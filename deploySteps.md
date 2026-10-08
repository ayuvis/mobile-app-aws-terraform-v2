# Deploy Steps: EKS + Karpenter + vLLM (canary + KEDA) on AWS

Run these steps from the unzipped `mobile-app-aws-terraform-v2` folder.
Steps 1-3 are the account-side checks most likely to block you, so do them first.

> **Cost warning:** GPU nodes, NAT gateways, Aurora, Redis and the EKS control plane all bill by the hour.
> With default settings (2 GPUs running 24/7) this stack costs well over $1,000 a month.
> Use the dev settings in Step 3 and finish with Step 11 (cleanup) when you're done testing.

---

## 1. Prepare the AWS account (one-time)

- [ ] **Don't deploy as the root user.** Create an IAM Identity Center user (or IAM user) with admin rights and enable MFA.
- [ ] Configure the CLI (`aws configure sso` or `aws configure`), then confirm:
  ```bash
  aws sts get-caller-identity
  ```
- [ ] Create a **budget alert** in AWS Billing (for example, alert at $50 and $200).
- [ ] **Request GPU quota now. This can take hours or days.**
  Service Quotas → EC2 → **"Running On-Demand G and VT instances"** → request at least **8 vCPUs** in your region.
  A `g5.xlarge` uses 4 vCPUs, and new accounts usually start at 0.
- [ ] Confirm GPU instance types are offered in your region:
  ```bash
  aws ec2 describe-instance-type-offerings --location-type region \
    --filters Name=instance-type,Values=g5.xlarge,g6.xlarge --region ap-south-1
  ```
  If the result is empty, set a different `region` in `terraform.tfvars`.

## 2. Install tools on your machine

| Tool | Needed for |
|---|---|
| `terraform` >= 1.6 | Infrastructure |
| `awscli` v2 | Auth, S3, kubeconfig |
| `kubectl` | Cluster access |
| `helm` | Debugging Helm releases (Terraform installs the charts) |
| `python3` + `pip install huggingface_hub` | Downloading model weights |
| `kubectl-argo-rollouts` plugin | Watching and controlling canary rollouts |

## 3. Use dev-sized settings for the first run

Create `terraform.tfvars` next to the `.tf` files:

```hcl
environment        = "dev"            # allows clean destroy (no deletion protection)
region             = "ap-south-1"
single_nat_gateway = true             # one NAT instead of three
db_instance_count  = 1
db_instance_class  = "db.t4g.medium"
cache_node_type    = "cache.t4g.small"
admin_cidrs        = ["<your-public-ip>/32"]   # curl -s https://checkip.amazonaws.com
github_repo        = "your-org/your-repo"
```

Also reduce GPU usage for testing:
- `k8s/03-vllm-keda.yaml`: set `minReplicaCount: 1`
- `k8s/01-vllm-rollout.yaml`: set `replicas: 1`

## 4. Create the infrastructure

```bash
terraform init
terraform apply -target=module.eks     # VPC + EKS first (~15 min)
terraform apply                        # Karpenter, Prometheus, KEDA, Argo Rollouts, Aurora, Redis, CloudFront, IAM
```

The two-step apply is needed because the `helm` and `kubectl` providers can only connect once the cluster exists.
Read each plan before typing `yes`.

If something fails on the full apply:

| Error | Fix |
|---|---|
| `no matches for kind "NodePool"` / `"EC2NodeClass"` | Karpenter CRDs weren't ready yet. Run `terraform apply` again. |
| 403 pulling the Karpenter chart from `public.ecr.aws` | `docker logout public.ecr.aws`, then apply again. |

## 5. Connect to the cluster and verify

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region ap-south-1

kubectl get nodes                      # 2 system nodes Ready
kubectl get pods -A                    # karpenter, keda, argo-rollouts, monitoring all Running
kubectl get nodepool,ec2nodeclass      # general and gpu-inference exist
```

## 6. Put model weights in S3

Start with a pre-quantized, ungated model. Llama needs a Hugging Face license acceptance and token; Qwen doesn't.

```bash
huggingface-cli download Qwen/Qwen2.5-7B-Instruct-AWQ --local-dir ./qwen2.5-7b-awq
aws s3 sync ./qwen2.5-7b-awq \
  s3://$(terraform output -raw models_bucket)/qwen2.5-7b-instruct-awq/
```

A 7B AWQ model fits on the 24 GB GPU in a `g5.xlarge`.

## 7. Point the manifest at your model

Edit `k8s/01-vllm-rollout.yaml`:

1. Replace `<MODELS_BUCKET>` with the output of `terraform output -raw models_bucket`.
2. Change the S3 path in the init container to `qwen2.5-7b-instruct-awq/`.
3. Set `--served-model-name=qwen2.5-7b`.
   (`--model=/models/llama` can stay. The init container syncs the weights into that path.)
4. Pin the vLLM image by digest if you can.

## 8. Deploy vLLM

```bash
kubectl apply -f k8s/01-vllm-rollout.yaml
kubectl apply -f k8s/02-vllm-analysis.yaml
kubectl apply -f k8s/03-vllm-keda.yaml

kubectl get nodeclaims -w                                      # Karpenter launching a GPU node
kubectl argo rollouts get rollout vllm-llama -n inference -w   # rollout progress
```

The first start takes about 5-10 minutes: GPU node launch, weights download, then model load.

If the pod stays `Pending`:
```bash
kubectl -n inference describe pod -l app=vllm-llama
kubectl describe nodeclaim
kubectl -n kube-system logs deploy/karpenter | tail -50
```
The usual cause is the GPU quota from Step 1.

## 9. Test it

```bash
kubectl -n inference port-forward svc/vllm-llama 8080:80
```

In another terminal:

```bash
curl localhost:8080/v1/models

curl localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b","messages":[{"role":"user","content":"Hello"}]}'
```

Check that Prometheus sees the metrics:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
# open http://localhost:9090 and query: vllm:num_requests_waiting
```

## 10. Try a canary rollout

Change something in the pod template (for example `--max-model-len=4096`, or a new model path) and re-apply:

```bash
kubectl apply -f k8s/01-vllm-rollout.yaml
kubectl argo rollouts get rollout vllm-llama -n inference -w
```

The rollout runs these steps:
1. A canary pod gets about 25% of traffic for 10 minutes while the checks in `02-vllm-analysis.yaml` run every minute.
2. It moves to 50% for another 10 minutes.
3. It goes to 100%.
4. If a check fails past its limit, the rollout aborts and traffic returns to the stable pods.

Useful commands:

```bash
kubectl argo rollouts promote vllm-llama -n inference     # skip a pause
kubectl argo rollouts abort vllm-llama -n inference       # manual rollback
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100
```

## 11. Clean up so you stop paying

Do this in order:

```bash
# 1. Remove workloads first so Karpenter terminates the GPU nodes
kubectl delete -f k8s/

# 2. Empty the buckets (not set to force-destroy)
aws s3 ls | grep mobileapp-dev                          # find the media and models bucket names
aws s3 rm s3://<media-bucket> --recursive
# The models bucket is versioned: use the console's "Empty" button so old versions are removed too

# 3. Delete ECR images (skip if the repo is empty)
aws ecr list-images --repository-name mobileapp-dev/app --query 'imageIds[*]' --output json > /tmp/ids.json
aws ecr batch-delete-image --repository-name mobileapp-dev/app --image-ids file:///tmp/ids.json

# 4. Destroy everything
terraform destroy
```

If `destroy` hangs, look for leftover load balancers or network interfaces in the VPC, delete them, and run it again.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Pod `Pending`, "insufficient nvidia.com/gpu" | NVIDIA device plugin not running on the GPU node yet. Check `kubectl -n kube-system get pods \| grep nvidia`. |
| No GPU node ever appears | GPU quota is 0 (Step 1), or the region has no g5/g6 capacity. |
| Init container fails with S3 `AccessDenied` | The service account must be exactly `vllm` in namespace `inference` (Pod Identity association). |
| Rollout aborts immediately | Analysis metric names don't match your vLLM version. Check `/metrics` on a pod and update `02-vllm-analysis.yaml` and `03-vllm-keda.yaml`. |
| KEDA doesn't scale | Check `kubectl -n inference describe scaledobject vllm-llama` and make sure Prometheus is reachable at the address in the file. |
| `terraform apply` fails connecting to the cluster | Run the first step with `-target=module.eks` before the full apply. |

## Before production

- Switch `environment` to `prod` (turns on DB deletion protection and final snapshots) and use `single_nat_gateway = false`.
- Lock `admin_cidrs` down and add a remote state backend in `versions.tf`.
- Add the EBS CSI driver or Amazon Managed Prometheus so metrics persist.
- Replace the demo RDS Proxy secret with a least-privilege app user.
- Add the AWS Load Balancer Controller and `trafficRouting` for exact canary percentages.

# Mobile app on AWS: EKS + Karpenter + vLLM (canary + KEDA)

## Layout

| Path | Purpose |
|---|---|
| `versions.tf`, `variables.tf` | Providers, state backend stub, inputs |
| `vpc.tf` | VPC, subnets, VPC endpoints |
| `eks.tf` | EKS cluster, system node group |
| `karpenter.tf` | Karpenter + general (Graviton) and GPU node pools, NVIDIA device plugin |
| `platform.tf` | Prometheus (persistent storage), KEDA, Argo Rollouts (Helm) |
| `ebs-csi.tf` | **New in v3:** EBS CSI driver add-on and `gp3` StorageClass for Prometheus |
| `data.tf` | Aurora + RDS Proxy, Redis |
| `edge.tf` | S3 + CloudFront, WAF, Route 53 |
| `iam.tf` | GitHub OIDC, ECR, models bucket, vLLM Pod Identity |
| `outputs.tf` | Useful endpoints and ARNs |
| `deploySteps.md` | Step-by-step first deployment on a new AWS account |
| `TROUBLESHOOTING.md` | **New in v3:** what changed, how to roll it out, triage commands and symptom-to-cause table |
| `k8s/01-vllm-rollout.yaml` | **New:** vLLM as an Argo Rollout (canary), Service, PodMonitor, PDB |
| `k8s/02-vllm-analysis.yaml` | **New:** AnalysisTemplate (TTFT, queue, KV-cache, restarts) |
| `k8s/03-vllm-keda.yaml` | **New:** KEDA ScaledObject (queue depth + KV-cache) |

## Deploy order

```bash
# 1. Cluster first (helm/kubectl providers need it to exist)
terraform init
terraform apply -target=module.eks
terraform apply

# 2. Upload model weights (AWQ-quantized Llama shown)
aws s3 sync ./llama-3.1-8b-instruct-awq s3://$(terraform output -raw models_bucket)/llama-3.1-8b-instruct-awq/

# 3. Edit k8s/01-vllm-rollout.yaml: set <MODELS_BUCKET>, pin the image digest
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region ap-south-1
kubectl apply -f k8s/01-vllm-rollout.yaml
kubectl apply -f k8s/02-vllm-analysis.yaml
kubectl apply -f k8s/03-vllm-keda.yaml
```

The first rollout is slow: Karpenter has to launch a GPU node, then the pod downloads weights and loads the model.

## Shipping a new model or config

Change the image, args or S3 path in `01-vllm-rollout.yaml` and apply it (or let Argo CD do it). The Rollout then runs these steps:

1. Starts a canary pod, which gets about 25% of traffic.
2. Holds for 10 minutes while `vllm-canary-health` checks TTFT p95, queue depth, KV-cache use and restarts every minute.
3. Moves to 50%, holds another 10 minutes, then goes to 100%.
4. If any check fails its limit, the Rollout aborts and traffic returns to the stable pods.

```bash
kubectl argo rollouts get rollout vllm-llama -n inference -w   # needs the kubectl-argo-rollouts plugin
kubectl argo rollouts abort vllm-llama -n inference            # manual rollback
kubectl argo rollouts promote vllm-llama -n inference          # skip a pause
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100
```

## Caveats

- **Canary weight is replica-based.** There is no ALB or mesh traffic router in this stack, so with 2 replicas "25%" becomes 1 canary pod out of 3, which is about 33%. For exact percentages or header-based and shadow traffic, add the AWS Load Balancer Controller (or a mesh/gateway) and switch to `trafficRouting`.
- **Add an app-level error rate.** vLLM doesn't expose a clean 5xx rate, so add a metric from your BFF to the AnalysisTemplate.
- **Prometheus now uses a 50 Gi gp3 EBS volume** (v3). For long retention or multiple clusters, consider Amazon Managed Prometheus.
- **Metric names are pinned to vLLM v0.6.x.** If you upgrade vLLM, check `/metrics` and update the queries in the analysis and KEDA files.
- **KEDA and the Rollout both set replicas.** Re-applying `01-vllm-rollout.yaml` briefly resets replicas to 2 until KEDA corrects it. With Argo CD, ignore `/spec/replicas` on the Rollout.
- **Helm chart versions are pinned** to late-2024 releases. Bump them to current ones before production.

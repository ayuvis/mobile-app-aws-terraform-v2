# Troubleshooting and v3 rollout

v3 targets three production symptoms: continuous pod restarts, high resource use at idle,
and autoscaling that doesn't behave. The fixes address the most likely causes from the
config in v2. They are **not yet confirmed against your cluster**, so run the triage
below to check which ones apply.

## What changed in v3

| Area | Change | Fixes |
|---|---|---|
| `k8s/01-vllm-rollout.yaml` | CPU/memory requests and limits on vLLM (and the init container), `/dev/shm` 8 Gi → 2 Gi, startup probe allows 20 min | OOMKilled pods, restarts during model load |
| `karpenter.tf` (GPU pool) | Only `2xlarge`/`4xlarge` sizes (`xlarge` has 16 GiB RAM), disruption budget of 1 node at a time | OOM on small GPU nodes, GPU node churn |
| `karpenter.tf` (general pool) | `consolidateAfter` 1m → 10m, 10% disruption budget | Pods constantly rescheduled |
| `eks.tf` | `metrics-server` add-on | `<unknown>` on CPU/memory HPAs, `kubectl top` failing |
| `ebs-csi.tf` (new) | EBS CSI driver, `gp3` StorageClass | Prometheus losing data on restart |
| `platform.tf` | Prometheus on a 50 Gi volume, memory limit, `enable_grafana` / `enable_alertmanager` switches | Prometheus restarts breaking KEDA, idle resource use |
| `k8s/03-vllm-keda.yaml` | Scale up 1 pod per 5 min (was 2 per minute), `fallback` to 2 replicas if Prometheus is down, KV-cache trigger moved to AverageValue, optional cron floor | Overshoot to max replicas then thrash, scaling stalling when Prometheus is down |

## Rolling out v3 (do it in a quiet period)

1. **Raise the GPU quota first.** During the transition, old `xlarge` nodes (4 vCPU each)
   and new `2xlarge` nodes (8 vCPU each) run together. For 2 replicas plus one surge pod,
   plan for about 32 vCPUs of "Running On-Demand G and VT instances".
2. `terraform plan`, then `terraform apply`. Expect:
   - new EBS CSI add-on, IAM role and `gp3` StorageClass, plus the `metrics-server` add-on
   - Prometheus Helm upgrade onto a persistent volume (it restarts once and starts with empty history)
   - NodePool changes; Karpenter replaces nodes gradually (10% of general nodes, one GPU node at a time)
3. Check: `kubectl top nodes` works, `kubectl -n monitoring get pvc` shows `Bound`.
4. `kubectl apply -f k8s/01-vllm-rollout.yaml`. The pod template changed, so this starts a
   canary (about 25 minutes with the pauses). Watch it with
   `kubectl argo rollouts get rollout vllm-llama -n inference -w` and skip the pauses with
   `kubectl argo rollouts promote vllm-llama -n inference --full` once the canary looks healthy.
   Applying this file resets `replicas` to 2 until KEDA corrects it.
5. `kubectl apply -f k8s/03-vllm-keda.yaml`, then confirm with
   `kubectl get scaledobject,hpa -n inference`.

## Triage commands

```bash
# Which pods restart, and why
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -15
kubectl describe pod <pod> -n <ns> | grep -A8 "Last State"     # OOMKilled / Error / probe failure
kubectl get events -A --sort-by=.lastTimestamp | tail -40

# Utilization (fails if metrics-server is missing)
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20

# Autoscaling
kubectl get hpa,scaledobject -A
kubectl describe scaledobject vllm-llama -n inference          # Ready / Active / Fallback conditions
kubectl -n keda logs deploy/keda-operator --tail=100

# Karpenter churn
kubectl get nodeclaims
kubectl -n kube-system logs deploy/karpenter | grep -i -E "disrupt|consolidat|interrupt" | tail -30
```

## Symptom to cause

| Symptom | Check | Likely cause |
|---|---|---|
| vLLM `OOMKilled` (exit 137) | `describe pod` → Last State | Small GPU node, no memory limits, big `/dev/shm` (fixed in v3) |
| "Startup probe failed" in events | `kubectl get events` | Model load slower than the probe window; raise `failureThreshold` or use faster storage |
| App pods recreated but containers not crashing | `kubectl get nodeclaims`, Karpenter logs | Consolidation, Spot interruption or drift; add PDBs, longer `consolidateAfter` |
| Prometheus pod restarting | `kubectl -n monitoring get pods` | No memory limit or no persistent volume (fixed in v3) |
| Rollout keeps aborting | `kubectl argo rollouts get rollout ...` | A canary pod restarted, or metric names don't match your vLLM version |
| HPA shows `<unknown>` | `kubectl get hpa -A` | No metrics-server (fixed in v3), or missing CPU requests on the pods |
| KEDA not scaling | `describe scaledobject`, keda-operator logs | Prometheus unreachable, PodMonitor not scraped, or metric names changed after a vLLM upgrade |
| Scales to max, then slowly back | HPA events | Pending GPU pods don't lower the metric; scale-up is now 1 pod per 5 min in v3 |
| Pods Pending, no new node | `kubectl describe nodeclaim` | GPU quota or the NodePool's 16-GPU limit |
| Two HPAs fighting | `kubectl get hpa -n inference` | Only `keda-hpa-vllm-llama` should exist for the Rollout |

## Notes on idle usage

- GPU **memory** near 90% at idle is expected: `--gpu-memory-utilization=0.90` pre-allocates the KV cache. Look at GPU compute utilization and `vllm:num_requests_running` instead.
- The idle floor is the 2 always-on GPU nodes plus the monitoring stack. Options: set `enable_grafana = false` / `enable_alertmanager = false` if unused, or use the cron trigger in `03-vllm-keda.yaml` to run 1 replica outside business hours.
- If you upgrade vLLM, re-check metric names on `/metrics` (the KV-cache gauge has been renamed in newer releases) and update `02-vllm-analysis.yaml` and `03-vllm-keda.yaml`.

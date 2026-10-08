############################################
# Platform add-ons the vLLM rollout depends on:
#   - Prometheus (metrics for KEDA + canary analysis), now with persistent storage
#   - KEDA (autoscaling on queue depth / KV-cache)
#   - Argo Rollouts (canary with automatic rollback)
# Chart versions are pinned for reproducibility; bump them deliberately.
############################################

variable "prometheus_storage_size" {
  description = "Size of the Prometheus EBS volume (gp3)"
  type        = string
  default     = "50Gi"
}

variable "enable_grafana" {
  description = "Set false to save memory/CPU if you don't use the bundled Grafana"
  type        = bool
  default     = true
}

variable "enable_alertmanager" {
  description = "Set false to save memory/CPU if you don't use the bundled Alertmanager"
  type        = bool
  default     = true
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.5.1"
  timeout          = 900

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention     = "7d"
        retentionSize = "40GB" # keep below the volume size so the TSDB never fills the disk

        # Pick up PodMonitors / ServiceMonitors / rules from any namespace,
        # not only ones labelled release=kube-prometheus-stack
        podMonitorSelectorNilUsesHelmValues     = false
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false

        # A memory limit stops Prometheus starving neighbours; size up if you see OOMKills
        resources = {
          requests = { cpu = "500m", memory = "2Gi" }
          limits   = { memory = "4Gi" }
        }

        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = { storage = var.prometheus_storage_size }
              }
            }
          }
        }
      }
    }
    grafana      = { enabled = var.enable_grafana }
    alertmanager = { enabled = var.enable_alertmanager }
  })]

  depends_on = [kubectl_manifest.nodepool_general, kubectl_manifest.storageclass_gp3]
}

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.16.0"

  depends_on = [kubectl_manifest.nodepool_general]
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.37.7"

  values = [yamlencode({
    controller = { replicas = 2 }
    dashboard  = { enabled = true } # ClusterIP only; use kubectl port-forward
  })]

  depends_on = [kubectl_manifest.nodepool_general]
}

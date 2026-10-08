############################################
# Platform add-ons the vLLM rollout depends on:
#   - Prometheus (metrics for KEDA + canary analysis)
#   - KEDA (autoscaling on queue depth / KV-cache)
#   - Argo Rollouts (canary with automatic rollback)
# Chart versions are pinned for reproducibility; bump them deliberately.
############################################

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
        retention = "7d"
        # Pick up PodMonitors / ServiceMonitors / rules from any namespace,
        # not only ones labelled release=kube-prometheus-stack
        podMonitorSelectorNilUsesHelmValues     = false
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
        resources = {
          requests = { cpu = "500m", memory = "2Gi" }
        }
        # NOTE: no PVC here (the EBS CSI driver add-on is not installed in this
        # stack), so metrics are lost on Prometheus restart. For production use
        # the EBS CSI add-on + a storageSpec, or Amazon Managed Prometheus.
      }
    }
  })]

  depends_on = [kubectl_manifest.nodepool_general]
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

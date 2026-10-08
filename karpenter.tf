############################################
# Karpenter: IAM, SQS interruption queue, Helm chart
############################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name                    = module.eks.cluster_name
  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.us_east_1
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.6"
  wait       = false

  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  values = [yamlencode({
    replicas = 2
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
  })]

  depends_on = [module.eks]
}

############################################
# General pool: Graviton, Spot + On-Demand
############################################
resource "kubectl_manifest" "nodeclass_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      role: ${module.karpenter.node_iam_role_name}
      amiSelectorTerms:
        - alias: al2023@latest
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs: { volumeSize: 50Gi, volumeType: gp3, encrypted: true }
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool_general" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: general
    spec:
      template:
        spec:
          nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
          expireAfter: 720h
          requirements:
            - { key: kubernetes.io/arch, operator: In, values: ["arm64"] }
            - { key: karpenter.sh/capacity-type, operator: In, values: ["spot", "on-demand"] }
            - { key: karpenter.k8s.aws/instance-category, operator: In, values: ["c", "m", "r"] }
            - { key: karpenter.k8s.aws/instance-generation, operator: Gt, values: ["6"] }
      limits:
        cpu: "2000"
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.nodeclass_default]
}

############################################
# GPU pool: isolated, tainted, for vLLM only
############################################
resource "kubectl_manifest" "nodeclass_gpu" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: gpu
    spec:
      role: ${module.karpenter.node_iam_role_name}
      amiSelectorTerms:
        - alias: al2023@latest   # Karpenter picks the NVIDIA AMI variant for GPU types
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs: { volumeSize: 300Gi, volumeType: gp3, iops: 6000, throughput: 500, encrypted: true }
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool_gpu" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu-inference
    spec:
      template:
        metadata:
          labels: { workload: llm-inference }
        spec:
          nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu }
          taints:
            - { key: nvidia.com/gpu, value: "true", effect: NoSchedule }
          requirements:
            - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
            - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
            - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["g5", "g6"] }
      limits:
        nvidia.com/gpu: "16"
      disruption:
        # Weights take minutes to load: be slow to scale GPU nodes down
        consolidationPolicy: WhenEmpty
        consolidateAfter: 15m
  YAML

  depends_on = [kubectl_manifest.nodeclass_gpu]
}

# Exposes nvidia.com/gpu to the scheduler on GPU nodes
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.16.2"

  values = [yamlencode({
    affinity     = null # default affinity needs NFD labels; we select by nodepool instead
    nodeSelector = { workload = "llm-inference" }
    tolerations  = [{ key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }]
  })]

  depends_on = [helm_release.karpenter]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.admin_cidrs

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    # Required for CPU/memory HPAs and `kubectl top`. KEDA alone does not provide it.
    metrics-server = {}
  }

  # Small Graviton group that only runs system pods (Karpenter, CoreDNS).
  # Everything else is provisioned just-in-time by Karpenter.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["m7g.large"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Karpenter discovers the node security group by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }
}

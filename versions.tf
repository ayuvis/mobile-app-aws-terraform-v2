terraform {
  required_version = ">= 1.6"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.70" }
    helm    = { source = "hashicorp/helm", version = "~> 2.15" }
    kubectl = { source = "alekc/kubectl", version = "~> 2.0" }
  }

  # Remote state: create the bucket + lock table once, then uncomment.
  # backend "s3" {
  #   bucket         = "my-tf-state-bucket"
  #   key            = "mobile-app/prod/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# ECR Public tokens (used to pull the Karpenter chart) only exist in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

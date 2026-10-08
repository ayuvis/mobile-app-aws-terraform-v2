variable "project" {
  type    = string
  default = "mobileapp"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "ap-south-1" # check GPU instance availability (g5/g6) in your region
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT (cheap, dev). false = one NAT per AZ (prod HA)."
  type        = bool
  default     = false
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"] # lock this down
}

variable "db_instance_class" {
  type    = string
  default = "db.r7g.large"
}

variable "db_instance_count" {
  description = "1 writer + N-1 readers"
  type        = number
  default     = 2
}

variable "cache_node_type" {
  type    = string
  default = "cache.r7g.large"
}

variable "github_repo" {
  description = "org/repo allowed to assume the CI role via OIDC"
  type        = string
  default     = "my-org/my-app"
}

# Optional DNS (leave empty until the ALB exists)
variable "domain" {
  type    = string
  default = ""
}

variable "hosted_zone_id" {
  type    = string
  default = ""
}

variable "alb_dns_name" {
  type    = string
  default = ""
}

variable "alb_zone_id" {
  type    = string
  default = ""
}

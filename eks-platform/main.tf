locals {
  name         = "enterprise-eks-vpc"
  region       = "us-east-1"
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "enterprise-eks-cluster"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  # We use 3 AZs for high availability
  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  # Enterprise Security: Nodes are private, internet access goes through NAT
  enable_nat_gateway     = true
  single_nat_gateway     = true # Set to true to save money in training. In prod, this is false (1 NAT per AZ).
  one_nat_gateway_per_az = false

  # EKS requires DNS support
  enable_dns_hostnames = true
  enable_dns_support   = true

  # --- REQUIRED TAGS FOR EKS ROUTING ---

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.cluster_name
  }
}

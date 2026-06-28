module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31" # Using v20+ to ensure native Pod Identity & CAM support

  cluster_name    = local.cluster_name
  cluster_version = "1.30" # A highly stable version for enterprise

  # Network routing (referencing our VPC module)
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # For training, we keep the endpoint public so your local kubectl works.
  # In strict enterprise prod, this is false and accessed via Transit Gateway/VPN.
  cluster_endpoint_public_access = true

  # 1. Modern Authentication (Goodbye aws-auth configmap)
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  # 2. Modern Add-ons (Notice the Pod Identity Agent)
  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {} 
    aws-ebs-csi-driver     = { most_recent = true }
  }

# 3. The System Bootstrap Node Group
#   eks_managed_node_groups = {
#     system_nodes = {
#       # Amazon Linux 2023 is the new standard over AL2
#       ami_type       = "AL2023_x86_64_STANDARD"
#       instance_types = ["t3.medium"] # Big enough to hold LGTM & Karpenter controllers
      
#       min_size     = 2
#       max_size     = 3
#       desired_size = 2
      
#       # We put system nodes in private subnets
#       subnet_ids = module.vpc.private_subnets
#     }
#   }
}

# --- PREREQUISITE FOR LGTM STORAGE (EBS CSI DRIVER IAM) ---
module "aws_ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 1.7" # Modern version for Pod Identity

  name = "aws-ebs-csi-pod-identity"
  attach_aws_ebs_csi_policy = true

  # This maps the AWS IAM Role directly to the Kubernetes Service Account
  associations = {
    eks = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }
}

# 1. Install Karpenter via Blueprints
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name
  enable_irsa  = true
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn
}

# Output the command to update your local kubeconfig
output "configure_kubectl" {
  description = "Run this command to configure your local kubectl context"
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

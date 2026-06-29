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
    coredns    = {}
    kube-proxy = {}
    # Prefix delegation raises the per-node pod cap dramatically (e.g. t3.medium
    # ~17 -> ~110 pods) by assigning /28 IP prefixes instead of secondary IPs.
    # Without it, small nodes hit "Too many pods" and DaemonSets/extra pods stay
    # Pending. Takes effect on NEW ENIs — recycle existing nodes after applying.
    vpc-cni = {
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {}
    aws-ebs-csi-driver     = { most_recent = true }
  }

  # 3. The System Bootstrap Node Group
  # The bootstrap floor that runs the cluster-critical controllers (Karpenter,
  # CoreDNS, EBS CSI). Karpenter provisions all dynamic workload nodes (ArgoCD,
  # monitoring, apps) on its own nodes; instance_types here does NOT constrain
  # Karpenter's sizing. Baseline is 2 nodes for controller headroom/HA while in
  # use; scale down to 1 when idle via `just floor-down`. max_size = 3 leaves
  # surge room for rolling node-group updates.
  eks_managed_node_groups = {
    system_nodes = {
      # Amazon Linux 2023 is the new standard over AL2
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"] # 2 vCPU / 4 GiB

      min_size     = 1
      max_size     = 3
      desired_size = 2

      # We put system nodes in private subnets
      subnet_ids = module.vpc.private_subnets
    }
  }

  # Karpenter discovers the security group to attach to provisioned nodes via this tag.
  # The matching tag on private subnets is set in main.tf. Without this, an
  # EC2NodeClass using securityGroupSelectorTerms{karpenter.sh/discovery} finds nothing.
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }
}

# --- PREREQUISITE FOR LGTM STORAGE (EBS CSI DRIVER IAM) ---
module "aws_ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 1.7" # Modern version for Pod Identity

  name                      = "aws-ebs-csi-pod-identity"
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

# NOTE: Karpenter is installed and fully managed by the `eks_blueprints_addons`
# module in argocd.tf (enable_karpenter = true). That module creates the controller
# IRSA role, the node IAM role + instance profile, the SQS interruption queue and
# EventBridge rules, AND installs the Helm chart. A second standalone
# `terraform-aws-modules/eks//modules/karpenter` here would duplicate all of that
# (orphaned IAM roles, a second unused SQS queue) and is intentionally NOT used.

# Output the command to update your local kubeconfig
output "configure_kubectl" {
  description = "Run this command to configure your local kubectl context"
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.1"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Existing ArgoCD configuration
  enable_argocd = true
  argocd = {
    namespace        = "argocd"
    create_namespace = true
    chart_version    = "7.3.11"
  }

  # Increased timeout for Karpenter installation
  enable_karpenter = true
  karpenter = {
    chart_version = "1.0.0"
    timeout       = 600
    # NOTE: this module passes Helm values via `set` (list of {name,value}); a
    # `settings = {}` map is NOT read by the module and would be silently ignored.
    # Single-node floor: run ONE Karpenter replica with modest requests so the
    # controller + CoreDNS + EBS CSI all fit on one t3.medium (~1.93 vCPU
    # allocatable). The chart's default 2 replicas x 1 vCPU would not fit.
    set = [
      {
        name  = "replicas"
        value = "1"
      },
      {
        name  = "controller.resources.requests.cpu"
        value = "0.5"
      },
      {
        name  = "controller.resources.requests.memory"
        value = "512Mi"
      },
    ]
  }

  # Give the Karpenter node IAM role a deterministic name (default uses a random
  # name_prefix). The EC2NodeClass in the GitOps repo references this exact name via
  # spec.role, so it must be stable.
  karpenter_node = {
    iam_role_use_name_prefix = false
    iam_role_name            = "karpenter-node-${module.eks.cluster_name}"
  }
}

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
    settings = {
      "controller.image.repository" = "public.ecr.aws/karpenter/controller"
      # This overrides the hook image to a standard, reliable version
      "webhook.image.repository" = "public.ecr.aws/karpenter/webhook"
    }
  }

  # Give the Karpenter node IAM role a deterministic name (default uses a random
  # name_prefix). The EC2NodeClass in the GitOps repo references this exact name via
  # spec.role, so it must be stable.
  karpenter_node = {
    iam_role_use_name_prefix = false
    iam_role_name            = "karpenter-node-${module.eks.cluster_name}"
  }
}

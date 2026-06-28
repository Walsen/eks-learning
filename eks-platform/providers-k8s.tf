# Fetch a temporary authentication token from AWS to log into the cluster
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

# Tell the Kubernetes provider how to connect
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# Tell the Helm provider how to connect (it nests the k8s config)
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

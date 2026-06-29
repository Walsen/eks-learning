terraform {
  required_version = ">=1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>5.40"
    }
    # Pin helm to v2.x: the provider "helm" { kubernetes { ... } } nested-block
    # syntax used in providers-k8s.tf was removed in helm provider v3. Leaving this
    # unpinned lets a clean `terraform init` pull v3 and break the config.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "training"
      ManagedBy   = "Terraform"
    }
  }
}

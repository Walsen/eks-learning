terraform {
	required_version = ">=1.5.0"

	required_providers {
		aws = {
			source =  "hashicorp/aws"
			version = "~>5.40"
		}
	}
}

provider "aws" {
  region = "us-east-1"

  default_tags {
	tags = {
	  Environment = "training"
	  ManagedBy = "Terraform"
	}
  }
}

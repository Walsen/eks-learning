# ---------------------------------------------------------------------------
# LGTM observability backend — Phase 1: object storage + Pod Identity
#
# Loki (logs), Tempo (traces) and Mimir (metrics) each persist to their own
# S3 bucket. Access is granted via EKS Pod Identity (same pattern as the EBS
# CSI driver), scoped to each component's bucket only.
#
# The namespace / service_account values below MUST match the Helm releases
# added in later phases (release name == namespace == service account name).
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # component => { namespace, service_account }. Buckets and IAM are derived.
  lgtm_components = {
    loki  = { namespace = "loki", service_account = "loki" }
    tempo = { namespace = "tempo", service_account = "tempo" }
    mimir = { namespace = "mimir", service_account = "mimir" }
  }

  # Globally-unique bucket names: <cluster>-<component>-<account_id>
  lgtm_bucket_names = {
    for k, v in local.lgtm_components :
    k => "${local.cluster_name}-${k}-${data.aws_caller_identity.current.account_id}"
  }
}

# --- S3 buckets -------------------------------------------------------------

resource "aws_s3_bucket" "lgtm" {
  for_each = local.lgtm_components
  bucket   = local.lgtm_bucket_names[each.key]

  # Telemetry data is reproducible; allow Terraform to remove the bucket
  # (and its contents) when destroyed in this training environment.
  force_destroy = true

  tags = {
    Component = each.key
    Stack     = "lgtm"
  }
}

# Disable ACLs (modern best practice — ownership enforced by the bucket owner).
resource "aws_s3_bucket_ownership_controls" "lgtm" {
  for_each = local.lgtm_components
  bucket   = aws_s3_bucket.lgtm[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block all public access.
resource "aws_s3_bucket_public_access_block" "lgtm" {
  for_each = local.lgtm_components
  bucket   = aws_s3_bucket.lgtm[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption (SSE-S3).
resource "aws_s3_bucket_server_side_encryption_configuration" "lgtm" {
  for_each = local.lgtm_components
  bucket   = aws_s3_bucket.lgtm[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle: abort incomplete multipart uploads. Object/block retention itself
# is managed by each LGTM component's compactor/retention config, not here, to
# avoid deleting blocks the database still references.
resource "aws_s3_bucket_lifecycle_configuration" "lgtm" {
  for_each = local.lgtm_components
  bucket   = aws_s3_bucket.lgtm[each.key].id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {} # apply to all objects

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- Pod Identity: one role per component, scoped to its bucket -------------

module "lgtm_pod_identity" {
  source   = "terraform-aws-modules/eks-pod-identity/aws"
  version  = "~> 1.7"
  for_each = local.lgtm_components

  # Use the exact name (not name_prefix). The module's name_prefix is capped at
  # 38 chars; "<cluster>-<component>-pod-identity-" exceeds that. The fixed name
  # is ~40 chars, well under the IAM role 64-char limit.
  name            = "${local.cluster_name}-${each.key}-pod-identity"
  use_name_prefix = false

  attach_custom_policy      = true
  custom_policy_description = "S3 access for ${each.key} (LGTM)"
  policy_statements = [
    {
      sid       = "BucketLevel"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [aws_s3_bucket.lgtm[each.key].arn]
    },
    {
      sid = "ObjectLevel"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = ["${aws_s3_bucket.lgtm[each.key].arn}/*"]
    },
  ]

  # Map the IAM role to the component's Kubernetes service account.
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = each.value.namespace
      service_account = each.value.service_account
    }
  }
}

# --- Outputs (consumed by the Helm values in later phases) ------------------

output "lgtm_bucket_names" {
  description = "S3 bucket name per LGTM component"
  value       = local.lgtm_bucket_names
}

output "lgtm_pod_identity_role_arns" {
  description = "Pod Identity IAM role ARN per LGTM component"
  value       = { for k, m in module.lgtm_pod_identity : k => m.iam_role_arn }
}

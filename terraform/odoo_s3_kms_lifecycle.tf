#############################
# Variables
#############################
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket for Odoo SaaS backups"
  type        = string
}

variable "kms_key_alias" {
  description = "Alias for the KMS key (without alias/ prefix)"
  type        = string
  default     = "odoo-saas-backups"
}

variable "lifecycle_days" {
  description = "Expire backups after N days"
  type        = number
  default     = 30
}

# Optional: principal ARN (role/user) that your admin app uses for S3 access
variable "app_principal_arn" {
  description = "IAM Role/User ARN used by the admin app to access S3 (optional)"
  type        = string
  default     = ""
}

#############################
# Provider
#############################
provider "aws" {
  region = var.aws_region
}

#############################
# KMS Key + Alias
#############################
resource "aws_kms_key" "backups" {
  description             = "KMS key for Odoo SaaS backups"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "backups_alias" {
  name          = "alias/${var.kms_key_alias}"
  target_key_id = aws_kms_key.backups.key_id
}

#############################
# S3 Bucket with security
#############################
resource "aws_s3_bucket" "backups" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.backups.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle: expire tenant dumps under tenants/<db>/
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-tenant-dumps"
    status = "Enabled"

    filter {
      prefix = "tenants/"
    }

    expiration {
      days = var.lifecycle_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.lifecycle_days
    }
  }
}

# Bucket policy: enforce TLS and SSE-KMS with our key
data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*"
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid     = "DenyUnencryptedUploads"
    effect  = "Deny"
    actions = ["s3:PutObject"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = ["${aws_s3_bucket.backups.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid     = "DenyIncorrectKMSKey"
    effect  = "Deny"
    actions = ["s3:PutObject"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = ["${aws_s3_bucket.backups.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.backups.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

#############################
# Optional IAM policy for the app
#############################
data "aws_iam_policy_document" "app_access" {
  # Restrict to the 'tenants/' prefix (list bucket + object ops)
  statement {
    sid    = "ListBucketUnderPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["tenants/*"]
    }
  }

  statement {
    sid    = "ObjectCRUDUnderTenants"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:DeleteObjectVersion"
    ]
    resources = ["${aws_s3_bucket.backups.arn}/tenants/*"]
  }

  # Allow KMS decrypt/encrypt with our key
  statement {
    sid    = "KMSUsage"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey"
    ]
    resources = [aws_kms_key.backups.arn]
  }
}

resource "aws_iam_policy" "app_access" {
  name   = "${var.kms_key_alias}-s3-app-access"
  policy = data.aws_iam_policy_document.app_access.json
}

# Optionally attach to an existing role/user if provided
resource "aws_iam_role_policy_attachment" "app_role_attach" {
  count      = var.app_principal_arn != "" && can(regex("^arn:aws:iam::[0-9]+:role/", var.app_principal_arn)) ? 1 : 0
  role       = element(split("/", var.app_principal_arn), length(split("/", var.app_principal_arn)) - 1)
  policy_arn = aws_iam_policy.app_access.arn
}

resource "aws_iam_user_policy_attachment" "app_user_attach" {
  count      = var.app_principal_arn != "" && can(regex("^arn:aws:iam::[0-9]+:user/", var.app_principal_arn)) ? 1 : 0
  user       = element(split("/", var.app_principal_arn), length(split("/", var.app_principal_arn)) - 1)
  policy_arn = aws_iam_policy.app_access.arn
}

#############################
# Outputs
#############################
output "bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "kms_key_arn" {
  value = aws_kms_key.backups.arn
}

output "kms_alias" {
  value = aws_kms_alias.backups_alias.name
}

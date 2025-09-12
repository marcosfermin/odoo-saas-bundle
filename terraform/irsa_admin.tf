#terraform/irsa_admin.tf

#Creates an IAM Role for Service Account (IRSA) and attaches the S3/KMS policy we already created (aws_iam_policy.app_access).
#Inputs you must provide: your cluster’s OIDC Provider URL/ARN, and the k8s SA name/namespace.

############################################
# Variables (fill with your EKS specifics)
############################################
variable "eks_oidc_provider_arn" {
  description = "ARN of the EKS cluster OIDC provider"
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "URL of the OIDC provider (no https:// prefix, e.g. oidc.eks.us-east-1.amazonaws.com/id/XXXX)"
  type        = string
}

variable "k8s_sa_name" {
  description = "Kubernetes ServiceAccount name used by Admin app"
  type        = string
  default     = "admin-sa"
}

variable "k8s_sa_namespace" {
  description = "Namespace of the ServiceAccount"
  type        = string
  default     = "odoo-saas"
}

############################################
# IAM Role trust policy for IRSA
############################################
data "aws_iam_policy_document" "admin_irsa_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.k8s_sa_namespace}:${var.k8s_sa_name}"]
    }
  }
}

resource "aws_iam_role" "admin_irsa_role" {
  name               = "odoo-admin-irsa"
  assume_role_policy = data.aws_iam_policy_document.admin_irsa_trust.json
}

# Reuse the app access policy from the S3+KMS Terraform (created earlier):
#   resource "aws_iam_policy" "app_access" { ... }
resource "aws_iam_role_policy_attachment" "admin_attach" {
  role       = aws_iam_role.admin_irsa_role.name
  policy_arn = aws_iam_policy.app_access.arn
}

output "admin_irsa_role_arn" {
  value = aws_iam_role.admin_irsa_role.arn
}

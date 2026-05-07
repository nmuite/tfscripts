# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_iam_user" "user_admin" {
  name = "admin"
  path = "/"
  tags = {
    AKIA3QQQOG76YTPZHQGF = "AWS CLI"
    AKIA3QQQOG763CSSM4XO = "admin-CLI_user"
    AKIA3QQQOG76ZMGKXEOF = "cli-userid"
    AKIA3QQQOG76RL3NXGHL = "CLI-Access-Key"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_user" "user_muite" {
  name = "muite"
  path = "/"
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_user" "user_terraform1" {
  name = "Terraform1"
  path = "/"
  tags = {
    AKIA3QQQOG76ZRZZRFV6 = "AWS-CLI"
    AKIA3QQQOG76SJBVS6XB = "CLi Auth"
    AKIA3QQQOG7662SEAB5A = "Terraform_New_Key"
    AKIA3QQQOG765GDNALMA = "clli-user"
    AKIA3QQQOG76VNQ26QHC = "CLI_User"
    AKIA3QQQOG76VG6SYQ76 = "Terraform_user"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_user" "user_wingutec_user" {
  name = "wingutec-user"
  path = "/"
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_user" "user_wingutecweb" {
  name = "wingutecweb"
  path = "/"
  lifecycle { prevent_destroy = true }
}


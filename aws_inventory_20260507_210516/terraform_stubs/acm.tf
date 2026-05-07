# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_acm_certificate" "cert_muite_et_lab_be" {
  domain_name               = "muite.et-lab.be"
  validation_method         = "DNS"
  # subject_alternative_names = [muite.et-lab.be]
  lifecycle { prevent_destroy = true }
}


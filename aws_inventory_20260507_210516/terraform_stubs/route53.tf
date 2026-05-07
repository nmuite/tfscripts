# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_route53_zone" "zone_sub_wingutec_com_" {
  name          = "sub.wingutec.com."
  lifecycle { prevent_destroy = true }
}

resource "aws_route53_zone" "zone_wingutec_com_" {
  name          = "wingutec.com."
  comment = "HostedZone created by Route53 Registrar"
  lifecycle { prevent_destroy = true }
}

resource "aws_route53_zone" "zone_wingutec_com_" {
  name          = "wingutec.com."
  # vpc { vpc_id = "" }
  comment = "private for wingutec"
  lifecycle { prevent_destroy = true }
}


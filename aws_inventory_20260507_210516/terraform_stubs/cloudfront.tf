# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_cloudfront_distribution" "cf_e2ishgzrxzj9ol" {
  enabled         = true
  price_class     = "PriceClass_200"
  http_version    = "HTTP2"

  # TODO: define origin, default_cache_behavior after import
  lifecycle { prevent_destroy = true }
}


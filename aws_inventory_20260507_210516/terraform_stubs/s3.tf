# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_s3_bucket" "bucket_cf_templates_194oi5gopobgf_eu_west_1" {
  bucket = "cf-templates-194oi5gopobgf-eu-west-1"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_cf_templates_1gojhcbg0d146_us_east_1" {
  bucket = "cf-templates-1gojhcbg0d146-us-east-1"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_cf_templates_1gojhcbg0d146_us_east_2" {
  bucket = "cf-templates-1gojhcbg0d146-us-east-2"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_cf_templates_dcsuine5qkrq0_us_east_1" {
  bucket = "cf-templates-dcsuine5qkrq0-us-east-1"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_cloudfront_06062024_muite" {
  bucket = "cloudfront-06062024-muite"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_codepipeline_us_east_1_a15c123f9011_4ecc_9533_b260df0" {
  bucket = "codepipeline-us-east-1-a15c123f9011-4ecc-9533-b260df03f347"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_config_bucket_791382210557" {
  bucket = "config-bucket-791382210557"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_elasticbeanstalk_ap_southeast_2_791382210557" {
  bucket = "elasticbeanstalk-ap-southeast-2-791382210557"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_elasticbeanstalk_us_east_1_791382210557" {
  bucket = "elasticbeanstalk-us-east-1-791382210557"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_gateway_endpoint" {
  bucket = "gateway-endpoint"
  # region is managed via provider alias

  # versioning { enabled = true }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_nmuiteafrica" {
  bucket = "nmuiteafrica"
  # region is managed via provider alias

  # versioning { enabled = true }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_nmuitebilling" {
  bucket = "nmuitebilling"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_nmuitesaa" {
  bucket = "nmuitesaa"
  # region is managed via provider alias

  # versioning { enabled = true }
  tags = {
    project = "SAA"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_terraform_bucket_c40daa3956dc60f41398" {
  bucket = "terraform-bucket-c40daa3956dc60f41398"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_terraform_bucket_c40daa3956dc60f41398_private" {
  bucket = "terraform-bucket-c40daa3956dc60f41398-private"
  # region is managed via provider alias

  # versioning { enabled = true }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_terraform2_3375436aa2f669f4" {
  bucket = "terraform2-3375436aa2f669f4"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_test_vpc_s3_muite" {
  bucket = "test-vpc-s3-muite"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_vpc_flow_logs__muite" {
  bucket = "vpc-flow-logs--muite"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_website_bucket_ngm" {
  bucket = "website-bucket-ngm"
  # region is managed via provider alias

  # versioning { enabled = true }
  tags = {
    project = "Wingutec"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_wingutec_co_za" {
  bucket = "wingutec.co.za"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "bucket_wingutec_com" {
  bucket = "wingutec.com"
  # region is managed via provider alias
  lifecycle { prevent_destroy = true }
}


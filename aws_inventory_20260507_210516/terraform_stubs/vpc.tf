# Auto-generated Terraform stubs — Account: 791382210557 — 20260507_210516
# Run:  terraform init && terraform plan -generate-config-out=generated.tf
# Then: terraform apply

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_vpc" "transit_vpc_vpc" {
  cidr_block           = "10.200.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "Transit-VPC-vpc"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_vpc" "app_vpc_vpc" {
  cidr_block           = "10.100.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "App-VPC-vpc"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_vpc" "vpc_08908d5dc7fed56f3" {
  cidr_block           = "10.10.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    aws:cloudformation:stack-id = "arn:aws:cloudformation:us-east-2:791382210557:stack/vpc-create-01/21643aa0-9af0-11ef-befa-068760757da9"
    aws:cloudformation:stack-name = "vpc-create-01"
    aws:cloudformation:logical-id = "VPC"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "app_vpc_subnet_private2_us_east_2b" {
  vpc_id                  = "vpc-09913aa02362a04b4"
  cidr_block              = "10.100.144.0/20"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = false
  tags = {
    Name = "App-VPC-subnet-private2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "app_vpc_subnet_public2_us_east_2b" {
  vpc_id                  = "vpc-09913aa02362a04b4"
  cidr_block              = "10.100.16.0/20"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = false
  tags = {
    Name = "App-VPC-subnet-public2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "transit_vpc_subnet_private2_us_east_2b" {
  vpc_id                  = "vpc-01cf29f8c4f8b83ab"
  cidr_block              = "10.200.144.0/20"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = false
  tags = {
    Name = "Transit-VPC-subnet-private2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "transit_vpc_subnet_public1_us_east_2a" {
  vpc_id                  = "vpc-01cf29f8c4f8b83ab"
  cidr_block              = "10.200.0.0/20"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = false
  tags = {
    Name = "Transit-VPC-subnet-public1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "transit_vpc_subnet_private1_us_east_2a" {
  vpc_id                  = "vpc-01cf29f8c4f8b83ab"
  cidr_block              = "10.200.128.0/20"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = false
  tags = {
    Name = "Transit-VPC-subnet-private1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "app_vpc_subnet_public1_us_east_2a" {
  vpc_id                  = "vpc-09913aa02362a04b4"
  cidr_block              = "10.100.0.0/20"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = false
  tags = {
    Name = "App-VPC-subnet-public1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "app_vpc_subnet_private1_us_east_2a" {
  vpc_id                  = "vpc-09913aa02362a04b4"
  cidr_block              = "10.100.128.0/20"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = false
  tags = {
    Name = "App-VPC-subnet-private1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_subnet" "transit_vpc_subnet_public2_us_east_2b" {
  vpc_id                  = "vpc-01cf29f8c4f8b83ab"
  cidr_block              = "10.200.16.0/20"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = false
  tags = {
    Name = "Transit-VPC-subnet-public2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_security_group" "sg_default_sg_04ecb12526eb0eb1f" {
  name        = "default"
  description = "default VPC security group"
  vpc_id      = "vpc-08908d5dc7fed56f3"

  # NOTE: manage ingress/egress rules via aws_security_group_rule resources after import
  lifecycle { prevent_destroy = true }
}

resource "aws_security_group" "sg_default_sg_0f3317ec1b460affe" {
  name        = "default"
  description = "default VPC security group"
  vpc_id      = "vpc-09913aa02362a04b4"

  # NOTE: manage ingress/egress rules via aws_security_group_rule resources after import
  lifecycle { prevent_destroy = true }
}

resource "aws_security_group" "sg_default_sg_061c2cb3809b6aa92" {
  name        = "default"
  description = "default VPC security group"
  vpc_id      = "vpc-01cf29f8c4f8b83ab"

  # NOTE: manage ingress/egress rules via aws_security_group_rule resources after import
  lifecycle { prevent_destroy = true }
}

resource "aws_internet_gateway" "transit_vpc_igw" {
  # attachment is managed via aws_internet_gateway_attachment
  tags = {
    Name = "Transit-VPC-igw"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_internet_gateway" "app_vpc_igw" {
  # attachment is managed via aws_internet_gateway_attachment
  tags = {
    Name = "App-VPC-igw"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "app_vpc_rtb_private2_us_east_2b" {
  vpc_id = "vpc-09913aa02362a04b4"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "App-VPC-rtb-private2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "transit_vpc_rtb_public" {
  vpc_id = "vpc-01cf29f8c4f8b83ab"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "Transit-VPC-rtb-public"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "transit_vpc_rtb_private1_us_east_2a" {
  vpc_id = "vpc-01cf29f8c4f8b83ab"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "Transit-VPC-rtb-private1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "rtb_03e8bdebcb3b0eac4" {
  vpc_id = "vpc-09913aa02362a04b4"
  # NOTE: individual routes managed via aws_route resources
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "rtb_08bf47714cab9d533" {
  vpc_id = "vpc-01cf29f8c4f8b83ab"
  # NOTE: individual routes managed via aws_route resources
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "app_vpc_rtb_private1_us_east_2a" {
  vpc_id = "vpc-09913aa02362a04b4"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "App-VPC-rtb-private1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "transit_vpc_rtb_private2_us_east_2b" {
  vpc_id = "vpc-01cf29f8c4f8b83ab"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "Transit-VPC-rtb-private2-us-east-2b"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "app_vpc_rtb_public" {
  vpc_id = "vpc-09913aa02362a04b4"
  # NOTE: individual routes managed via aws_route resources
  tags = {
    Name = "App-VPC-rtb-public"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_route_table" "rtb_05f069f74eb4dca41" {
  vpc_id = "vpc-08908d5dc7fed56f3"
  # NOTE: individual routes managed via aws_route resources
  lifecycle { prevent_destroy = true }
}

resource "aws_eip" "eip_16_59_31_102" {
  domain = "vpc"
  # network_interface = "eni-059eccdfef7106503"
  tags = {
    Name = "App-VPC-eip-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_nat_gateway" "app_vpc_nat_public1_us_east_2a" {
  subnet_id         = "subnet-02c431784659f64a2"
  connectivity_type = "public"
  allocation_id     = "eipalloc-0146a50001a31c1b8"
  tags = {
    Name = "App-VPC-nat-public1-us-east-2a"
  }
  lifecycle { prevent_destroy = true }
}


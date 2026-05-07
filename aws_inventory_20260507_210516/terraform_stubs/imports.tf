# Terraform import blocks — Account: 791382210557 — 20260507_210516
# Requires Terraform >= 1.5
# Usage:
#   terraform init
#   terraform plan -generate-config-out=generated.tf
#   terraform apply

import {
  to = aws_iam_user.user_admin
  id = "admin"
}

import {
  to = aws_iam_user.user_muite
  id = "muite"
}

import {
  to = aws_iam_user.user_terraform1
  id = "Terraform1"
}

import {
  to = aws_iam_user.user_wingutec_user
  id = "wingutec-user"
}

import {
  to = aws_iam_user.user_wingutecweb
  id = "wingutecweb"
}

import {
  to = aws_s3_bucket.bucket_cf_templates_194oi5gopobgf_eu_west_1
  id = "cf-templates-194oi5gopobgf-eu-west-1"
}

import {
  to = aws_s3_bucket.bucket_cf_templates_1gojhcbg0d146_us_east_1
  id = "cf-templates-1gojhcbg0d146-us-east-1"
}

import {
  to = aws_s3_bucket.bucket_cf_templates_1gojhcbg0d146_us_east_2
  id = "cf-templates-1gojhcbg0d146-us-east-2"
}

import {
  to = aws_s3_bucket.bucket_cf_templates_dcsuine5qkrq0_us_east_1
  id = "cf-templates-dcsuine5qkrq0-us-east-1"
}

import {
  to = aws_s3_bucket.bucket_cloudfront_06062024_muite
  id = "cloudfront-06062024-muite"
}

import {
  to = aws_s3_bucket.bucket_codepipeline_us_east_1_a15c123f9011_4ecc_9533_b260df0
  id = "codepipeline-us-east-1-a15c123f9011-4ecc-9533-b260df03f347"
}

import {
  to = aws_s3_bucket.bucket_config_bucket_791382210557
  id = "config-bucket-791382210557"
}

import {
  to = aws_s3_bucket.bucket_elasticbeanstalk_ap_southeast_2_791382210557
  id = "elasticbeanstalk-ap-southeast-2-791382210557"
}

import {
  to = aws_s3_bucket.bucket_elasticbeanstalk_us_east_1_791382210557
  id = "elasticbeanstalk-us-east-1-791382210557"
}

import {
  to = aws_s3_bucket.bucket_gateway_endpoint
  id = "gateway-endpoint"
}

import {
  to = aws_s3_bucket.bucket_nmuiteafrica
  id = "nmuiteafrica"
}

import {
  to = aws_s3_bucket.bucket_nmuitebilling
  id = "nmuitebilling"
}

import {
  to = aws_s3_bucket.bucket_nmuitesaa
  id = "nmuitesaa"
}

import {
  to = aws_s3_bucket.bucket_terraform_bucket_c40daa3956dc60f41398
  id = "terraform-bucket-c40daa3956dc60f41398"
}

import {
  to = aws_s3_bucket.bucket_terraform_bucket_c40daa3956dc60f41398_private
  id = "terraform-bucket-c40daa3956dc60f41398-private"
}

import {
  to = aws_s3_bucket.bucket_terraform2_3375436aa2f669f4
  id = "terraform2-3375436aa2f669f4"
}

import {
  to = aws_s3_bucket.bucket_test_vpc_s3_muite
  id = "test-vpc-s3-muite"
}

import {
  to = aws_s3_bucket.bucket_vpc_flow_logs__muite
  id = "vpc-flow-logs--muite"
}

import {
  to = aws_s3_bucket.bucket_website_bucket_ngm
  id = "website-bucket-ngm"
}

import {
  to = aws_s3_bucket.bucket_wingutec_co_za
  id = "wingutec.co.za"
}

import {
  to = aws_s3_bucket.bucket_wingutec_com
  id = "wingutec.com"
}

import {
  to = aws_route53_zone.zone_sub_wingutec_com_
  id = "Z0223148Y0QMU9EC4HN0"
}

import {
  to = aws_route53_zone.zone_wingutec_com_
  id = "Z03057922XS7XY6ERI7UU"
}

import {
  to = aws_route53_zone.zone_wingutec_com_
  id = "Z054543211R8052HVFLDP"
}

import {
  to = aws_acm_certificate.cert_muite_et_lab_be
  id = "arn:aws:acm:us-east-1:791382210557:certificate/357512de-490a-4400-8a32-ac5101a1f02f"
}

import {
  to = aws_cloudfront_distribution.cf_e2ishgzrxzj9ol
  id = "E2ISHGZRXZJ9OL"
}

import {
  to = aws_vpc.transit_vpc_vpc
  id = "vpc-01cf29f8c4f8b83ab"
}

import {
  to = aws_vpc.app_vpc_vpc
  id = "vpc-09913aa02362a04b4"
}

import {
  to = aws_vpc.vpc_08908d5dc7fed56f3
  id = "vpc-08908d5dc7fed56f3"
}

import {
  to = aws_subnet.app_vpc_subnet_private2_us_east_2b
  id = "subnet-048a42530699d855c"
}

import {
  to = aws_subnet.app_vpc_subnet_public2_us_east_2b
  id = "subnet-09c39916d10189af9"
}

import {
  to = aws_subnet.transit_vpc_subnet_private2_us_east_2b
  id = "subnet-05472b345c70c4153"
}

import {
  to = aws_subnet.transit_vpc_subnet_public1_us_east_2a
  id = "subnet-08369fa63b5a20160"
}

import {
  to = aws_subnet.transit_vpc_subnet_private1_us_east_2a
  id = "subnet-0e3d6bd981181a5f2"
}

import {
  to = aws_subnet.app_vpc_subnet_public1_us_east_2a
  id = "subnet-02c431784659f64a2"
}

import {
  to = aws_subnet.app_vpc_subnet_private1_us_east_2a
  id = "subnet-0e1a07aece9b594f8"
}

import {
  to = aws_subnet.transit_vpc_subnet_public2_us_east_2b
  id = "subnet-06457a1f8cc2b5601"
}

import {
  to = aws_security_group.sg_default_sg_04ecb12526eb0eb1f
  id = "sg-04ecb12526eb0eb1f"
}

import {
  to = aws_security_group.sg_default_sg_0f3317ec1b460affe
  id = "sg-0f3317ec1b460affe"
}

import {
  to = aws_security_group.sg_default_sg_061c2cb3809b6aa92
  id = "sg-061c2cb3809b6aa92"
}

import {
  to = aws_internet_gateway.transit_vpc_igw
  id = "igw-06acede568817075c"
}

import {
  to = aws_internet_gateway.app_vpc_igw
  id = "igw-09a60ef207386dc02"
}

import {
  to = aws_route_table.app_vpc_rtb_private2_us_east_2b
  id = "rtb-0ef74a69803dcffcb"
}

import {
  to = aws_route_table.transit_vpc_rtb_public
  id = "rtb-03a6274c2e4009d04"
}

import {
  to = aws_route_table.transit_vpc_rtb_private1_us_east_2a
  id = "rtb-095a457d0a9b1f9e9"
}

import {
  to = aws_route_table.rtb_03e8bdebcb3b0eac4
  id = "rtb-03e8bdebcb3b0eac4"
}

import {
  to = aws_route_table.rtb_08bf47714cab9d533
  id = "rtb-08bf47714cab9d533"
}

import {
  to = aws_route_table.app_vpc_rtb_private1_us_east_2a
  id = "rtb-04c9ff5223f9b0ebc"
}

import {
  to = aws_route_table.transit_vpc_rtb_private2_us_east_2b
  id = "rtb-0e6c5ea10f7eeeb80"
}

import {
  to = aws_route_table.app_vpc_rtb_public
  id = "rtb-0c4453e3da436b3ec"
}

import {
  to = aws_route_table.rtb_05f069f74eb4dca41
  id = "rtb-05f069f74eb4dca41"
}

import {
  to = aws_eip.eip_16_59_31_102
  id = "eipalloc-0146a50001a31c1b8"
}

import {
  to = aws_nat_gateway.app_vpc_nat_public1_us_east_2a
  id = "nat-0dca74180b0ca836a"
}


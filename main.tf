# skript has some preconditions:
# 1. create aws root-account
# 2. select in settings, that iam-user can view billing-information
# 3. create 1 iam-user called admin-infrastructure or something like that -> this user will not be attached to groups or something like that of this skript
#   on this user the infrastructure will be provisiond (he is somehow independent of the others
#   since maybe in development, the admin group will be destroyed and ...
#   because of that that user is a separat admin for the infrastructure)
# 4. create ssh-key for ec2; iam-user access-key; create inline/lightweight policy the managed policy
#   "AdministratorAccess" and attach this to the created iam-user; insert here the credentials
# 5. run skript
# 6. login into aws browser-console + assign pw to each user
# 7. for accessing the cluster, leave this infrastructure admin as it is and grep one of the admin-accounts, which where created

# https://docs.aws.amazon.com/de_de/vpc/latest/userguide/vpc-subnets-commands-example.html
# terraform graph | dot -Tsvg > graph.svg

#define variables
variable "server_port_http" {
  description = "The port the server will use for HTTP requests"
  type        = number
  default     = 80
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "availability-zone" {
  description = "AWS primary availability-zone"
  type        = string
  default     = "a"
}

variable "jumphost-private-ip" {
  description = "private internal ip of jumphost"
  type = string
  default = "10.0.1.10"
}

# for eks we need 2 subnets, each in a different az
variable "availability-zone_second" {
  description = "AWS secondary availability-zone"
  type        = string
  default     = "b"
}

variable "bucketname" {
  description = "Name of the s3-bucket"
  type        = string
  default     = "s3-0"
}

output "ssh_private_key_pem" {
  value = tls_private_key.ssh.private_key_pem
}

output "ssh_public_key_pem" {
  value = tls_private_key.ssh.public_key_pem
}

# define output
output "eip-jumphost" {
  value       = aws_eip.eip_jumphost.public_ip
  description = "The public IP of the eip"
}

output "one-created-admin-username" {
  value = aws_iam_user.create-admin1_dev_main.name
}


# specify registry/namespace of provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.20.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.0.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "2.0.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "3.0.0"
    }

    template = {
      source  = "hashicorp/template"
      version = "2.2.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
  }

  required_version = "~> 0.14"
}

# specify provider
provider "aws" {
  region = var.region
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name = "ssh-key-terraform"
  public_key = tls_private_key.ssh.public_key_openssh
}

# iam
resource "aws_iam_user" "create-admin1_dev_main" {
  name = "admin1"
}

resource "aws_iam_user" "create-admin2_dev_main" {
  name = "admin2"
}

resource "aws_iam_user" "create-admin3_dev_main" {
  name = "admin3"
}

resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length        = 8
  require_lowercase_characters   = true
  require_numbers                = false
  require_uppercase_characters   = false
  require_symbols                = false
  allow_users_to_change_password = true
}

resource "aws_iam_group" "admin-group_dev_main" {
  name = "AdministratorGroup"
}

resource "aws_iam_group_policy_attachment" "policy-attachment-to-admin-group_dev_main" {
  group      = aws_iam_group.admin-group_dev_main.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_group_membership" "add-admin-user-to-admin-group_dev_main" {
  name = "add-admin-user-to-admin-group"
  users = [
    aws_iam_user.create-admin1_dev_main.name,
    aws_iam_user.create-admin2_dev_main.name,
    aws_iam_user.create-admin3_dev_main.name,
  ]
  group = aws_iam_group.admin-group_dev_main.name
}

resource "aws_iam_role" "role-to-access-s3_dev_main" {
  name = "role-to-access-s3_dev_main"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    Name = "role-to-access-s3"
  }
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.role-to-access-s3_dev_main.name
}

resource "aws_iam_role_policy" "policy-to-access-s3_dev_main" {
  name = "policy-to-access-s3_dev_main"
  role = aws_iam_role.role-to-access-s3_dev_main.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

# policy for s3, to be able to write logs from cloudtrail to the bucket
# https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
# https://github.com/tmknom/terraform-aws-s3-cloudtrail/blob/master/main.tf
data "aws_iam_policy_document" "default" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = [
      "s3:GetBucketAcl",
    ]
    resources = [
      "arn:aws:s3:::${var.bucketname}",
    ]
  }
  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::${var.bucketname}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values = [
        "bucket-owner-full-control",
      ]
    }
  }
}


# create vpc
resource "aws_vpc" "vpc_dev_main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    iac_environment                             = "development"
  }
}



# create an gw for the vpc
resource "aws_internet_gateway" "gw_dev_main" {
  vpc_id = aws_vpc.vpc_dev_main.id
  tags = {
    "environment" = "development"
  }
}

# adds a routing table to the vpc (there is already a "main-routing-table")
#   one for public traffic
#   one for private traffic (actually not needed for now since main-routing-table exists)

resource "aws_route_table" "rt_public_dev_main" {
  vpc_id = aws_vpc.vpc_dev_main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw_dev_main.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.gw_dev_main.id
  }
  tags = {
    Name          = "public subnet rt"
    "environment" = "development"
  }
}

# eip for all traffic
resource "aws_eip" "nat_gateway" {
  vpc = true
  depends_on                = [aws_internet_gateway.gw_dev_main]
}

# nat for all traffic
# routing: (evt. priv subnet) -> nat (with eip) -> public subnet -> public subnet attached route-table -> gateway
# in contrast jumphost: host with eip-attached nic -> public subnet -> public subnet attached route-table -> gateway
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_gateway.id
  # subnet in which to place nat
  subnet_id = aws_subnet.subnet_public.id
  tags = {
    "Name" = "DummyNatGateway"
  }
}


# create aws vpc endpoint for s3
#   access to s3 wget https://s3-0.s3.eu-central-1.amazonaws.com/Screenshot+from+2020-06-20+20-22-29.png
#   -> forbidden -> we need to add role to ec2
resource "aws_vpc_endpoint" "endpoint-s3_dev_main" {
  vpc_id       = aws_vpc.vpc_dev_main.id
  service_name = "com.amazonaws.${var.region}.s3"
  tags = {
    "Name"        = "s3 bucket endpoint"
    "environment" = "development"
  }
}

# create route table association for s3-endpoint
#   with that its possible to access s3-service from private subnet without leaving vpc
#   verify the added route: https://eu-central-1.console.aws.amazon.com/vpc/home?region=eu-central-1#RouteTables:sort=routeTableId
#
#   for now we create an association for public subnet also
resource "aws_vpc_endpoint_route_table_association" "vpc-endpoint-rt-public-association-s3_dev_main" {
  route_table_id  = aws_route_table.rt_public_dev_main.id
  vpc_endpoint_id = aws_vpc_endpoint.endpoint-s3_dev_main.id
}


# s3 bucket
# access example file: https://s3-0.s3.eu-central-1.amazonaws.com/Screenshot+from+2020-06-20+20-22-29.png
resource "aws_s3_bucket" "s3-0_dev_main" {
  bucket        = var.bucketname
  policy        = data.aws_iam_policy_document.default.json
  force_destroy = true
  acl           = "private"

  versioning {
    enabled = true
  }
  tags = {
    "Name"        = "first s3 bucket"
    "environment" = "development"
  }
}


# cloudtrail
resource "aws_cloudtrail" "simple-cloud-trail" {
  name                          = "tf-trail-foobar"
  s3_bucket_name                = aws_s3_bucket.s3-0_dev_main.id
  s3_key_prefix                 = "test-prefix-s3"
  include_global_service_events = true
}
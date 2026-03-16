terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — create this S3 bucket + DynamoDB table manually first,
  # or switch to a local backend for getting started.
  backend "s3" {
    bucket         = "tipsytypes-terraform-state"
    key            = "kubernetes/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "tipsytypes-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  env = terraform.workspace # "dev" or "prod"

  instance_type = {
    dev  = "t3.small"
    prod = "t3.medium"
  }

  disk_size = {
    dev  = 30
    prod = 40
  }

  # prod uses apex + wildcard; dev gets a *.dev subdomain
  subdomain_prefix = local.env == "prod" ? "" : "${local.env}."

  name_prefix = "tipsytypes-${local.env}"

  common_tags = {
    Environment = local.env
    Project     = "tipsytypes"
    ManagedBy   = "terraform"
  }
}

# ── AMI ──────────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── SSH key pair ─────────────────────────────────────────────────────────────
resource "aws_key_pair" "main" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# ── Security group ────────────────────────────────────────────────────────────
resource "aws_security_group" "k8s" {
  name        = "${local.name_prefix}-sg"
  description = "Allow HTTP, HTTPS, SSH for minikube k8s node"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-sg" })
}

# ── IAM: allow EC2 to pull from ECR ──────────────────────────────────────────
resource "aws_iam_role" "ec2_ecr" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2_ecr.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_ecr" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.ec2_ecr.name
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "k8s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = local.instance_type[local.env]
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ecr.name

  root_block_device {
    volume_size = local.disk_size[local.env]
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    environment  = local.env
    domain       = var.domain
    aws_region   = var.aws_region
    infra_repo   = var.infra_repo_url
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-k8s" })
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
resource "aws_eip" "k8s" {
  instance = aws_instance.k8s.id
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.name_prefix}-eip" })
}

# ── Route53 ──────────────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  name = var.domain
}

# Wildcard: *.tipsytypes.com (prod) or *.dev.tipsytypes.com (dev)
resource "aws_route53_record" "wildcard" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.${local.subdomain_prefix}${var.domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.k8s.public_ip]
}

# Apex record only for prod
resource "aws_route53_record" "apex" {
  count   = local.env == "prod" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 60
  records = [aws_eip.k8s.public_ip]
}

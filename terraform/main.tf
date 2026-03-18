terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

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
  name_prefix = "tipsytypes"

  common_tags = {
    Project   = "tipsytypes"
    ManagedBy = "terraform"
  }
}

# ── AMI ──────────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── SSH key pair ──────────────────────────────────────────────────────────────
resource "aws_key_pair" "main" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# ── Security group ────────────────────────────────────────────────────────────
resource "aws_security_group" "k8s" {
  name        = "${local.name_prefix}-sg"
  description = "Allow HTTP, HTTPS, SSH"

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

# ── Single EC2 instance (hosts both dev + prod namespaces) ────────────────────
resource "aws_instance" "k8s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ecr.name

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    environment = "shared"
    domain      = var.domain
    aws_region  = var.aws_region
    infra_repo  = var.infra_repo_url
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-k8s" })
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
resource "aws_eip" "k8s" {
  instance = aws_instance.k8s.id
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.name_prefix}-eip" })
}

# ── ECR Repositories ─────────────────────────────────────────────────────────
resource "aws_ecr_repository" "apps" {
  for_each             = toset(var.ecr_repos)
  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, { Name = each.key })
}

# ── Route53 ──────────────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  name = var.domain
}

# *.tipsytypes.com → prod apps
resource "aws_route53_record" "wildcard_prod" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.k8s.public_ip]
}

# *.dev.tipsytypes.com → dev apps
resource "aws_route53_record" "wildcard_dev" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.dev.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.k8s.public_ip]
}

# Apex
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 60
  records = [aws_eip.k8s.public_ip]
}

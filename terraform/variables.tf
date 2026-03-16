variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "domain" {
  description = "Root domain name (must already be in Route53)"
  type        = string
  default     = "tipsytypes.com"
}

variable "ssh_public_key" {
  description = "SSH public key to add to EC2 instance (run: cat ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "infra_repo_url" {
  description = "HTTPS URL of this infra repo (cloned onto EC2 for helm charts)"
  type        = string
  default = "https://github.com/delta619/kubernetes-subdomain-multi-app.git"
}

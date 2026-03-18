output "ec2_public_ip" {
  description = "Elastic IP of the k8s EC2 instance"
  value       = aws_eip.k8s.public_ip
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.k8s.id
}

output "ssh_command" {
  description = "SSH into the instance"
  value       = "ssh ubuntu@${aws_eip.k8s.public_ip}"
}

output "wildcard_dns_prod" {
  description = "Wildcard DNS for prod (*.tipsytypes.com)"
  value       = aws_route53_record.wildcard_prod.name
}

output "wildcard_dns_dev" {
  description = "Wildcard DNS for dev (*.dev.tipsytypes.com)"
  value       = aws_route53_record.wildcard_dev.name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = { for k, v in aws_ecr_repository.apps : k => v.repository_url }
}

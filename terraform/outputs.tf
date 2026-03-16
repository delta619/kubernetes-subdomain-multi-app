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

output "wildcard_dns" {
  description = "Wildcard DNS record pointing to this instance"
  value       = aws_route53_record.wildcard.name
}

output "instance_id" {
  description = "EC2 instance id."
  value       = aws_instance.this.id
}

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "session_manager_command" {
  description = "Open a shell on the instance without any inbound port."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.aws_region}"
}

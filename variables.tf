variable "project_name" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "terraform-cicd-demo"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.0.0/24"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs."
  type        = number
  default     = 14
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    Optional CIDRs permitted to reach port 22. Leave empty (the default) and no
    SSH ingress rule is created at all — shell access is via SSM Session Manager,
    which needs no inbound port. Only populate this for a specific, known source
    address; 0.0.0.0/0 is rejected.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs must not contain 0.0.0.0/0. Use SSM Session Manager instead of opening SSH to the internet."
  }
}

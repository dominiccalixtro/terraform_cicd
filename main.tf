provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

# Latest Amazon Linux 2023 AMI, resolved at plan time. Avoids pinning an AMI id
# that silently goes stale (and unpatched) as new images are published.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ------------------------------------------------------------------ network --

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# The default security group is created by AWS with an allow-all egress rule and
# cannot be deleted. Adopting it here with no rules leaves it deny-all, so any
# resource accidentally launched without an explicit group gets no connectivity.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-default-deny-all"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.this.id
  cidr_block = var.public_subnet_cidr

  # Public addressing is an explicit per-instance decision, not a subnet default.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-public"
  }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  gateway_id             = aws_internet_gateway.this.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "public" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public.id
}

# ---------------------------------------------------------------- flow logs --

resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_158:Flow logs for a throwaway demo VPC hold no sensitive payload data and are already encrypted at rest with an AWS-owned key. A customer-managed KMS key would add cost and key-policy surface for no gain here.
  # checkov:skip=CKV_AWS_338:14-day retention is a deliberate cost decision for a demo environment, not a compliance target. Raise flow_log_retention_days for anything real.
  name              = "/aws/vpc/${var.project_name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project_name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.project_name}-flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}

# ----------------------------------------------------------------- security --

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance"
  description = "Instance access. No inbound by default; shell access is via SSM Session Manager."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-instance"
  }
}

# Created only when ssh_allowed_cidrs is explicitly populated. Empty by default,
# so the deployed instance has no inbound rules at all.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.instance.id
  description       = "SSH from an explicitly allowed source"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# Outbound 443 only: enough for SSM Session Manager, the SSM agent and package
# updates, and nothing else. Egress is destination-unrestricted because the
# instance talks to regional AWS service endpoints whose address ranges are not
# stable; narrowing further requires interface VPC endpoints, which this demo
# deliberately does not pay for.
# trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.instance.id
  description       = "HTTPS to AWS service endpoints and package mirrors"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# ---------------------------------------------------------------- instance ---

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.project_name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# AWS-managed policy scoped to what the SSM agent needs. This replaces inbound
# SSH entirely: no key pair, no port 22, and every session is logged in CloudTrail.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.project_name}-instance"
  role = aws_iam_role.instance.name
}

# trivy:ignore:AVD-AWS-0009
resource "aws_instance" "this" {
  # checkov:skip=CKV_AWS_88:Public addressing is required for SSM connectivity without a NAT gateway or interface VPC endpoints, neither of which this demo pays for. Inbound is closed, egress is limited to 443, and IMDSv2 is enforced.
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  associate_public_ip_address = true
  ebs_optimized               = true
  monitoring                  = true

  # IMDSv2 only. IMDSv1's unauthenticated endpoint is what turns a simple SSRF
  # into stolen instance-role credentials; hop limit 1 stops a container on the
  # host from reaching it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = {
    Name = "${var.project_name}-instance"
  }
}

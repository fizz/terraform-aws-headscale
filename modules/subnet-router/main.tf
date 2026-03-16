# Data sources
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  # Auto-detect private subnets by tag (eksctl / common naming convention)
  filter {
    name   = "tag:Name"
    values = ["*Private*"]
  }
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  selected_subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.private.ids[0]
  ami_id             = var.ami_id != null ? var.ami_id : data.aws_ami.al2023_arm.id
}

# Security Group - egress only, no inbound needed for subnet router
resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-subnet-router"
  description = var.sg_description
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-subnet-router"
  })
}

# IAM Role for EC2
resource "aws_iam_role" "this" {
  name = "${var.name_prefix}-subnet-router"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-subnet-router"
  })
}

# SSM access for instance management
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Logs access
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name_prefix}/*"
      }
    ]
  })
}

# CloudWatch metrics access
resource "aws_iam_role_policy" "cloudwatch_metrics" {
  name = "cloudwatch-metrics"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# SSM Parameter access for auth key
resource "aws_iam_role_policy" "ssm_params" {
  name = "ssm-params"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter${var.auth_key_ssm_path}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-subnet-router"
  role = aws_iam_role.this.name

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-subnet-router"
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "this" {
  name              = "/${var.name_prefix}/subnet-router"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-subnet-router-logs"
  })
}

# EC2 Instance - subnet router only (no Headscale server)
resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  source_dest_check           = false # Required for subnet routing — instance forwards traffic for other IPs

  user_data = templatefile("${path.module}/userdata.sh", {
    headscale_server_url = var.headscale_server_url
    advertised_routes    = join(",", var.advertised_routes)
    advertise_tags       = var.advertise_tags
    hostname             = var.hostname
    auth_key_ssm_path    = var.auth_key_ssm_path
    aws_region           = var.aws_region
    name_prefix          = var.name_prefix
    log_retention_days   = var.log_retention_days
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30 # AL2023 AMI minimum
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-subnet-router"
  })
}

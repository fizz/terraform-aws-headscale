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

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

locals {
  selected_subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.public.ids[0]
}

data "aws_subnet" "selected" {
  id = local.selected_subnet_id
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Elastic IP for stable DNS
resource "aws_eip" "this" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = var.name_prefix
  })
}

# Security Group
resource "aws_security_group" "this" {
  name        = var.name_prefix
  description = "Headscale coordination server"
  vpc_id      = var.vpc_id

  # HTTPS for Headscale coordination + OIDC callback
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for Headscale"
  }

  # HTTP for Let's Encrypt ACME challenge
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for ACME challenge"
  }

  # Outbound for DERP relay, package updates, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(var.tags, {
    Name = var.name_prefix
  })
}

# IAM Role for EC2
resource "aws_iam_role" "this" {
  name = "${var.name_prefix}-server"

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
    Name = "${var.name_prefix}-server"
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

# SSM Parameter access for OIDC secret
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
        Resource = "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter${var.oidc_client_secret_ssm_path}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-server"
  role = aws_iam_role.this.name

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-server"
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "this" {
  name              = "/${var.name_prefix}/audit-logs"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-audit-logs"
  })
}

# Persistent cache volume for Let's Encrypt state
resource "aws_ebs_volume" "cache" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-cache"
  })
}

# EC2 Instance
resource "aws_instance" "this" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = local.selected_subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = var.ssh_key_name

  user_data = templatefile("${path.module}/userdata.sh", {
    headscale_domain            = var.domain
    oidc_issuer                 = var.oidc_issuer
    oidc_client_id              = var.oidc_client_id
    allowed_domains             = join(",", var.allowed_domains)
    advertised_routes           = join(",", var.advertised_routes)
    aws_region                  = data.aws_region.current.id
    cache_volume_id             = aws_ebs_volume.cache.id
    name_prefix                 = var.name_prefix
    acl_policy                  = var.acl_policy
    magic_dns_domain            = var.magic_dns_domain
    advertise_tags              = var.advertise_tags
    hostname                    = var.hostname
    oidc_client_secret_ssm_path = var.oidc_client_secret_ssm_path
    log_retention_days          = var.log_retention_days
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = var.name_prefix
  })
}

# Attach cache volume
resource "aws_volume_attachment" "cache" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.cache.id
  instance_id = aws_instance.this.id
}

# Associate EIP with instance
resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

# DNS record (conditional)
resource "aws_route53_record" "this" {
  count = var.route53_zone_id != null ? 1 : 0

  zone_id         = var.route53_zone_id
  name            = var.domain
  type            = "A"
  ttl             = 300
  records         = [aws_eip.this.public_ip]
  allow_overwrite = true
}

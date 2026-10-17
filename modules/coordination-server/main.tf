# Data sources
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
  description = var.sg_description
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
  name = var.name_prefix

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
    Name = var.name_prefix
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
  name = var.name_prefix
  role = aws_iam_role.this.name

  tags = merge(var.tags, {
    Name = var.name_prefix
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

# Persistent volume for the Let's Encrypt cache, the Headscale database and the noise key
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
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = local.selected_subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = var.ssh_key_name

  # The user data only mounts the volume, and the SSM association below does the
  # rest. A change to the configuration runs the association again and does not
  # replace the instance. A change to the user data itself still replaces it.
  user_data_replace_on_change = true

  # IMDSv2 only.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  user_data = templatefile("${path.module}/userdata.sh", {
    cache_volume_id = aws_ebs_volume.cache.id
    name_prefix     = var.name_prefix
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

# --- Provisioning ------------------------------------------------------------
#
# The instance is configured by an SSM Command document, not by the user data.
# The association runs the document when it is created, when the document or the
# instance changes, and on a schedule. Each step is idempotent, so a run that fails
# can run again on the same instance, and a schedule run puts back a change made by
# hand.
#
# The steps run in order, and a failed step does not stop the steps after it. The
# command and the association then show the failure. Observability runs first, so
# that its logs and metrics do not depend on any later step.

locals {
  provision_common = file("${path.module}/provision/common.sh")

  provision_vars = {
    log_group                   = aws_cloudwatch_log_group.this.name
    headscale_version           = var.headscale_version
    headscale_domain            = var.domain
    oidc_issuer                 = var.oidc_issuer
    oidc_client_id              = var.oidc_client_id
    oidc_client_secret_ssm_path = var.oidc_client_secret_ssm_path
    aws_region                  = data.aws_region.current.id
    acl_policy                  = var.acl_policy
    magic_dns_domain            = var.magic_dns_domain
    split_dns                   = jsonencode(var.split_dns)
    advertised_routes           = join(",", var.advertised_routes)
    advertise_tags              = var.advertise_tags
    hostname                    = var.hostname
  }

  provision_steps = [
    { name = "observability", file = "01-observability.sh" },
    { name = "headscale", file = "02-headscale.sh" },
    { name = "router", file = "03-router.sh" },
  ]
}

resource "aws_ssm_document" "provision" {
  name            = "${var.name_prefix}-provision"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure the Headscale coordination server ${var.name_prefix}"
    mainSteps = [
      for step in local.provision_steps : {
        action = "aws:runShellScript"
        name   = step.name
        inputs = {
          timeoutSeconds = "900"
          runCommand = [
            join("\n", [
              local.provision_common,
              templatefile("${path.module}/provision/${step.file}", local.provision_vars),
            ])
          ]
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-provision"
  })
}

resource "aws_ssm_association" "provision" {
  name                = aws_ssm_document.provision.name
  association_name    = "${var.name_prefix}-provision"
  document_version    = aws_ssm_document.provision.latest_version
  schedule_expression = var.provision_schedule
  compliance_severity = "HIGH"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  # Terraform waits for the first run and fails the apply if a step fails, so a
  # broken configuration shows in the apply and not only on the instance.
  wait_for_success_timeout_seconds = var.provision_wait_seconds

  depends_on = [
    aws_volume_attachment.cache,
    aws_eip_association.this,
    aws_route53_record.this,
  ]
}

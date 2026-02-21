terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket         = "my-terraform-state"
  #   key            = "headscale/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "headscale"
      ManagedBy = "terraform"
    }
  }
}

module "headscale" {
  source = "../../modules/coordination-server"

  vpc_id            = var.vpc_id
  subnet_id         = var.subnet_id
  domain            = var.headscale_domain
  oidc_issuer       = var.oidc_issuer
  oidc_client_id    = var.oidc_client_id
  allowed_domains   = var.allowed_domains
  advertised_routes = var.advertised_routes
  advertise_tags    = var.advertise_tags
  hostname          = var.hostname
  instance_type     = var.instance_type
  ssh_key_name      = var.ssh_key_name
  route53_zone_id   = var.route53_zone_id

  acl_policy = jsonencode({
    tagOwners = {
      (var.advertise_tags) = var.allowed_domains
    }

    autoApprovers = {
      routes = {
        (var.advertise_tags) = var.advertised_routes
      }
    }

    acls = [
      {
        action = "accept"
        src    = ["*"]
        dst    = ["*:*"]
      }
    ]
  })
}

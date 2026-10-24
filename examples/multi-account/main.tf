# Multi-account Headscale deployment example
#
# This example shows both modules together for illustration. In production,
# run each environment as a separate Terraform root with its own state backend.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

# ---------- providers ----------

provider "aws" {
  alias  = "dev"
  region = var.aws_region

  assume_role {
    role_arn = var.dev_role_arn
  }

  default_tags {
    tags = {
      Project     = "headscale"
      ManagedBy   = "terraform"
      Environment = "dev"
    }
  }
}

provider "aws" {
  alias  = "prod"
  region = var.aws_region

  assume_role {
    role_arn = var.prod_role_arn
  }

  default_tags {
    tags = {
      Project     = "headscale"
      ManagedBy   = "terraform"
      Environment = "prod"
    }
  }
}

# ---------- coordination server (dev account) ----------

module "coordination_server" {
  source = "../../modules/coordination-server"

  ami_id = var.ami_id

  providers = {
    aws = aws.dev
  }

  vpc_id            = var.dev_vpc_id
  domain            = var.headscale_domain
  oidc_issuer       = var.oidc_issuer
  oidc_client_id    = var.oidc_client_id
  allowed_domains   = var.allowed_domains
  advertised_routes = var.dev_advertised_routes
  advertise_tags    = var.dev_advertise_tags

  acl_policy = jsonencode({
    tagOwners = {
      (var.dev_advertise_tags)  = var.allowed_domains
      (var.prod_advertise_tags) = var.allowed_domains
    }

    autoApprovers = {
      routes = {
        (var.dev_advertise_tags)  = var.dev_advertised_routes
        (var.prod_advertise_tags) = var.prod_advertised_routes
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

# ---------- subnet router (prod account) ----------

module "subnet_router" {
  source = "../../modules/subnet-router"

  ami_id = var.ami_id

  providers = {
    aws = aws.prod
  }

  vpc_id               = var.prod_vpc_id
  headscale_server_url = module.coordination_server.headscale_url
  advertised_routes    = var.prod_advertised_routes
  advertise_tags       = var.prod_advertise_tags
  hostname             = var.prod_hostname
  aws_region           = var.aws_region
}

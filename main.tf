module "coordination_server" {
  source = "./modules/coordination-server"

  name_prefix                 = var.name_prefix
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  domain                      = var.domain
  oidc_issuer                 = var.oidc_issuer
  oidc_client_id              = var.oidc_client_id
  oidc_client_secret_ssm_path = var.oidc_client_secret_ssm_path
  allowed_domains             = var.allowed_domains
  advertised_routes           = var.advertised_routes
  advertise_tags              = var.advertise_tags
  hostname                    = var.hostname
  magic_dns_domain            = var.magic_dns_domain
  split_dns                   = var.split_dns
  acl_policy                  = var.acl_policy
  instance_type               = var.instance_type
  ssh_key_name                = var.ssh_key_name
  route53_zone_id             = var.route53_zone_id
  log_retention_days          = var.log_retention_days
  sg_description              = var.sg_description
  ami_id                      = var.ami_id
  tags                        = var.tags
}

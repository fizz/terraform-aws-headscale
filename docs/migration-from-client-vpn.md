# Migrating from AWS Client VPN to Headscale

## Why migrate

AWS Client VPN costs $72/endpoint/month in association fees alone, before connection-hour charges. A realistic monthly bill for a small team with two endpoints (dev + prod) lands between $150 and $500. Headscale runs on a single t4g.nano instance at approximately $3/month.

Beyond cost, Client VPN requires per-VPC endpoints. Each VPC you want to reach needs its own endpoint, subnet associations, authorization rules, SAML provider configuration, ACM certificates, and `.ovpn` client profiles. Headscale replaces all of this with one coordination server and optional subnet routers that advertise routes to any VPC in any account.

## What you gain

- **98%+ cost reduction.** One t4g.nano replaces multiple Client VPN endpoints.
- **Multi-account subnet routing from a single server.** The coordination server advertises routes to its local VPC. Remote VPCs in other accounts get a lightweight subnet router instance that joins the tailnet and advertises their CIDRs. No VPC peering required for client access.
- **OIDC authentication.** Google Workspace, Okta, or any OIDC provider. No SAML metadata XML, no IAM SAML providers.
- **Automatic TLS.** Let's Encrypt via built-in ACME. No ACM certificate imports, no manual renewal.
- **Audit logging.** CloudWatch Logs with configurable retention.
- **One client for all environments.** Tailscale client connects to the coordination server and reaches every advertised route. No per-environment `.ovpn` profiles.

## What you lose

- **AWS-managed high availability.** Client VPN is a managed service with built-in redundancy. Headscale runs on a single EC2 instance. This is mitigated by EBS persistence (state survives instance replacement) and fast `terraform apply` rebuilds, but it is not HA.
- **Native SAML SSO.** Client VPN integrates directly with AWS IAM SAML providers. Headscale uses OIDC instead. If your IdP supports OIDC (most do), this is a lateral move. If you depend on SAML-only federation, you will need an OIDC bridge.
- **Server-side split tunneling configuration.** Client VPN push-routes control which traffic enters the tunnel. With Headscale/Tailscale, split tunneling is configured client-side via the Tailscale app. This is arguably better (the client decides), but it is a different operational model.

## Network coverage mapping

Each VPC that had a Client VPN endpoint becomes either a local route on the coordination server or a remote subnet router. The pattern:

| AWS Client VPN setup | Headscale equivalent |
|---|---|
| VPN endpoint in dev VPC (e.g. `172.31.0.0/16`) | Coordination server in dev VPC advertises `172.31.0.0/16` via `advertised_routes` |
| VPN endpoint in prod VPC (e.g. `10.0.0.0/16`) | Subnet router in prod VPC advertises `10.0.0.0/16` via `advertised_routes` |
| Subnet association per AZ | Not needed. One instance per VPC, routing is IP-level |
| Authorization rules per CIDR | ACL policy in Headscale config (`acl_policy` variable) |
| SAML provider per account | Single OIDC provider on the coordination server |
| `.ovpn` profile per environment | One Tailscale client connection covers all environments |

**Example — vanguard.dev with two accounts:**

```
                   ┌─────────────────────────────┐
                   │  Dev account (coordination)  │
                   │  VPC: 172.31.0.0/16          │
                   │  EKS: 10.29.0.0/16           │
                   │                              │
                   │  coordination-server module   │
                   │  advertised_routes:           │
                   │    - 172.31.0.0/16            │
                   │    - 10.29.0.0/16             │
                   └──────────┬───────────────────┘
                              │ tailnet
                   ┌──────────┴───────────────────┐
                   │  Prod account (subnet router) │
                   │  VPC: 10.0.0.0/16             │
                   │                               │
                   │  subnet-router module          │
                   │  advertised_routes:            │
                   │    - 10.0.0.0/16               │
                   └───────────────────────────────┘
```

With Client VPN, this required two separate endpoints ($144/month base), two SAML providers, two sets of subnet associations and auth rules, and two `.ovpn` profiles. With Headscale, it is two t4g.nano instances (~$6/month total) and one Tailscale client connection.

If a remote VPC only needs narrow access (e.g. a single RDS endpoint), advertise a /32 instead of the full CIDR to avoid route conflicts between accounts with overlapping IP ranges.

## Migration steps

### 1. Deploy the coordination server

Use the `coordination-server` module in your primary account. See `examples/single-account/` for a minimal configuration or `examples/multi-account/` for cross-account setups.

```hcl
module "headscale" {
  source = "github.com/your-org/terraform-aws-headscale//modules/coordination-server"

  vpc_id            = "vpc-xxxxxxxx"
  domain            = "vpn.vanguard.dev"
  oidc_client_id    = var.oidc_client_id
  allowed_domains   = ["vanguard.dev"]
  advertised_routes = ["172.31.0.0/16"]
  advertise_tags    = "tag:infra"

  acl_policy = jsonencode({
    tagOwners     = { "tag:infra" = ["vanguard.dev"] }
    autoApprovers = { routes = { "tag:infra" = ["172.31.0.0/16"] } }
    acls          = [{ action = "accept", src = ["*"], dst = ["*:*"] }]
  })
}
```

Store the OIDC client secret in SSM Parameter Store at `/headscale/oidc-client-secret` before applying.

### 2. Deploy subnet routers in remote accounts

For each additional VPC/account, deploy the `subnet-router` module:

```hcl
module "subnet_router" {
  source = "github.com/your-org/terraform-aws-headscale//modules/subnet-router"

  vpc_id               = "vpc-yyyyyyyy"
  headscale_server_url = "https://vpn.vanguard.dev"
  advertised_routes    = ["10.0.0.0/16"]
  advertise_tags       = "tag:infra"
  hostname             = "prod-subnet-router"
}
```

Generate a pre-auth key from the coordination server and store it in SSM at `/headscale/auth-key` in the remote account before applying.

### 3. Verify connectivity

Install the Tailscale client and connect to the coordination server:

```bash
tailscale login --login-server https://vpn.vanguard.dev
```

Verify routes are advertised:

```bash
tailscale status
```

Test connectivity to resources in each VPC (e.g. `ping`, `psql`, `curl` to internal endpoints).

### 4. Decommission Client VPN

Once all team members have confirmed connectivity through Headscale:

1. Remove Client VPN authorization rules (prevents new connections).
2. Wait for active sessions to drain or notify users.
3. Delete subnet associations, routes, and the endpoint itself.
4. Remove the ACM certificates and SAML providers if no longer needed.
5. Delete `.ovpn` profiles from client machines.

If you managed Client VPN with Terraform, `terraform destroy` handles steps 1-4.

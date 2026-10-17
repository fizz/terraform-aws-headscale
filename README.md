# terraform-aws-headscale

Self-hosted Headscale VPN on AWS. One Terraform module, one t4g.nano, ~$3/mo.

## What this is

Terraform modules for deploying [Headscale](https://github.com/juanfont/headscale) (open-source Tailscale coordination server) on AWS. OIDC authentication, automatic Let's Encrypt TLS, CloudWatch audit logging, and multi-account subnet routing. The coordination server runs both Headscale and a Tailscale subnet router on a single EC2 instance -- single-account deployments need nothing else.

## Architecture

**Single account** -- one instance does everything:

```
┌──────────────────────────────────┐
│  coordination-server (t4g.nano)  │
│  ┌────────────┐ ┌──────────────┐ │
│  │  Headscale  │ │  Tailscale   │ │──▶ VPC routes
│  │ coordinator │ │ subnet router│ │
│  └────────────┘ └──────────────┘ │
└──────────────────────────────────┘
```

**Multi-account** -- add subnet routers in other VPCs/accounts:

```
┌──────────────────┐     ┌──────────────────┐
│ Dev account       │     │ Prod account      │
│ coordination-    │     │ subnet-router     │
│ server           │◀────│ (Tailscale only)  │
│ (Headscale +     │     │ Advertises prod   │
│  Tailscale)      │     │ VPC routes        │
└──────────────────┘     └──────────────────┘
```

Clients connect to the coordination server with `tailscale up --login-server=https://vpn.vanguard.dev`, authenticate via OIDC, and get routed to any advertised subnet across all connected accounts.

## Quick start

1. Copy the single-account example:

```bash
cp -r examples/single-account/ my-deployment/
cd my-deployment/
cp terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars` with your values:

```hcl
aws_region        = "us-east-1"
vpc_id            = "vpc-0abc123def456"
headscale_domain  = "vpn.vanguard.dev"
oidc_client_id    = "123456789-abc.apps.googleusercontent.com"
allowed_domains   = ["vanguard.dev"]
advertised_routes = ["10.0.0.0/16"]
advertise_tags    = "tag:vanguard-dev"
ami_id            = "ami-0123456789abcdef0"
```

`ami_id` has no default. Look up the current Amazon Linux 2023 arm64 AMI for your region:

```bash
aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64 \
  --query Parameter.Value --output text
```

A new AMI replaces the instance, so it changes only when you change this value.

3. Store your OIDC client secret in SSM Parameter Store:

```bash
aws ssm put-parameter \
  --name /headscale/oidc-client-secret \
  --type SecureString \
  --value "your-oidc-client-secret"
```

4. Deploy:

```bash
terraform init
terraform apply
```

**Prerequisites:** An existing VPC with a public subnet, a Route53 hosted zone (optional -- you can point DNS manually), and a Google Workspace (or other OIDC provider) OAuth client.

## Multi-account setup

See `examples/multi-account/` for a complete example. The pattern:

1. Deploy `coordination-server` in your primary account (runs Headscale + Tailscale).
2. Generate a pre-auth key on the Headscale server and store it in SSM in each target account.
3. Deploy `subnet-router` in each additional account/VPC. It connects back to the coordination server and advertises its local VPC routes.

The ACL policy on the coordination server must include tags and autoApprovers for all subnet routers. The multi-account example shows this.

## Modules

### coordination-server

Headscale coordinator + built-in Tailscale subnet router on a single EC2 instance. Creates an EIP, security group, IAM instance profile, CloudWatch log group, EBS volume for the state, an SSM document and association that configure the instance, and an optional Route53 A record.

#### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vpc_id` | VPC ID for the Headscale instance | `string` | -- | yes |
| `domain` | FQDN for the Headscale server (e.g. `vpn.vanguard.dev`) | `string` | -- | yes |
| `oidc_client_id` | OIDC client ID | `string` | -- | yes |
| `allowed_domains` | Email domains allowed to authenticate via OIDC | `list(string)` | -- | yes |
| `advertised_routes` | CIDR ranges to advertise via the built-in subnet router | `list(string)` | -- | yes |
| `advertise_tags` | Headscale ACL tag applied to the subnet-router node (e.g. `tag:infra`) | `string` | -- | yes |
| `ami_id` | Amazon Linux 2023 arm64 AMI ID. A change replaces the instance | `string` | -- | yes |
| `acl_policy` | Full Headscale ACL policy as a JSON string | `string` | -- | yes |
| `name_prefix` | Prefix for all resource names | `string` | `"headscale"` | no |
| `subnet_id` | Public subnet ID (auto-detected from VPC if not set) | `string` | `null` | no |
| `oidc_issuer` | OIDC issuer URL | `string` | `"https://accounts.google.com"` | no |
| `oidc_client_secret_ssm_path` | SSM path containing the OIDC client secret | `string` | `"/headscale/oidc-client-secret"` | no |
| `hostname` | Tailscale hostname for the built-in subnet router node | `string` | `"subnet-router"` | no |
| `magic_dns_domain` | MagicDNS base domain inside the tailnet | `string` | `"vpn.internal"` | no |
| `instance_type` | EC2 instance type | `string` | `"t4g.nano"` | no |
| `ssh_key_name` | EC2 key pair name | `string` | `null` | no |
| `route53_zone_id` | Route53 hosted zone ID for DNS record (skipped if null) | `string` | `null` | no |
| `log_retention_days` | CloudWatch log group retention in days | `number` | `365` | no |
| `headscale_version` | Headscale release to install, as its GitHub tag. A change installs it on the running instance | `string` | `"v0.29.5"` | no |
| `provision_schedule` | How often the provisioning association runs again, to put back changes made by hand | `string` | `"rate(1 day)"` | no |
| `provision_wait_seconds` | How long `terraform apply` waits for a provisioning run to succeed. 0 does not wait | `number` | `1200` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

#### Provisioning

The user data only mounts the EBS volume. An SSM Command document, `<name_prefix>-provision`, configures the rest. An SSM association runs the document when Terraform creates it, when the document or the instance changes, and again on `provision_schedule`. The document has three steps, which run in this order:

1. **observability:** installs the CloudWatch agent and ships `/var/log/headscale.log`, the provisioning log and the user-data log to the log group, with disk, memory and swap metrics.
2. **headscale:** installs the pinned `headscale_version` and writes the config, the ACL policy and the systemd unit. It restarts Headscale only when one of them changed.
3. **router:** installs Tailscale and joins the instance as the subnet router for `advertised_routes`, then approves the routes.

Every step is idempotent. A step that fails does not stop the steps after it, and the command and the association show the failure. Observability runs first, so its logs do not depend on a later step. `terraform apply` waits for the first run and fails when a step fails (`provision_wait_seconds`).

A change to the ACL policy, the split DNS, the routes or the Headscale version runs the document again on the running instance. It does not replace the instance. To run it again by hand, use the `provision_run_command` output. The `provision_status_command` output shows the result of the latest run.

Package installs wait for the rpm database. At boot, the Inspector VM scanner holds the rpm lock while it lists the packages, and dnf does not wait for that lock. The steps wait with `fuser` and retry.

#### State and instance replacement

A change to the user data, the AMI or the instance type replaces the instance. The state is on the EBS volume, which stays when the instance is replaced:

- `/var/lib/headscale/cache/state/`: the Headscale database and the noise key
- `/var/lib/headscale/cache/tailscale/`: the node identity of the built-in subnet router
- `/var/lib/headscale/cache/`: the Let's Encrypt cache

The new instance starts with the nodes and the server identity of the old one, and clients reconnect without a new login. If the volume is not mounted, the headscale and router steps stop and report a failure. They do not start with an empty database.

**Upgrade from 2.2 to 3.0.** The upgrade replaces the instance once. The state is already on the volume, so no manual step is necessary.

**Upgrade from 2.1 or earlier.** Before 2.2, the database and the noise key were on the root disk, and a replacement deleted them. Copy the state to the volume immediately before you apply:

```bash
scripts/ssm_command.sh 'systemctl stop headscale && mkdir -p /var/lib/headscale/cache/state && cp -a /var/lib/headscale/db.sqlite* /var/lib/headscale/*private.key /var/lib/headscale/cache/state/ && chown -R headscale:headscale /var/lib/headscale/cache/state'
```

The command stops Headscale so that the copy of the database is complete. The tailnet stays down until the new instance starts.

#### Outputs

| Name | Description |
|------|-------------|
| `instance_id` | EC2 instance ID |
| `elastic_ip` | Elastic IP address |
| `headscale_url` | Headscale server URL (e.g. `https://vpn.vanguard.dev`) |
| `connect_command` | Command for users to connect (`tailscale up --login-server=...`) |
| `ssm_connect` | SSM command to connect to the instance |
| `security_group_id` | Security group ID |
| `log_group` | CloudWatch log group for audit logs |
| `provision_association_id` | SSM association that configures the instance |
| `provision_status_command` | Command that shows the result of the latest provisioning run |
| `provision_run_command` | Command that runs the provisioning again now |

### subnet-router

Tailscale-only instance for additional accounts/VPCs. Connects outbound to the coordination server, advertises local VPC routes. No inbound ports required.

#### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vpc_id` | VPC ID for the subnet router instance | `string` | -- | yes |
| `headscale_server_url` | URL of the Headscale coordination server | `string` | -- | yes |
| `advertised_routes` | CIDR ranges to advertise via the subnet router | `list(string)` | -- | yes |
| `advertise_tags` | Headscale ACL tag applied to this node (e.g. `tag:infra`) | `string` | -- | yes |
| `ami_id` | Amazon Linux 2023 arm64 AMI ID. A change replaces the instance | `string` | -- | yes |
| `name_prefix` | Prefix for all resource names | `string` | `"headscale"` | no |
| `subnet_id` | Private subnet ID (auto-detected from VPC if not set) | `string` | `null` | no |
| `hostname` | Tailscale hostname for this node | `string` | `"subnet-router"` | no |
| `auth_key_ssm_path` | SSM path containing the Headscale pre-auth key | `string` | `"/headscale/auth-key"` | no |
| `instance_type` | EC2 instance type | `string` | `"t4g.nano"` | no |
| `aws_region` | AWS region (used in userdata for SSM API calls) | `string` | `"us-east-1"` | no |
| `log_retention_days` | CloudWatch log group retention in days | `number` | `365` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

#### Outputs

| Name | Description |
|------|-------------|
| `instance_id` | EC2 instance ID |
| `private_ip` | Private IP address |
| `advertised_routes` | Routes advertised by this subnet router |
| `security_group_id` | Security group ID |
| `iam_role_arn` | IAM role ARN for the instance |

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/headscale_status.sh` | Query Headscale users, nodes, and routes via SSM (no SSH required) |
| `scripts/ssm_command.sh` | Run an arbitrary command on the Headscale instance via SSM |
| `scripts/ssm_session.sh` | Start an interactive SSM session on the Headscale instance |

All scripts auto-discover the instance by its `Name` tag. Override with env vars: `PROFILE`, `REGION`, `TAG_NAME`, `INSTANCE_ID`.

## CI/CD

A reference GitHub Actions workflow pattern is described in `examples/`. The modules themselves have zero coupling to any CI system -- they work with Terraform Cloud, Spacelift, Atlantis, or local CLI.

For GitHub Actions users: a directory-based discovery pattern works well. Each environment gets its own directory with a `main.tf` calling the appropriate module. The workflow scans for directories, runs the coordination server first, then all subnet routers in parallel.

## Cost

A t4g.nano running 24/7 costs ~$3/mo. Add ~$0.005/hr per additional subnet router.

For comparison: AWS Client VPN costs $72/endpoint/month before connection-hour charges ($0.05/hr per active connection). Three endpoints with moderate usage runs $250-500/mo.

## License

Apache 2.0. See [LICENSE](LICENSE).

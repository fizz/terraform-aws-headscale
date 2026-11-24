# advertised_routes is left out: the router advertises nothing.

mock_provider "aws" {}

variables {
  vpc_id               = "vpc-0123456789abcdef0"
  subnet_id            = "subnet-0123456789abcdef0"
  headscale_server_url = "https://vpn.example.com"
  advertise_tags       = "tag:infra"
  ami_id               = "ami-0123456789abcdef0"
}

run "advertised_routes_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(output.advertised_routes) == 0
    error_message = "advertised_routes does not default to an empty list."
  }
}

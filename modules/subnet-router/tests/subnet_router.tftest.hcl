# Plan-only tests with a mocked AWS provider. No AWS call is made.
#   terraform -chdir=modules/subnet-router init -backend=false
#   terraform -chdir=modules/subnet-router test

mock_provider "aws" {}

variables {
  vpc_id               = "vpc-0123456789abcdef0"
  subnet_id            = "subnet-0123456789abcdef0"
  headscale_server_url = "https://vpn.example.com"
  advertised_routes    = ["10.0.0.0/16"]
  advertise_tags       = "tag:infra"
  ami_id               = "ami-0123456789abcdef0"
}

# The user data of v5.0.0, rendered with the variables above. A change to the user
# data replaces the instance, so it must not move.
run "defaults_keep_the_v5_plan" {
  command = plan

  assert {
    condition = aws_instance.this.user_data == templatefile("${path.module}/tests/fixtures/userdata-v5.0.0.sh", {
      headscale_server_url = "https://vpn.example.com"
      advertised_routes    = "10.0.0.0/16"
      advertise_tags       = "tag:infra"
      hostname             = "subnet-router"
      auth_key_ssm_path    = "/headscale/auth-key"
      aws_region           = "us-east-1"
      name_prefix          = "headscale"
      log_retention_days   = 365
    })
    error_message = "The default user data differs from v5.0.0."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].volume_size == 30
    error_message = "The default root volume is not 30 GiB."
  }

  assert {
    condition     = length(aws_ssm_document.client_gateway) == 0 && length(aws_ssm_association.client_gateway) == 0
    error_message = "The defaults create a client gateway document or association."
  }
}

run "accept_routes" {
  command = plan

  variables {
    accept_routes = true
  }

  assert {
    condition     = length(aws_ssm_association.client_gateway) == 1
    error_message = "accept_routes does not create the association."
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "ACCEPT_ROUTES=true")
    error_message = "The document does not set accept-routes."
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "accept-routes")
    error_message = "accept_routes changed the user data, which replaces the instance."
  }
}

run "masquerade_cidrs" {
  command = plan

  variables {
    masquerade_cidrs = ["10.0.0.0/16", "10.1.0.0/24"]
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "MASQUERADE_CIDRS=\"10.0.0.0/16 10.1.0.0/24\"")
    error_message = "The document does not carry both ranges."
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "ACCEPT_ROUTES=false")
    error_message = "accept-routes is not off by default in the document."
  }
}

run "clamp_mss_to_pmtu" {
  command = plan

  variables {
    clamp_mss_to_pmtu  = true
    provision_schedule = "rate(12 hours)"
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "CLAMP_MSS=true")
    error_message = "The document does not clamp the MSS."
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "FORWARD -o tailscale0 -p tcp")
    error_message = "The document does not clamp the SYN that leaves through tailscale0."
  }

  assert {
    condition     = strcontains(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0], "FORWARD -i tailscale0 -p tcp")
    error_message = "The document does not clamp the SYN-ACK that comes back through tailscale0."
  }

  assert {
    condition     = aws_ssm_association.client_gateway[0].schedule_expression == "rate(12 hours)"
    error_message = "provision_schedule is not used."
  }
}

# The script is embedded whole in the document content, and every plan that changes
# it prints it whole. This keeps it short.
run "document_stays_small" {
  command = plan

  variables {
    accept_routes     = true
    clamp_mss_to_pmtu = true
    masquerade_cidrs  = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(jsondecode(aws_ssm_document.client_gateway[0].content).mainSteps[0].inputs.runCommand[0]) < 4096
    error_message = "The client gateway script is 4096 characters or more."
  }
}

run "root_volume_size" {
  command = plan

  variables {
    root_volume_size = 50
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].volume_size == 50
    error_message = "root_volume_size is not used."
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "50")
    error_message = "root_volume_size reached the user data."
  }
}

run "empty_advertised_routes" {
  command = plan

  variables {
    advertised_routes = []
    accept_routes     = true
    masquerade_cidrs  = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(output.advertised_routes) == 0
    error_message = "The output is not empty."
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "--advertise-routes= \\")
    error_message = "The router does not join with an empty route list."
  }
}

run "network_interface_id_output" {
  command = apply

  assert {
    condition     = output.network_interface_id == aws_instance.this.primary_network_interface_id
    error_message = "network_interface_id is not the instance's primary interface."
  }

  assert {
    condition     = output.network_interface_id != ""
    error_message = "network_interface_id is empty."
  }
}

run "bad_masquerade_cidr" {
  command = plan

  variables {
    masquerade_cidrs = ["10.0.0.0/33"]
  }

  expect_failures = [var.masquerade_cidrs]
}

run "masquerade_cidr_without_prefix" {
  command = plan

  variables {
    masquerade_cidrs = ["10.0.0.1"]
  }

  expect_failures = [var.masquerade_cidrs]
}

run "root_volume_below_the_ami_size" {
  command = plan

  variables {
    root_volume_size = 7
  }

  expect_failures = [var.root_volume_size]
}

run "root_volume_fraction" {
  command = plan

  variables {
    root_volume_size = 20.5
  }

  expect_failures = [var.root_volume_size]
}

data "aws_ami" "selected" {
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_key_pair" "ssh" {
  key_name = var.ssh_key_name
}

resource "aws_instance" "api" {
  ami                         = data.aws_ami.selected.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  key_name                    = data.aws_key_pair.ssh.key_name
  associate_public_ip_address = false
  iam_instance_profile        = var.iam_instance_profile_name

  # First-boot setup: installs Docker, clones the api + infra repos, prepares
  # the SQLite data dir. See bootstrap.sh for details. The script only runs
  # on a *new* instance — `ignore_changes` below keeps edits from triggering
  # a replacement that would wipe the SQLite DB on the existing host.
  user_data = templatefile("${path.module}/bootstrap.sh", {
    api_repo_url   = var.bootstrap.api_repo_url
    infra_repo_url = var.bootstrap.infra_repo_url
    mcp_repo_url   = var.bootstrap.mcp_repo_url
    agent_repo_url = var.bootstrap.agent_repo_url
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-api"
  }

  # Pin AMI so a new Ubuntu publish doesn't replace the host (and wipe the SQLite DB).
  # user_data is ignored for the same reason — editing bootstrap.sh should not
  # recreate the live host. To roll either deliberately, taint this resource.
  #
  # associate_public_ip_address is ignored because of a quirk in the AWS provider:
  # once aws_eip_association.api attaches an EIP, AWS reports the primary ENI as
  # having a public IP and the provider surfaces that as `true` — drifting from
  # the configured `false`. EC2 doesn't allow toggling that attribute in-place,
  # so without this entry every subsequent apply forces a destroy+recreate.
  lifecycle {
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}

resource "aws_eip" "api" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-api-eip"
  }
}

resource "aws_eip_association" "api" {
  instance_id   = aws_instance.api.id
  allocation_id = aws_eip.api.id
}

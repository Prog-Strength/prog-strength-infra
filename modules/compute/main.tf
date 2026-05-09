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
  # To roll the AMI deliberately, taint this resource.
  lifecycle {
    ignore_changes = [ami]
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

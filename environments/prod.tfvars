aws_region        = "us-east-2"
project_name      = "prog-strength"
environment       = "prod"
availability_zone = "us-east-2b"

vpc_cidr           = "10.0.0.0/16"
public_subnet_cidr = "10.0.1.0/24"

instance_type    = "t4g.small"
ami_name_pattern = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
ami_owner        = "099720109477"
ssh_key_name     = "prog-strength-backend-prod-keys"
root_volume_size = 8

ingress_rules = [
  {
    description = "SSH"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  },
  {
    description = "HTTP (Caddy ACME challenge + redirect)"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  },
  {
    description = "HTTPS"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  },
]

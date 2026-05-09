resource "aws_security_group" "api" {
  name        = "${var.name_prefix}-api"
  description = "Ingress for the Prog Strength API host"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

# Each ingress rule resource takes a single cidr_ipv4. We key by description, so descriptions
# must be unique. To support multiple CIDRs per logical rule, flatten across cidr_blocks here.
resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = { for r in var.ingress_rules : r.description => r }

  security_group_id = aws_security_group.api.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_blocks[0]
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.api.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

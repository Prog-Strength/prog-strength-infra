module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
}

module "security_group" {
  source = "./modules/security_group"

  name_prefix   = local.name_prefix
  vpc_id        = module.network.vpc_id
  ingress_rules = var.ingress_rules
}

module "compute" {
  source = "./modules/compute"

  name_prefix        = local.name_prefix
  subnet_id          = module.network.public_subnet_id
  security_group_ids = [module.security_group.security_group_id]
  instance_type      = var.instance_type
  ami_name_pattern   = var.ami_name_pattern
  ami_owner          = var.ami_owner
  ssh_key_name       = var.ssh_key_name
  root_volume_size   = var.root_volume_size
}

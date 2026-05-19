module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.network.vpc_cidr
  public_subnet_cidr = var.network.public_subnet_cidr
  availability_zone  = var.aws.availability_zone
}

module "security_group" {
  source = "./modules/security_group"

  name_prefix   = local.name_prefix
  vpc_id        = module.network.vpc_id
  ingress_rules = var.compute.security_group.ingress_rules
}

module "compute" {
  source = "./modules/compute"

  name_prefix        = local.name_prefix
  subnet_id          = module.network.public_subnet_id
  security_group_ids = [module.security_group.security_group_id]
  instance_type      = var.compute.instance_type
  ami_name_pattern   = var.compute.ami_name_pattern
  ami_owner          = var.compute.ami_owner
  ssh_key_name       = var.compute.ssh_key_name
  root_volume_size   = var.compute.root_volume_size
  bootstrap          = var.compute.bootstrap
}

module "backup" {
  source = "./modules/backup"

  name_prefix                        = local.name_prefix
  bucket_name                        = var.backup.bucket_name
  noncurrent_version_expiration_days = var.backup.noncurrent_version_expiration_days
  instance_role_name                 = module.compute.instance_role_name
}

module "ecr" {
  source = "./modules/ecr"

  name_prefix                = local.name_prefix
  repository_names           = var.ecr.repository_names
  max_image_count            = var.ecr.max_image_count
  untagged_image_expire_days = var.ecr.untagged_image_expire_days
  instance_role_name         = module.compute.instance_role_name
}

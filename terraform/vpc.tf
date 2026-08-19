# ---------------------------------------------------------------------------
# VPC - creates a new one, UNLESS one tagged for this project already exists
# (sandbox/training AWS accounts are often capped at 1 VPC per region, so
# reruns must reuse whatever's already there instead of trying to create
# a second one).
# ---------------------------------------------------------------------------

# Whether to reuse a VPC Terraform doesn't manage, instead of creating one.
#
# This used to be auto-detected with a data source (look up a VPC tagged
# with this project's name). That's unstable across applies: the FIRST
# apply creates the VPC (and tags it with that name), so on the very NEXT
# plan the lookup finds the VPC Terraform itself just made. That flips
# vpc_already_exists from false -> true, which flips module.vpc's count
# from 1 -> 0 and tells Terraform to destroy the whole VPC (subnets, NAT
# gateway, everything) - and since EKS/RDS/Lambda all read vpc_id and the
# subnet ids from locals below, that flip cascades into force-replacing
# almost everything else too. Every apply after the first re-triggers it,
# which is why any change looked like "destroy and recreate everything."
#
# Set this explicitly instead. Once Terraform has created (or imported)
# the VPC, leave this false so Terraform keeps managing module.vpc[0] the
# normal way. Only set it true if you're intentionally pointing at a VPC
# that lives outside this Terraform config.
variable "use_existing_vpc" {
  description = "Reuse a VPC Terraform doesn't manage instead of creating one. Leave false once Terraform has created/adopted the VPC."
  type        = bool
  default     = false
}

locals {
  vpc_already_exists = var.use_existing_vpc
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  count = local.vpc_already_exists ? 0 : 1

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags so EKS + ALB controller can discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                     = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "shared"
  }
}

# If reusing an existing VPC, look up its subnets by tag instead.
data "aws_subnets" "existing_private" {
  count = local.vpc_already_exists ? 1 : 0
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.existing.ids
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_subnets" "existing_public" {
  count = local.vpc_already_exists ? 1 : 0
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.existing.ids
  }
  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

# Single source of truth other files should reference (eks.tf, alb, etc.)
# instead of reaching into module.vpc directly, since it may not exist.
locals {
  vpc_id = local.vpc_already_exists ? data.aws_vpcs.existing.ids[0] : module.vpc[0].vpc_id

  # Fall back to public subnets for the existing-VPC path if no
  # internal-elb-tagged private subnets are found (e.g. a bare default VPC).
  private_subnet_ids = local.vpc_already_exists ? (
    length(data.aws_subnets.existing_private[0].ids) > 0 ?
    data.aws_subnets.existing_private[0].ids :
    data.aws_subnets.existing_public[0].ids
  ) : module.vpc[0].private_subnets

  public_subnet_ids = local.vpc_already_exists ? data.aws_subnets.existing_public[0].ids : module.vpc[0].public_subnets
}

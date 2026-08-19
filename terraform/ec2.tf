# ---------------------------------------------------------------------------
# EC2 "admin box" - a public-subnet instance with aws-cli, kubectl, eksctl,
# and helm pre-installed via user_data, so you can SSH in and immediately
# run kubectl/eksctl against the EKS cluster without setting anything up
# locally. Grants its instance role cluster-admin via an EKS access entry
# (EKS 20.x uses the access-entry API, not the old aws-auth ConfigMap).
# ---------------------------------------------------------------------------

variable "admin_ec2_key_name" {
  description = "Existing EC2 key pair name for SSH access. Leave blank to launch without a key pair (SSM Session Manager only, no SSH)."
  type        = string
  default     = ""
}

variable "admin_ec2_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "admin_ec2_allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the admin box on port 22. Restrict this to your own IP (e.g. \"1.2.3.4/32\") - 0.0.0.0/0 is open to the whole internet."
  type        = string
  default     = "0.0.0.0/0"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "admin_ec2" {
  name        = "${var.project_name}-${var.environment}-admin-ec2-sg"
  description = "Admin/bastion box - SSH in, kubectl/eksctl out to the EKS API"
  vpc_id      = local.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ec2_allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "admin_ec2" {
  name = "${var.project_name}-${var.environment}-admin-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets the box run `aws eks update-kubeconfig` and generally inspect the
# cluster/other resources without hardcoding credentials.
resource "aws_iam_role_policy" "admin_ec2_eks_describe" {
  name = "eks-describe"
  role = aws_iam_role.admin_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"]
        Resource = "*"
      }
    ]
  })
}

# SSM Session Manager access as a fallback if you don't want to open port 22
# at all (leave admin_ec2_key_name blank and connect via `aws ssm start-session`).
resource "aws_iam_role_policy_attachment" "admin_ec2_ssm" {
  role       = aws_iam_role.admin_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "admin_ec2" {
  name = "${var.project_name}-${var.environment}-admin-ec2"
  role = aws_iam_role.admin_ec2.name
}

# Grants this instance's IAM role cluster-admin on the EKS cluster via the
# access-entry API (module.eks's enable_cluster_creator_admin_permissions
# only covers whichever IAM principal ran terraform apply, not this box).
resource "aws_eks_access_entry" "admin_ec2" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.admin_ec2.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin_ec2" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.admin_ec2.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_instance" "admin" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.admin_ec2_instance_type
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.admin_ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.admin_ec2.name
  associate_public_ip_address = true
  key_name                    = var.admin_ec2_key_name != "" ? var.admin_ec2_key_name : null

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    encrypted   = true
  }

  # Amazon Linux 2023 (dnf-based). Installs: aws-cli v2 (usually preinstalled
  # on al2023, upgraded here to be sure), kubectl matching the cluster's k8s
  # minor version, eksctl, and helm - then writes a kubeconfig so `kubectl`
  # works immediately for the ec2-user without running update-kubeconfig by
  # hand.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y unzip tar gzip

    # aws-cli v2
    curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update

    # kubectl (pinned to the cluster's k8s minor version)
    curl -sSLO "https://dl.k8s.io/release/v${var.eks_cluster_version}.0/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl

    # eksctl (latest)
    curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl

    # helm (latest)
    curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # kubeconfig for ec2-user, pointing at this cluster
    sudo -u ec2-user -H bash -c "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  EOF

  tags = {
    Name = "${var.project_name}-${var.environment}-admin-ec2"
  }

  depends_on = [module.eks]
}

output "admin_ec2_public_ip" {
  description = "SSH here (or use SSM) once user_data has finished installing eksctl/kubectl"
  value       = aws_instance.admin.public_ip
}

output "admin_ec2_ssh" {
  description = "SSH command (only works if admin_ec2_key_name was set)"
  value       = "ssh ec2-user@${aws_instance.admin.public_ip}"
}

output "admin_ec2_ssm" {
  description = "Session Manager alternative to SSH (works even without a key pair, as long as the SSM agent + IAM role are up)"
  value       = "aws ssm start-session --target ${aws_instance.admin.id} --region ${var.aws_region}"
}

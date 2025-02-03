terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"  # Will update based on preference
}

# VPC Module
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = "true"
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# EKS Module
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "eks-cluster"
  cluster_version = "1.28"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_addons = {
    aws-efs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Managed Node Group
  eks_managed_node_groups = {
    main = {
      min_size     = 1
      max_size     = 5
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      labels = {
        Environment = "dev"
      }
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# EFS File System
resource "aws_efs_file_system" "main" {
  creation_token = "eks-efs"
  encrypted      = true

  tags = {
    Name = "eks-efs"
  }
}

# EFS Mount Targets
resource "aws_efs_mount_target" "main" {
  count           = 2
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# EFS Security Group
resource "aws_security_group" "efs" {
  name        = "efs-sg"
  description = "Allow inbound NFS traffic from EKS cluster"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "NFS from EKS"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg"
  }
}
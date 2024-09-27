provider "aws" {
  region = "us-east-1"
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

resource "aws_ecr_repository" "ecr_fast_food" {
  name                 = "pos-fiap-schepis/fast-food-api"
  image_tag_mutability = "MUTABLE"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "ecr-fast-food-repo"
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.ecr_fast_food.repository_url
  description = "The URL of the ECR repository"
}

resource "aws_cognito_user_pool" "user_pool" {
  name = "${var.cluster_name}-user-pool"

  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = {
    Name = "${var.cluster_name}-user-pool"
  }
}

resource "aws_cognito_user_pool_client" "user_pool_client" {
  user_pool_id = aws_cognito_user_pool.user_pool.id
  name         = "${var.cluster_name}-user-pool-client"
  generate_secret = false
}

resource "aws_api_gateway_rest_api" "api_gateway" {
  name        = "${var.cluster_name}-api"
  description = "API Gateway for ${var.cluster_name}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.cluster_name}-api-gateway"
  }
}

resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  parent_id   = aws_api_gateway_rest_api.api_gateway.root_resource_id
  path_part   = "items"
}

resource "aws_api_gateway_method" "get_method" {
  rest_api_id   = aws_api_gateway_rest_api.api_gateway.id
  resource_id   = aws_api_gateway_resource.resource.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_integration" {
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.get_method.http_method
  type        = "MOCK"
}

resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"

  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "eks-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

resource "aws_subnet" "private" {
  count = 3
  vpc_id     = aws_vpc.eks_vpc.id
  cidr_block = element(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"], count.index)
  availability_zone = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)

  tags = {
    Name = "eks-private-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "public" {
  count = 3
  vpc_id     = aws_vpc.eks_vpc.id
  cidr_block = element(["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"], count.index)
  availability_zone = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)

  tags = {
    Name = "eks-public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "eks-public-route-table"
  }
}

resource "aws_route_table_association" "public_association" {
  count = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "eks-nat-gateway"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "eks-private-route-table"
  }
}

resource "aws_route_table_association" "private_association" {
  count = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


resource "aws_db_instance" "postgres" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "16.4"
  apply_immediately    = true
  identifier           = "postgres-db-fast-food"
  instance_class       = "db.t3.micro"
  username             = "postgres"
  password             = "postgres"
  db_name              = "fastfood"
  parameter_group_name = "default.postgres16"
  db_subnet_group_name = aws_db_subnet_group.rds_subnet.name
  skip_final_snapshot  = true
  publicly_accessible  = true 
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  tags = {
    Name = "postgres-db"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-security-group"
  }
}
resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  version  = "1.30"
  role_arn = data.aws_iam_role.lab_role.arn
  vpc_config {
    subnet_ids = aws_subnet.private[*].id
  }

  tags = {
    Name = "EKS Fast food"
  }
}

resource "aws_eks_node_group" "node_group" {
  count = 1
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "node-group-${count.index + 1}"
  node_role_arn = data.aws_iam_role.lab_role.arn
  subnet_ids = aws_subnet.private[*].id

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.small"]

  tags = {
    Name = "node-group-${count.index + 1}"
  }
}

resource "aws_db_subnet_group" "rds_subnet" {
  name       = "rds-subnet-group"
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Name = "rds-subnet-group"
  }
}


provider "aws" {
  region = "us-east-1"
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

resource "aws_ecr_repository" "ecr_fast_food" {
  name                 = "pos-fiap-schepis/fast-food-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "ecr-fast-food-repo"
  }
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.ecr_fast_food.repository_url
  description = "The URL of the ECR repository"
}

resource "aws_cognito_user_pool" "user_pool" {
  name = "${var.cluster_name}-user-pool"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  tags = {
    Name = "${var.cluster_name}-user-pool"
  }
}

resource "aws_cognito_user_pool_client" "user_pool_client" {
  user_pool_id = aws_cognito_user_pool.user_pool.id
  name         = "${var.cluster_name}-user-pool-client"

  explicit_auth_flows = ["ADMIN_NO_SRP_AUTH"]

  allowed_oauth_flows = ["implicit"]
  allowed_oauth_scopes = ["openid"]

  callback_urls = ["https://www.example.com/callback"]

  generate_secret = true
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
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
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
  count  = 3
  vpc_id = aws_vpc.eks_vpc.id
  cidr_block = element(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"], count.index)
  availability_zone = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)

  tags = {
    Name = "eks-private-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "public" {
  count  = 3
  vpc_id = aws_vpc.eks_vpc.id
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
  count     = 3
  subnet_id = aws_subnet.public[
  count.index
  ].id
  route_table_id = aws_route_table.public.id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[
  0
  ].id

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
  count     = 3
  subnet_id = aws_subnet.private[
  count.index
  ].id
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
  vpc_security_group_ids = [
    aws_security_group.rds_sg.id
  ]

  tags = {
    Name = "postgres-db"
  }

}

resource "aws_security_group" "rds_sg" {
  name   = "rds-security-group"
  vpc_id = aws_vpc.eks_vpc.id

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
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
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "node-group"
  node_role_arn   = data.aws_iam_role.lab_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.large"]

  tags = {
    Name = "node-group"
  }
}

resource "aws_db_subnet_group" "rds_subnet" {
  name       = "rds-subnet-group"
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Name = "rds-subnet-group"
  }
}

resource "aws_security_group" "alb_sg" {
  name   = "alb-security-group"
  vpc_id = aws_vpc.eks_vpc.id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-security-group"
  }
}

resource "aws_lb" "api_gateway_lb" {
  name               = "${var.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = {
    Name = "${var.cluster_name}-alb"
  }
}

resource "aws_lb_listener" "api_gateway_listener" {
  load_balancer_arn = aws_lb.api_gateway_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_gateway_target_group.arn
  }
}

data "aws_instances" "available_instances" {
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

resource "aws_lb_target_group_attachment" "tg_attachment" {
  count            = length(data.aws_instances.available_instances.ids)
  target_group_arn = aws_lb_target_group.api_gateway_target_group.arn
  target_id        = element(data.aws_instances.available_instances.ids, count.index)
  port             = 30080
}

resource "aws_lb_target_group" "api_gateway_target_group" {
  name     = "${var.cluster_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.eks_vpc.id

  health_check {
    path                = "/actuator/health/readiness"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.cluster_name}-tg"
  }
}

resource "aws_api_gateway_integration" "alb_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api_gateway.id
  resource_id             = aws_api_gateway_resource.resource.id
  http_method             = aws_api_gateway_method.get_method.http_method
  type                    = "HTTP"
  integration_http_method = "GET"
  uri                     = "https://${aws_lb.api_gateway_lb.dns_name}/"
}

data "aws_eks_cluster_auth" "eks_auth" {
  name = aws_eks_cluster.eks.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks_auth.token
}


resource "kubernetes_deployment" "sonarqube" {
  metadata {
    name = "sonarqube"
    labels = {
      app = "sonarqube"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "sonarqube"
      }
    }

    template {
      metadata {
        labels = {
          app = "sonarqube"
        }
      }

      spec {
        container {
          name  = "sonarqube"
          image = "sonarqube:lts"

          port {
            container_port = 9000
          }

          env {
            name  = "SONAR_ES_BOOTSTRAP_CHECKS_DISABLE"
            value = "true"
          }

          resources {
            requests = {
              memory = "2Gi"
              cpu    = "1"
            }
            limits = {
              memory = "4Gi"
              cpu    = "2"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "sonarqube" {
  metadata {
    name = "sonarqube"
  }

  spec {
    selector = {
      app = "sonarqube"
    }

    port {
      protocol = "TCP"
      port     = 9000
      target_port = 9000
    }

    type = "LoadBalancer"
  }
}

data "kubernetes_service" "sonarqube" {
  metadata {
    name      = "sonarqube"
    namespace = "default"
  }
  depends_on = [kubernetes_service.sonarqube]
}

output "sonarqube_load_balancer_dns" {
  value = data.kubernetes_service.sonarqube.status[0].load_balancer[0].ingress[0].hostname
  description = "The DNS name of the SonarQube LoadBalancer"
}

output "sonarqube_load_balancer_ip" {
  value = data.kubernetes_service.sonarqube.status[0].load_balancer[0].ingress[0].ip
  description = "The IP address of the SonarQube LoadBalancer"
}

resource "kubernetes_deployment" "mongodb" {
  metadata {
    name = "mongodb"
    labels = {
      app = "mongodb"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "mongodb"
      }
    }

    template {
      metadata {
        labels = {
          app = "mongodb"
        }
      }

      spec {
        container {
          name  = "mongodb"
          image = "mongo:5.0"

          port {
            container_port = 27017
          }

          env {
            name  = "MONGO_INITDB_ROOT_USERNAME"
            value = "admin" # Replace with desired username
          }

          env {
            name  = "MONGO_INITDB_ROOT_PASSWORD"
            value = "password" # Replace with a secure password
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "512Mi"
              cpu    = "250m"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mongodb" {
  metadata {
    name = "mongodb"
  }

  spec {
    selector = {
      app = "mongodb"
    }

    port {
      protocol = "TCP"
      port     = 27017
      target_port = 27017
    }

    type = "LoadBalancer"
  }
}

output "mongodb_internal_connection_url" {
  value       = "mongodb://admin:password@mongodb:27017"
  description = "MongoDB internal connection URL for POC"
}
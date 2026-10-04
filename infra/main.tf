# Standalone infra for the `alertmanager` repo -- deliberately self-contained (own VPC lookup,
# own ECS cluster, own execution role) rather than depending on ll_admin_console/backend/infra's
# main.tf, since this repo is meant to be applied into any account on its own, starting with a
# personal AWS account for prototyping before this logic ever touches Liveline's real account.
#
# See ../README.md for the two-pipeline architecture this directory implements: this file plus
# pipeline.tf are applied ONCE (by a human, or by a dedicated infra pipeline) to create the
# ECR repo + ECS service + the CodePipeline itself; from then on, every push to `main` runs
# the CodePipeline (build -> push -> deploy), which never touches Terraform or this state.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "project_name" {
  type    = string
  default = "alertmanager"
}

variable "github_full_repository_id" {
  description = "GitHub repo in owner/repo form that the CodeStar connection and pipeline Source stage track."
  type        = string
  default     = "kingsleyche67/alertmanager"
}

variable "git_branch" {
  type    = string
  default = "main"
}

data "aws_caller_identity" "current" {}

# Default VPC -- fine for personal-account testing. Swap for real private
# subnets + NAT (the way ll_admin_console's liveline_api already runs) before this
# ever targets Liveline's own account; see README.md's "Moving this to Liveline" section.
data "aws_vpc" "main" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

locals {
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-${var.environment}-cluster"

  tags = {
    Name        = "${var.project_name}-${var.environment}-cluster"
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-${var.environment}-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

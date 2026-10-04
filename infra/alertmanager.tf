# The running service itself. Same two-container sidecar pattern proven end-to-end in the
# ll_admin_console/backend/infra/sandbox-personal-account-test/ validation (SSM fetch -> shared
# volume -> alertmanager reads it) -- the only thing that changes here is where the
# "alertmanager" container's image comes from: this repo's own ECR (built by pipeline.tf),
# not the public prom/alertmanager image directly, so the version running is exactly whatever
# buildspec.yml's `docker build .` of THIS repo's Dockerfile last produced.

variable "alertmanager_cpu" {
  type    = number
  default = 256
}

variable "alertmanager_memory" {
  type    = number
  default = 512
}

variable "alertmanager_allowed_cidr_blocks" {
  description = "CIDRs allowed to reach Alertmanager on 9093. Defaults to the VPC's own CIDR."
  type        = list(string)
  default     = []
}

locals {
  alertmanager_allowed_cidr_blocks = length(var.alertmanager_allowed_cidr_blocks) > 0 ? var.alertmanager_allowed_cidr_blocks : [data.aws_vpc.main.cidr_block]
  ssm_prefix                       = "/${var.project_name}/${var.environment}"
}

# =================
# Config delivery -- Terraform seeds a placeholder once, then steps aside. Real content is
# owned by a reconciler (regenerate from the customer registry -> PutParameter ->
# force-new-deployment). See README.md's "Config delivery" section for why a plain
# `/-/reload` is NOT enough -- confirmed by testing this directly against a live task.
# =================

resource "aws_ssm_parameter" "alertmanager_config" {
  name        = "${local.ssm_prefix}/config"
  description = "Full alertmanager.yml content. Owned by the reconciler after first apply."
  type        = "SecureString"
  value       = <<-EOT
    route:
      receiver: default-fallback
      group_by: ['alertname', 'facility_id', 'cell_id']
    receivers:
      - name: default-fallback
  EOT

  lifecycle {
    ignore_changes = [value]
  }
}

# =================
# IAM -- task role (SSM read + ECS Exec)
# =================

resource "aws_iam_role" "alertmanager_task_role" {
  name = "${var.project_name}-${var.environment}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "alertmanager_task_role" {
  name = "${var.project_name}-${var.environment}-task-policy"
  role = aws_iam_role.alertmanager_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.alertmanager_config.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alias/aws/ssm"
      },
      {
        # Lets `aws ecs execute-command` shell into the running container for debugging --
        # valuable enough in practice (this is how the sandbox test diagnosed the
        # /-/reload gap) to keep on permanently, not just for one-off tests.
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      }
    ]
  })
}

# =================
# Security Groups
# =================

resource "aws_security_group" "alertmanager_nlb" {
  name        = "${var.project_name}-${var.environment}-nlb-sg"
  description = "Security group for the Alertmanager NLB"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "Alertmanager API/UI"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = local.alertmanager_allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alertmanager_tasks" {
  name        = "${var.project_name}-${var.environment}-tasks-sg"
  description = "Security group for the Alertmanager ECS task"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "From the Alertmanager NLB"
    from_port       = 9093
    to_port         = 9093
    protocol        = "tcp"
    security_groups = [aws_security_group.alertmanager_nlb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =================
# Network Load Balancer
# =================

resource "aws_lb" "alertmanager" {
  name               = "nlb-${var.project_name}-${var.environment}"
  internal           = true
  load_balancer_type = "network"
  subnets            = local.subnet_ids
  security_groups    = [aws_security_group.alertmanager_nlb.id]
}

resource "aws_lb_target_group" "alertmanager" {
  name        = "tg-${var.project_name}-${var.environment}"
  port        = 9093
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    protocol            = "HTTP"
    path                = "/-/healthy"
    port                = "9093"
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "alertmanager" {
  load_balancer_arn = aws_lb.alertmanager.arn
  port              = "9093"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alertmanager.arn
  }
}

# =================
# CloudWatch Log Group
# =================

resource "aws_cloudwatch_log_group" "alertmanager" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 30
}

# =================
# ECS Task Definition + Service
# =================

resource "aws_ecs_task_definition" "alertmanager" {
  family                   = "${var.project_name}_${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.alertmanager_cpu
  memory                   = var.alertmanager_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.alertmanager_task_role.arn

  volume {
    name = "config"
  }

  container_definitions = jsonencode([
    {
      name       = "fetch-config"
      image      = "public.ecr.aws/aws-cli/aws-cli:2.17.62"
      essential  = false
      entryPoint = ["sh", "-c"]
      command = [
        "aws ssm get-parameter --name '${aws_ssm_parameter.alertmanager_config.name}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region} > /shared/alertmanager.yml"
      ]
      mountPoints = [{ sourceVolume = "config", containerPath = "/shared" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.alertmanager.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "fetch-config"
        }
      }
    },
    {
      name      = "alertmanager"
      image     = "${aws_ecr_repository.alertmanager.repository_url}:latest"
      essential = true
      dependsOn = [{ containerName = "fetch-config", condition = "SUCCESS" }]
      command = [
        "--config.file=/shared/alertmanager.yml",
        "--storage.path=/alertmanager"
      ]
      portMappings = [{ containerPort = 9093, protocol = "tcp" }]
      mountPoints  = [{ sourceVolume = "config", containerPath = "/shared" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.alertmanager.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  # Let CodePipeline own the image tag -- without this, every `terraform apply` resets the
  # container back to the `:latest` snapshot taken at apply time, undoing whatever specific
  # `:build-N` tag the pipeline last deployed. Same reasoning as liveline_api's task
  # definition in ll_admin_console/backend/infra/main.tf.
  lifecycle {
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "alertmanager" {
  name            = "${var.project_name}_${var.environment}"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.alertmanager.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    security_groups  = [aws_security_group.alertmanager_tasks.id]
    subnets          = local.subnet_ids
    assign_public_ip = true # default VPC has no NAT gateway -- see README.md
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.alertmanager.arn
    container_name   = "alertmanager"
    container_port   = 9093
  }

  depends_on = [aws_lb_listener.alertmanager]

  # Let CodePipeline own which task-definition revision is live.
  lifecycle {
    ignore_changes = [task_definition]
  }
}

output "alertmanager_nlb_dns_name" {
  value = aws_lb.alertmanager.dns_name
}

output "alertmanager_config_param_name" {
  value = aws_ssm_parameter.alertmanager_config.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.alertmanager.repository_url
}

output "codepipeline_name" {
  value = aws_codepipeline.alertmanager.name
}

output "codestar_connection_arn" {
  description = "Open this ARN's connection in the AWS Console and authorize it -- the one manual step. See pipeline.tf's comment."
  value       = aws_codestarconnections_connection.github.arn
}

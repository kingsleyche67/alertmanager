# The CONFIG pipeline: Source (same GitHub repo/connection) -> Build (push alertmanager.yml
# to SSM, force a new ECS deployment). Deliberately separate from aws_codepipeline.alertmanager
# in pipeline.tf -- different trigger (only alertmanager.yml), different IAM (SSM+ECS, no
# ECR/docker), and no image to build, so there's no "Deploy" action here at all: the Build
# stage's own buildspec does the real work directly, the same way aws_codebuild_project.tf_pipeline_guard
# does in ll_admin_console/backend/infra/main.tf (a CodeBuild project whose entire job is AWS
# CLI calls, not a docker build).

resource "aws_iam_role" "codebuild_config" {
  name = "${var.project_name}-codebuild-config-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_config" {
  name = "${var.project_name}-codebuild-config-policy-${var.environment}"
  role = aws_iam_role.codebuild_config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.codepipeline_artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.alertmanager_config.arn
      },
      {
        # SecureString write needs GenerateDataKey against the key, not Decrypt (that's
        # only needed on the READ side -- see the task role's own policy in alertmanager.tf).
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey"]
        Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alias/aws/ssm"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.this.name}/${aws_ecs_service.alertmanager.name}"
      }
    ]
  })
}

resource "aws_codebuild_project" "config" {
  name         = "${var.project_name}-config-${var.environment}"
  description  = "Push alertmanager.yml to SSM and force-redeploy ECS to pick it up"
  service_role = aws_iam_role.codebuild_config.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "SSM_PARAM_NAME"
      value = aws_ssm_parameter.alertmanager_config.name
    }
    environment_variable {
      name  = "ECS_CLUSTER_NAME"
      value = aws_ecs_cluster.this.name
    }
    environment_variable {
      name  = "ECS_SERVICE_NAME"
      value = aws_ecs_service.alertmanager.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-config.yml"
  }

  tags = {
    Name        = "${var.project_name}-config-${var.environment}"
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_iam_role" "codepipeline_config" {
  name = "${var.project_name}-codepipeline-config-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline_config" {
  name = "${var.project_name}-codepipeline-config-policy-${var.environment}"
  role = aws_iam_role.codepipeline_config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketVersioning",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
        ]
        Resource = [
          aws_s3_bucket.codepipeline_artifacts.arn,
          "${aws_s3_bucket.codepipeline_artifacts.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.config.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.codestar_connection_arn
      }
    ]
  })
}

resource "aws_codepipeline" "config" {
  name     = "${var.project_name}-config-${var.environment}"
  role_arn = aws_iam_role.codepipeline_config.arn

  # V2 + trigger below: only fires when alertmanager.yml itself changes -- a Dockerfile or
  # infra/** commit must not redeploy config, same as the image pipeline must not rebuild
  # the image on a config-only commit (see that pipeline's own trigger block in pipeline.tf).
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.codepipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = var.github_full_repository_id
        BranchName       = var.git_branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.config.name
      }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.git_branch]
        }
        file_paths {
          includes = ["alertmanager.yml"]
        }
      }
    }
  }

  tags = {
    Name        = "${var.project_name}-config-${var.environment}"
    Environment = var.environment
    Project     = var.project_name
  }
}

output "config_codepipeline_name" {
  value = aws_codepipeline.config.name
}

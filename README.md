# alertmanager

A central Alertmanager, built and deployed via its own CodePipeline, for prototyping the
centralized-Alertmanager design before it ever touches Liveline's real AWS account. See
`ll_admin_console/backend/infra/alertmanager.tf` in the main Liveline repo for the design
this is validating, and that repo's `sandbox-personal-account-test/` for the first round of
hands-on validation (the two-container config-fetch mechanism and inhibit_rules were already
proven there; this repo is about proving the *build/deploy* side on top of that).

## Two pipelines, not one

This is the same shape already proven in `ll_admin_console/backend/infra/main.tf` for the
admin console's own API (`aws_codepipeline.backend` + the separate `terraform_pipeline`
module) -- a **Terraform/infra pipeline** and an **app pipeline** are different things with
different triggers, and the app pipeline never runs Terraform:

```
                     ┌─── runs ONCE (or whenever infra changes) ───┐
                     │          terraform apply                    │
                     │   (infra/*.tf in this repo)                 │
                     └──────────────────┬───────────────────────────┘
                                         │ creates
                                         ▼
      ECR repo │ ECS cluster+service+task-def │ CodeBuild project │ CodePipeline │ NLB

                     ┌─── runs on every `git push` to main ───┐
   GitHub ──source──▶│   CodePipeline: Source → Build → Deploy │
                     └──────────────────┬───────────────────────┘
                                         │ Build: docker build/push to ECR, write
                                         │        imagedefinitions.json
                                         │ Deploy: CodePipeline's native ECS action
                                         │         registers a new task-def revision
                                         │         with the new image, updates the service
                                         ▼
                              running Alertmanager task
```

The app pipeline (`infra/pipeline.tf`'s `aws_codepipeline.alertmanager`) **only** ever touches
the ECS *service* (new task-definition revision, new image tag) -- it has no Terraform
credentials, no state access, and no reason to need either.

### Why this doesn't fight itself

The ECS task definition and service both carry a `lifecycle.ignore_changes`:

- `aws_ecs_task_definition.alertmanager` ignores `container_definitions` -- so a routine
  `terraform apply` (changing CPU, memory, a security group rule, whatever) doesn't reset the
  running image back to whatever `:latest` happened to resolve to at apply time, undoing the
  pipeline's last real deploy.
- `aws_ecs_service.alertmanager` ignores `task_definition` -- so Terraform doesn't fight the
  pipeline over *which revision* is active either.

Terraform effectively hands off "which image is running" to the pipeline permanently, the
first time it applies. This is the exact mechanism `liveline_api`'s own task definition and
service already use in the real `ll_admin_console/backend/infra/main.tf` -- not invented for
this repo.

## Bootstrap sequence (the chicken-and-egg)

The ECS task definition needs a real `image:` value, but the only thing that ever produces a
real image is the pipeline Terraform itself creates. The order that actually resolves this:

1. **Push this repo's source first** (Dockerfile, buildspec.yml, infra/\*.tf) to
   `github.com/kingsleyche67/alertmanager` -- nothing AWS-side exists yet, this is just getting
   the source where the pipeline will later look for it.
2. **`terraform apply`** (from `infra/`, with real AWS credentials). This creates the ECR repo
   (empty), the ECS cluster/task-definition/service (pointed at `<ecr_repo>:latest`, which
   doesn't exist yet -- the service will sit unable to start a task, which is expected and
   temporary), the CodeBuild project, the CodePipeline, and a CodeStar GitHub connection.
3. **One manual step Terraform cannot finish**: the CodeStar connection comes up `PENDING`.
   Open it in the AWS Console (Developer Tools → Settings → Connections), click "Update
   pending connection," and authorize the GitHub App against this repo. There's no CLI/API
   path for this one click -- it's a one-time thing per connection, not per deploy.
4. Once authorized, the pipeline's **first execution fires automatically** (CodePipeline
   starts a run as soon as a connection with a configured trigger becomes usable, or you can
   click "Release change" manually to force it): Build stage runs `docker build` against this
   repo's one-line Dockerfile, pushes `:latest` and `:build-1` to ECR, writes
   `imagedefinitions.json`. Deploy stage registers a new task-definition revision pointing at
   `:build-1` and updates the service. The service now has a real image and stabilizes.
5. **From here on**, every `git push` to `main` re-triggers the pipeline automatically.
   Terraform is only re-run for actual infrastructure changes (a new variable, a scaling
   change, a new resource) -- never as part of a routine deploy.

## Config delivery

Alertmanager's actual routing config (per-customer Slack webhooks, inhibit_rules) is **not**
baked into the image -- the image is just the stock `prom/alertmanager` binary, re-hosted into
this repo's own ECR (same reason the existing `ll_alert_manager` repo's Dockerfile is a
one-liner: avoid Docker Hub rate limits, get ECR vulnerability scanning, pin a version
deliberately). Config flows the way `ll_admin_console/backend/infra/alertmanager.tf` already
proved out: a `fetch-config` sidecar container reads the real config from an SSM
`SecureString` parameter into a shared volume once at task start; Alertmanager reads that
file.

**Important, confirmed by testing this directly**: updating the SSM parameter and calling
`POST /-/reload` does **not** apply a new config to an already-running task -- `/-/reload`
only re-reads the *local* file, and that file is only ever written once, at task start. A
real config change (e.g. a new customer's webhook) needs:

```
1. PutParameter (new config content)
2. aws ecs update-service --force-new-deployment
```
not just step 1 + a reload call. A reconciler automating step 1 needs to also trigger step 2.

## Moving this to Liveline's real account

Two deliberate differences from how `liveline_api` actually runs, both because this targets a
personal account's default VPC for now:

- `assign_public_ip = true` on the service -- the default VPC has no NAT gateway. Liveline's
  real subnets are private-with-NAT (confirmed: `liveline_api` runs with `false` there
  successfully), so flip this when this moves.
- Uses the account's default VPC directly (`data.aws_vpc.main { default = true }`) instead of
  Liveline's real VPC/subnet IDs.

Everything else -- the pipeline shape, the `ignore_changes` pattern, the sidecar/SSM config
mechanism -- is meant to carry over unchanged.

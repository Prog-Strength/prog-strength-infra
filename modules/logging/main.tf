# --- CloudWatch log groups, one per docker-compose service -----------------
#
# Each container's stdout/stderr ships here via Docker's built-in `awslogs`
# log driver — see prog-strength-docs/sows/cloudwatch-logs.md. The driver
# auto-creates a log stream per container ID under each group, so we never
# have to enumerate streams ourselves.
#
# Groups are pre-created here (rather than via the driver's
# `awslogs-create-group` option) so the runtime IAM policy below can drop
# `logs:CreateLogGroup` for least-privilege.

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(var.service_names)

  name              = "/prog-strength/${each.key}"
  retention_in_days = var.retention_days

  tags = {
    Service = each.key
    Purpose = "container-stdout-logs"
  }
}

# --- IAM: write-only policy attached to the existing EC2 instance role -----
#
# Scoped to just the three Prog Strength log groups (and their streams) so a
# compromised host can't read other log groups or write outside this
# namespace. Authoring the policy here matches the convention modules/backup
# and modules/ecr use: domain modules own their policy + attachment, the
# role itself stays in modules/compute.

data "aws_iam_policy_document" "logs_write" {
  # CreateLogStream + PutLogEvents are the two API calls the `awslogs`
  # driver makes per container. CreateLogGroup is deliberately absent —
  # the groups above are pre-created so this permission isn't needed,
  # which means a misbehaving driver can't sprawl new groups under our
  # account.
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # ARN includes a :log-stream:* suffix because PutLogEvents acts on
    # streams, not groups. The values()-then-formatlist pattern keeps
    # the policy in sync with whatever the service_names variable
    # currently lists.
    resources = concat(
      [for g in aws_cloudwatch_log_group.service : g.arn],
      [for g in aws_cloudwatch_log_group.service : "${g.arn}:log-stream:*"],
    )
  }
}

resource "aws_iam_policy" "logs_write" {
  name        = "${var.name_prefix}-cloudwatch-logs-write"
  description = "PutLogEvents on the Prog Strength service log groups only."
  policy      = data.aws_iam_policy_document.logs_write.json
}

resource "aws_iam_role_policy_attachment" "logs_write" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.logs_write.arn
}

# --- Billing alarm: cap unexpected cost from runaway ingestion -------------
#
# AWS exposes an `EstimatedCharges` CloudWatch metric per service. We watch
# the AWSCloudWatch dimension specifically, so unrelated bill movement (EC2,
# S3, etc.) doesn't trip this alarm. No SNS target wired in v1 — the alarm
# just shows red in the console, which is enough signal for a side-project
# debugging surface. A future change can hang an SNS topic off the
# alarm_actions list without touching anything else.
#
# `count` rather than for_each so monthly_budget_usd=0 cleanly skips the
# resource for local/plan-only runs.

resource "aws_cloudwatch_metric_alarm" "logs_billing" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  alarm_name        = "${var.name_prefix}-cloudwatch-logs-cost"
  alarm_description = "Fires when estimated CloudWatch charges cross $${var.monthly_budget_usd}/month. No SNS target attached; the alarm state is the signal."

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.monthly_budget_usd
  evaluation_periods  = 1

  # EstimatedCharges is published every ~6 hours to us-east-1 only; we
  # accept that latency vs. real-time billing alarms. The 21600-second
  # period (= 6 hours) matches the publish cadence.
  metric_name = "EstimatedCharges"
  namespace   = "AWS/Billing"
  statistic   = "Maximum"
  period      = 21600

  dimensions = {
    Currency    = "USD"
    ServiceName = "AmazonCloudWatch"
  }

  # No alarm_actions: alarm state shows red in the console without paging
  # anyone. Wire SNS later when we have a unified notification channel.
  alarm_actions = []
}

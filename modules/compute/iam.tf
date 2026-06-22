# --- IAM: role + instance profile for the backend EC2 host -----------------
#
# The role itself lives here because it's a property of the instance, not
# of any one consumer (Litestream, ECR, etc.). Domain modules attach their
# own policies to this role via the `instance_role_name` output — e.g.
# the backup module attaches S3 read/write for Litestream, the ECR module
# attaches managed pull permissions. Adding a fourth domain that the
# host needs to talk to is a one-attachment change in that domain's
# module, not a refactor of who owns the role.

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api_instance" {
  name               = "${var.name_prefix}-backend-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_instance_profile" "api" {
  name = "${var.name_prefix}-backend-instance"
  role = aws_iam_role.api_instance.name
}

# Register the host as an SSM managed node. This is what lets CI deploy via
# SSM Run Command and operators break-glass via Session Manager with NO
# inbound SSH — the agent dials out to AWS over 443. AWS-managed policy;
# mirrors the additive-attachment pattern the ecr/backup modules use against
# this same role. See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.
resource "aws_iam_role_policy_attachment" "instance_ssm_core" {
  role       = aws_iam_role.api_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- IAM: role + instance profile for the API EC2 host ---------------------
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
  name               = "${var.name_prefix}-api-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_instance_profile" "api" {
  name = "${var.name_prefix}-api-instance"
  role = aws_iam_role.api_instance.name
}

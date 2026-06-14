# tflint config. The terraform ruleset's "recommended" preset catches the
# class of issues that `terraform validate` doesn't — missing version
# constraints, unused declarations, naming-convention drift, deprecated
# syntax. Run locally via the pre-commit `terraform_tflint` hook (pre-push
# stage) and in CI via .github/workflows/lint.yml.
#
# After changing plugins, run `tflint --init` to (re)install them.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

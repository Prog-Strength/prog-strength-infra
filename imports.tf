# Adopts the pre-existing GitHub OIDC identity provider (created manually,
# before this module) into state. After the first successful apply this
# block is inert; it stays as a record that the provider was imported,
# not created, by this stack. prog-strength-developer reads the same
# provider via a data source — unaffected by the import.
import {
  to = module.github_oidc.aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::650503560686:oidc-provider/token.actions.githubusercontent.com"
}

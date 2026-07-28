# Grafana alerting (provisioned)

Everything in this directory is loaded by Grafana at startup from the
read-only provisioning mount (see `monitoring/docker-compose.monitoring.yml`).
Provisioned alerting resources are **read-only in the Grafana UI** — to change
an alert, edit the YAML here and redeploy, same as the dashboards.

| File | Role | Touch when… |
|---|---|---|
| `templates.yml` | Shared Slack message format (`ps.title` / `ps.text`) | changing how ALL alerts read |
| `contact-points.yml` | `slack-alerts` webhook contact point | changing where alerts go |
| `policies.yml` | Root routing policy (grouping, repeat cadence) | changing routing/nag cadence |
| `rules-<domain>.yml` | Alert rules for one subsystem | adding/adjusting monitors |

## Adding a new monitor

1. Copy `rules-vector-memory.yml` to `rules-<domain>.yml` (or add a rule to
   an existing group). Give every rule a stable, unique `uid`.
2. Point `data[0].model.expr` at the PromQL you want (datasource UID is
   `prometheus`), set the threshold in the `__expr__` step, and set a
   `severity` label (`warning` | `critical`).
3. Write a human `summary` annotation. If a dashboard panel shows the same
   metric, add `__dashboardUid__` / `__panelId__` annotations so the Slack
   message links to it.
4. That's it — no changes to templates, contact points, policies, compose,
   or deploy plumbing. The provisioning directory is already mounted.

Gotchas:

- **No `$` in YAML content.** Grafana expands `$VAR`/`${VAR}` in provisioning
  files from the container environment (that's how the Slack webhook URL gets
  in). Use dot-context in templates (`.Labels.stage`), never `$labels`; a
  literal dollar must be written `$$`.
- **`noDataState: OK` for error counters** — counter series often don't exist
  until the first increment; absence of the series must not page.
- Counter-rate thresholds: put the threshold at the midpoint below the target
  count (e.g. `> 2.5` for "3 errors") — `increase()` extrapolates and can
  land slightly under the integer.

## Slack webhook plumbing (prod)

`SLACK_ALERTS_WEBHOOK_URL`: GitHub Actions secret (this repo) →
`.github/workflows/seed-secrets.yml` (fail-loud required gate) → Secrets
Manager `prog-strength-backend/prod/api` → `deploy/api.sh` renders `.env`
(gated in `REQUIRED_ENV_KEYS`) → grafana service env in
`docker-compose.monitoring.yml` → interpolated into `contact-points.yml`.

Rotating the webhook = update the GH secret, run the Seed Secrets workflow,
redeploy the api. Local dev falls back to a dead placeholder URL (Grafana
won't boot with an empty one); deliveries simply fail there.

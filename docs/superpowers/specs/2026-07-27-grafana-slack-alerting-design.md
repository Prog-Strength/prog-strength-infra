# Grafana Slack Alerting — Vector Memory Stage Errors

**Date:** 2026-07-27
**Status:** Approved for implementation

## Problem

The Vector Memory distillation pipeline broke silently. The `ps-vector-memory`
dashboard's "Stage errors" panel already visualizes
`api_vectormemory_stage_errors_total` with warning (1 error/hour) and critical
(3 errors/hour) reference lines, but nothing notifies anyone when those
thresholds are crossed. We need a Slack alert on that metric — and, since more
monitors are coming, a provisioned-as-code alerting pattern where adding a
monitor is a one-file change.

## Approach

Use **Grafana unified alerting, file-provisioned**, rather than adding
Prometheus Alertmanager. Grafana is already running, already provisioned from
this repo (`monitoring/grafana/provisioning/` is mounted read-only into the
container), and its alerting covers threshold evaluation, routing, and Slack
delivery without a new always-on service. Alertmanager remains the escape
hatch if we ever need cross-team routing or inhibition rules.

## File layout (the extensible pattern)

```
monitoring/grafana/provisioning/alerting/
  README.md               # how to add a new monitor
  templates.yml           # SHARED Slack message format (title + body)
  contact-points.yml      # slack-alerts contact point (webhook from env)
  policies.yml            # root notification policy → slack-alerts
  rules-vector-memory.yml # first monitor; future: rules-<domain>.yml
```

Adding a future monitor = adding one `rules-<domain>.yml` file (or a rule to
an existing group). The template, contact point, and policy are shared and
untouched. The provisioning directory is already mounted into the container,
so no compose volume changes are needed for new rule files.

### Shared message template (`templates.yml`)

Defines `ps.title` and `ps.text` Go templates used by the contact point.
The body iterates `.Alerts` and renders each alert's labels (e.g. `stage`),
summary annotation, and observed value — so rules stay declarative and the
message format is changed in exactly one place for all alerts.

Rule annotations deliberately avoid `$labels`-style template variables:
Grafana expands `$VAR` in provisioning files against the process environment
(that is how the webhook URL is injected), so `$` in YAML content is
hazardous. All dynamic rendering happens in the notification template, which
uses only dot-context (`.Labels`, `.Annotations`, `.ValueString`) — no `$`.

### Contact point (`contact-points.yml`)

One `slack-alerts` contact point, type `slack`, incoming-webhook URL
interpolated from `$SLACK_ALERTS_WEBHOOK_URL` at container startup. Resolved
notifications enabled, so recovery posts to the channel too. Single channel
for all severities; severity is conveyed in the message.

### Notification policy (`policies.yml`)

Root policy routes everything to `slack-alerts`, grouped by
`grafana_folder` + `alertname`, `repeat_interval: 4h` so a still-firing alert
re-nags every 4 hours instead of once and never again.

### First rules (`rules-vector-memory.yml`)

Folder "Prog Strength Alerts", group `vector-memory`, evaluated every 1m.
Two rules over the same instant query the dashboard panel uses:

```
sum by (stage) (increase(api_vectormemory_stage_errors_total[1h]))
```

| Rule | Threshold | Label |
|---|---|---|
| Vector Memory stage errors — warning | > 0.5 (i.e. ≥1 error/hour) | `severity: warning` |
| Vector Memory stage errors — critical | > 2.5 (i.e. ≥3 errors/hour) | `severity: critical` |

Thresholds sit at 0.5/2.5 rather than 1/3 because `increase()` extrapolates
and can report 0.97 for a single error; the half-open midpoints make "1 error"
and "3 errors" fire reliably. When critical fires, warning is also firing —
accepted (Grafana has no inhibition); the critical message makes severity
unambiguous.

- `for: 0s` — the 1h `increase()` window already smooths; no extra debounce,
  fastest notification.
- `noDataState: OK` — the counter series may not exist until the first error
  is ever recorded; absence must not page. (Pipeline-liveness deadness is a
  separate future monitor, e.g. time-since-last-sweep.)
- `execErrState: Alerting` — a broken query (metric renamed) should surface,
  matching the repo's fail-loud philosophy.
- `__dashboardUid__: ps-vector-memory` / `__panelId__: 14` annotations link
  the alert to the Stage errors panel.
- Alerting on `sum by (stage)` means the alert instance names the failing
  stage (distill, embed, …).

## Secret plumbing (mirrors PR #49 pattern)

`SLACK_ALERTS_WEBHOOK_URL` is a true secret (a webhook URL grants post
access), so it takes the Secrets Manager path, and it is **required** — a
missing webhook must not silently disable alerting (that silence is the
exact failure this work exists to fix):

1. GitHub Actions secret `SLACK_ALERTS_WEBHOOK_URL` in prog-strength-infra.
2. `.github/workflows/seed-secrets.yml` — added to the api blob **and** to
   the `required_secrets` fail-loud gate.
3. `deploy/api.sh` — added to `REQUIRED_ENV_KEYS`, so a deploy aborts before
   teardown if the rendered `.env` lacks it.
4. `monitoring/docker-compose.monitoring.yml` — grafana service gets
   `SLACK_ALERTS_WEBHOOK_URL=${SLACK_ALERTS_WEBHOOK_URL:-<placeholder>}`.
   The placeholder is a syntactically valid but dead
   `https://hooks.slack.com/services/...` URL: Grafana refuses to start when
   a slack contact point has an empty URL, so local/dev boots need a
   non-empty value; deliveries just fail harmlessly there. Prod can never
   fall through to it because of gates 2 and 3.

**Rollout consequence (deliberate):** after this merges, the next api deploy
fails at the `require_env_keys` gate until the operator (a) creates the Slack
incoming webhook, (b) adds the GH secret, (c) runs the Seed Secrets workflow.
Prod keeps serving throughout — the gate aborts before teardown.

## Out of scope

- Alertmanager, per-severity channels, paging/escalation.
- Additional monitors (sweep liveness, API latency, host disk) — each is a
  follow-up `rules-<domain>.yml`.
- UI-created alert rules — provisioned rules are read-only in the UI by
  design, matching the repo's "no clicks" philosophy.

## Testing

- `bash deploy/tests/require-env.test.sh` still passes (gate helper untouched).
- Local container check: run `grafana/grafana:12.2.1` with the provisioning
  directory mounted and a dummy `SLACK_ALERTS_WEBHOOK_URL`; assert clean
  startup (no provisioning errors in logs) and that the API reports the two
  rules, the contact point, and the template.
- Pre-commit YAML hygiene hooks cover syntax.

# Grafana API Health — Severity Thresholds & Latency Rename

## Background

The API Health dashboard (`monitoring/grafana/dashboards/api.json`, uid `ps-api`) currently surfaces health signals — goroutines, RSS, 5xx rate, latency — but most timeseries panels have no visual marker for "this value is anomalous." Operators have to remember what counts as normal for each metric.

A recent incident saw goroutine count climb to **146** (steady-state is ~20–50), which went unnoticed for longer than it should have because the panel has no visual cue for the abnormal range.

Additionally, the latency metrics (`ps_http_request_duration_seconds_*`) measure duration inside the server handler — they exclude the client⇄server network round-trip and TLS time. Today, panel titles say only "latency," which is easy to misread as end-to-end client-perceived latency.

## Goals

1. Add yellow (warning) and red (critical) horizontal threshold lines to the timeseries panels that signal API health degradation.
2. Add equivalent threshold-based coloring to the latency stat panels (stat panels don't render chart lines, but Grafana threshold steps recolor the value).
3. Rename latency panel titles and update descriptions to make clear they measure server-side latency only.

## Non-Goals

- Renaming the Prometheus metric itself (`ps_http_request_duration_seconds`). That would break historical data and require coordinated API code changes — out of scope.
- Per-series threshold overrides on the combined latency percentiles panel. A single chart-wide line at the p99-worthy mark is sufficient.
- Alerting rules (Prometheus Alertmanager or Grafana alerts). This is a dashboard visualization change only.

## Threshold Values

| Panel | ID | Yellow | Red | Reasoning |
|---|---|---|---|---|
| Goroutines | 9 | 75 | 100 | Steady-state ~20–50 per panel description; prior incident hit 146; red at 100 catches the anomaly well before incident magnitude |
| Memory (RSS) | 10 | 256 MiB | 512 MiB | API typically sits at ~25 MiB; 256 MiB is ~10× baseline (clearly anomalous); 512 MiB is ~25% of the t4g.small host's 2 GB and leaves headroom for Caddy and the OS |
| 5xx rate by route | 7 | 0.05 reqps | 0.2 reqps | ~1 err / 20s warn, ~1 err / 5s critical |
| Latency percentiles (timeseries) | 6 | 500 ms | 1 s | Single chart-wide line; "no request should take this long" |
| p95 server-side latency (stat) | 3 | 500 ms | 1 s | Stat-panel color thresholds |
| p99 server-side latency (stat) | 4 | 1 s | 2 s | p99 gets a higher bar than p95 |

Note: in the JSON, byte values are written as integer bytes (256 MiB = `268435456`, 512 MiB = `536870912`); Grafana's `bytes` unit auto-formats them.

## Renames

- Panel 3 title: `p95 latency (now)` → `p95 server-side latency (now)`
- Panel 4 title: `p99 latency (now)` → `p99 server-side latency (now)`
- Panel 6 title: `Latency percentiles (p50 / p95 / p99)` → `Server-side latency percentiles (p50 / p95 / p99)`
- Panel 6 description: prepend a sentence stating "Measured inside the server handler — excludes the client⇄server network round-trip and TLS handshake."

## Grafana JSON shape

**Timeseries panels** (panels 6, 7, 9, 10) — add to `fieldConfig.defaults`:

```json
"thresholds": {
  "mode": "absolute",
  "steps": [
    {"color": "green", "value": null},
    {"color": "yellow", "value": <warn>},
    {"color": "red", "value": <crit>}
  ]
},
"custom": {
  "thresholdsStyle": {"mode": "line"}
  // ...preserving any existing `custom` keys like stacking/fillOpacity
}
```

For panels that already define a `custom` block (panel 5 stacking; not the panels we're modifying here), the `thresholdsStyle` key merges into the existing block — we do not overwrite it.

**Stat panels** (panels 3, 4) — add the same `thresholds` block to `fieldConfig.defaults`, and remove the existing `color: {mode: "fixed", fixedColor: ...}` (since fixed color overrides threshold-driven coloring). Leave `unit` and `decimals` as-is.

## Why no per-series thresholds on panel 6

Grafana supports per-series threshold overrides via `fieldConfig.overrides`, which would let the p99 series have a different red line than p95. The complexity isn't worth it: a single line at 1 s communicates "any request that crosses this is bad" regardless of which percentile crossed it. If we later want per-percentile SLOs, those are better expressed as alerting rules than as a denser dashboard.

## Verification

After editing `api.json`:

1. `cd monitoring && docker compose -f docker-compose.monitoring.yml restart grafana` (or reload provisioning, depending on how the user runs locally).
2. Open the API Health dashboard and visually confirm: each of panels 6, 7, 9, 10 shows a yellow and red horizontal line at the documented values; panels 3 and 4 now color their values based on thresholds (green/yellow/red) instead of the previous fixed color; titles read "server-side latency" where renamed.
3. Confirm `jq . monitoring/grafana/dashboards/api.json > /dev/null` runs clean (valid JSON, no trailing-comma damage).

## Open question for follow-up (out of scope here)

The 5xx stat panel (panel 2) currently has thresholds based on a 24-hour rolling rate. The new 5xx-rate-by-route timeseries line (panel 7) uses absolute reqps over a 5-minute window. These are different units and different windows — both are useful, but worth being aware that they can disagree (a single bad minute won't move panel 2 but will trip panel 7). Not a defect; just a thing to know.

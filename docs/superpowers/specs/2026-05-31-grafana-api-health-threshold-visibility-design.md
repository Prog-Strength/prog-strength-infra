# Grafana API Health — Labeled Dashed Threshold Lines + Y-Axis Visibility

## Background

The prior spec (`2026-05-31-grafana-api-health-thresholds-design.md`) added yellow/red threshold lines and the latency rename. Once deployed, an operational gap surfaced: an operator looking at the Goroutines panel couldn't see any threshold lines at all, because typical data hovers at 20–50 goroutines while the lines sit at 75 / 100 — well above the auto-scaled Y-axis range. The threshold lines existed but were drawn outside the visible chart area.

Two other usability issues are also worth fixing in the same pass:

- The threshold lines are solid, identical in style to the data lines, so an operator skimming the chart can't tell at a glance which line is data and which is the threshold.
- The lines are unlabeled. Color alone tells you "warning vs critical" but not the value, and Grafana's `thresholdsStyle` doesn't expose any way to label native threshold lines.

## Goals

1. **Always-visible threshold lines.** The Y-axis must include the critical threshold value at all times, even when actual data is far below it. Operators should always be able to see how much headroom they have.
2. **Labeled threshold lines.** Each threshold line should appear in the legend with its severity and value (e.g. `warning (75)`).
3. **Distinguishable from data.** Threshold lines should be dashed so they read as reference lines, not measurements.

## Non-Goals

- Stat panels 3 and 4 (p95 / p99 server-side latency). These have no chart and therefore no threshold *lines*; their existing threshold-driven value coloring is unchanged.
- Stat panel 2 (5xx error rate 24h). Unchanged; its existing thresholds are fine.
- Coloring the data line itself based on threshold crossing (e.g. goroutine line turning red when it exceeds 100). The native `thresholds` block gave us that for free; removing it sacrifices that feature. The labeled dashed lines plus `softMax` cover the operator's need without it, and re-introducing data-line coloring would mean keeping the `thresholds` block alongside the new vector queries — redundant and harder to reason about.
- Alerting. Still out of scope.

## Affected Panels

Only the four timeseries panels in `monitoring/grafana/dashboards/api.json`:

- Panel id 6 — Server-side latency percentiles (p50 / p95 / p99)
- Panel id 7 — 5xx rate by route
- Panel id 9 — Goroutines
- Panel id 10 — Memory (RSS)

## Design

For each affected panel, three things change:

### 1. Replace native thresholds with labeled `vector()` query series

- Remove `fieldConfig.defaults.thresholds`.
- Remove `fieldConfig.defaults.custom.thresholdsStyle`. On the four panels touched here, `thresholdsStyle` is the only key under `custom`, so the entire `custom` block is removed too.
- Add two new Prometheus targets to the panel's `targets` array, after the existing data targets:
  - Warning: `vector(<warn_value>)` with `legendFormat: "warning (<formatted value>)"`
  - Critical: `vector(<crit_value>)` with `legendFormat: "critical (<formatted value>)"`

`vector(x)` is a Prometheus built-in that returns a constant-value vector at every query step — effectively zero cost.

The new target refIds continue the existing letter sequence (e.g. panel 6 currently has refIds A, B, C → new ones become D and E; panels 7, 9, 10 currently have refId A only → new ones become B and C).

### 2. Style the new series via field overrides

For each new target, add an entry to `fieldConfig.overrides` matching by series name. Color is a fixed yellow or red; line style is dashed.

```json
{
  "matcher": {"id": "byName", "options": "warning (75)"},
  "properties": [
    {"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
    {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
  ]
}
```

The matcher option string must match the panel's `legendFormat` exactly. The dash array `[10, 10]` is a 10-pixel dash followed by a 10-pixel gap — Grafana's standard dashed pattern.

### 3. Force the Y-axis to keep the critical line in view

Add to `fieldConfig.defaults`:

- `"min": 0` — the chart always starts at zero. This makes headroom obvious: if the data line is near the bottom and the critical dashed line is near the top, the operator immediately reads "lots of headroom."
- `"softMax": <just above critical>` — the chart always extends at least to this value, but grows if data spikes higher. The "soft" prefix means it's a floor on the upper bound, not a ceiling on data.

### Per-panel values

| Panel | Warning target | Critical target | min | softMax |
|---|---|---|---|---|
| 9 Goroutines | `vector(75)` legend `warning (75)` | `vector(100)` legend `critical (100)` | 0 | 110 |
| 10 Memory (RSS) | `vector(268435456)` legend `warning (256 MiB)` | `vector(536870912)` legend `critical (512 MiB)` | 0 | 629145600 (600 MiB) |
| 7 5xx rate by route | `vector(0.05)` legend `warning (0.05/s)` | `vector(0.2)` legend `critical (0.2/s)` | 0 | 0.25 |
| 6 Server-side latency percentiles | `vector(0.5)` legend `warning (500ms)` | `vector(1)` legend `critical (1s)` | 0 | 1.2 |

### Description blurb

Append a single sentence to each affected panel's existing description so a brand-new operator knows the dashed lines aren't data:

> Dashed yellow / red lines mark the warning and critical thresholds.

The existing description text is preserved; the new sentence goes after.

## Why remove the native thresholds entirely

A reader might reasonably ask "why not keep both — native thresholds for color shading AND vector() queries for labeled lines?" Three reasons:

1. **Visual redundancy.** Both draw a horizontal line at the same value. Two overlapping lines (one solid via threshold, one dashed via vector) is noisier, not clearer.
2. **Single source of truth.** With both present, future edits have to update the value in two places; easy to drift.
3. **The thing native thresholds give us for free that vector() doesn't — data-line color shifting when value crosses threshold — is genuinely useful, but only when the data line is colored by threshold (`color.mode: "thresholds"`). On panels 6 and 7 the data is multi-series (per route / per percentile), where threshold-based coloring doesn't fit; on panels 9 and 10 the data is single-series, where we could keep it but the operator already gets the same information from "is the data line above the dashed red line?" So the net loss is small.

## Verification

After editing `api.json`:

1. Restart the Grafana provisioning loop or wait ~30s, then hard-refresh the dashboard URL.
2. On each of the four panels, confirm:
   - The legend has two new entries — `warning (X)` and `critical (Y)`.
   - The new lines render as dashed (yellow / red).
   - When data is well below the thresholds, the Y-axis still extends up to at least the critical value (i.e., the critical line is always visible).
   - The dashed lines stay flat across the entire time window.
3. Confirm `jq . monitoring/grafana/dashboards/api.json > /dev/null` is clean.
4. Confirm the stat panels (3, 4) and the unrelated panels (1, 2, 5, 8) are visually unchanged.

## Out of scope (do NOT implement)

- Adjustments to stat panels 2, 3, 4.
- Alerting rules.
- Changes to other dashboards (`host.json`, `agent.json`).
- Coloring the data series based on threshold position.

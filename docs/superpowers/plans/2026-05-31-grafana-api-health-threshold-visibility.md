# Grafana API Health — Labeled Dashed Threshold Lines + Y-Axis Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the native dashboard threshold lines on the four API Health timeseries panels with labeled, dashed lines driven by `vector()` Prometheus queries, and lock the Y-axis lower bound at zero plus a `softMax` floor so the critical line is always in view regardless of how low actual data sits.

**Architecture:** All edits go into a single file: `monitoring/grafana/dashboards/api.json`. Each task replaces one panel's JSON block with a fully-transformed version (removed `thresholds` + `custom.thresholdsStyle`, two new `vector()` targets, two field overrides for color and dashed style, `min` + `softMax` on the Y-axis, and one sentence appended to the panel description). A final task brings up the local Grafana stack headlessly and confirms via the HTTP API that the new shape loads cleanly, then surfaces the visual check to the human.

**Tech Stack:** Grafana dashboard JSON (schemaVersion 39), Prometheus `vector()` built-in, `jq` for JSON validation, Docker Compose for running Grafana locally.

**Spec:** `docs/superpowers/specs/2026-05-31-grafana-api-health-threshold-visibility-design.md`

---

## Pre-task: Read the current dashboard

Every task below modifies one panel of `monitoring/grafana/dashboards/api.json`. Before starting any task, the implementer should `Read` that file once so the `Edit` tool has it in context. The file is ~340 lines after the v1 changes; panels are in numeric id order.

The "test" pattern from a normal codebase doesn't apply here — this is dashboard JSON with no unit-test framework. The substitute is (a) `jq` JSON-validity check per edit, and (b) a Grafana load + visual check at the end. Each implementation task is `Read → Edit → jq-validate → commit`.

A note on Unicode in descriptions: panels 6, 9, 10 have em-dashes (`—` U+2014) and/or other Unicode in their descriptions. The `new_string` blocks below contain these characters literally. Do not substitute ASCII (`--`, `->`) — preserve the bytes exactly.

---

### Task 1: Replace Goroutines panel (id 9) with labeled vector() lines + softMax

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (entire panel block for id 9)

**Spec rationale:** Steady-state is ~20–50 goroutines; thresholds at 75 / 100 mean the lines were sitting above the auto-scaled Y-axis and invisible. `min: 0` + `softMax: 110` keeps the critical line in frame; labeled `vector()` series replace the native dashed-line approach so the legend names each threshold.

- [ ] **Step 1: Apply the edit**

Use the `Edit` tool with these exact strings.

`old_string`:

```
    {
      "id": 9,
      "type": "timeseries",
      "title": "Goroutines",
      "description": "Active goroutines inside the API process. Steady-state is small (~20-50); a slow climb usually means a leak — a request handler spawning goroutines that never exit.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 20},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "go_goroutines{job=\"api\"}",
          "legendFormat": "goroutines",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 75},
              {"color": "red", "value": 100}
            ]
          },
          "custom": {
            "thresholdsStyle": {"mode": "line"}
          }
        },
        "overrides": []
      }
    }
```

`new_string`:

```
    {
      "id": 9,
      "type": "timeseries",
      "title": "Goroutines",
      "description": "Active goroutines inside the API process. Steady-state is small (~20-50); a slow climb usually means a leak — a request handler spawning goroutines that never exit. Dashed yellow / red lines mark the warning and critical thresholds.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 20},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "go_goroutines{job=\"api\"}",
          "legendFormat": "goroutines",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(75)",
          "legendFormat": "warning (75)",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(100)",
          "legendFormat": "critical (100)",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "min": 0,
          "softMax": 110
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "warning (75)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          },
          {
            "matcher": {"id": "byName", "options": "critical (100)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          }
        ]
      }
    }
```

- [ ] **Step 2: Validate JSON**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): label Goroutines threshold lines + force Y-axis floor"
```

---

### Task 2: Replace Memory (RSS) panel (id 10) with labeled vector() lines + softMax

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (entire panel block for id 10)

**Spec rationale:** API normally sits at ~25 MiB; thresholds at 256 MiB / 512 MiB were far above auto-scaled range. `min: 0` + `softMax: 629145600` (600 MiB) keeps the critical line visible.

- [ ] **Step 1: Apply the edit**

`old_string`:

```
    {
      "id": 10,
      "type": "timeseries",
      "title": "Memory (RSS)",
      "description": "Resident set size of the API process — how much physical memory it's actually holding. Compare to the host's available memory if this trends up over time.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 20},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "process_resident_memory_bytes{job=\"api\"}",
          "legendFormat": "RSS",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "bytes",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 268435456},
              {"color": "red", "value": 536870912}
            ]
          },
          "custom": {
            "thresholdsStyle": {"mode": "line"}
          }
        },
        "overrides": []
      }
    }
```

`new_string`:

```
    {
      "id": 10,
      "type": "timeseries",
      "title": "Memory (RSS)",
      "description": "Resident set size of the API process — how much physical memory it's actually holding. Compare to the host's available memory if this trends up over time. Dashed yellow / red lines mark the warning and critical thresholds.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 20},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "process_resident_memory_bytes{job=\"api\"}",
          "legendFormat": "RSS",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(268435456)",
          "legendFormat": "warning (256 MiB)",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(536870912)",
          "legendFormat": "critical (512 MiB)",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "bytes",
          "min": 0,
          "softMax": 629145600
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "warning (256 MiB)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          },
          {
            "matcher": {"id": "byName", "options": "critical (512 MiB)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          }
        ]
      }
    }
```

- [ ] **Step 2: Validate JSON**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): label Memory (RSS) threshold lines + force Y-axis floor"
```

---

### Task 3: Replace 5xx rate by route panel (id 7) with labeled vector() lines + softMax

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (entire panel block for id 7)

**Spec rationale:** Healthy state is ~0 reqps; thresholds at 0.05 / 0.2 were similarly above auto-scaled range. `min: 0` + `softMax: 0.25` keeps the critical line just below the chart ceiling, leaving a sliver of headroom above it for spikes.

- [ ] **Step 1: Apply the edit**

`old_string`:

```
    {
      "id": 7,
      "type": "timeseries",
      "title": "5xx rate by route",
      "description": "Server-side errors broken out by route. A spike here usually points at a specific handler — start there, not at infra.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "sum by (route) (rate(ps_http_requests_total{status=~\"5..\"}[5m]))",
          "legendFormat": "{{route}}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 0.05},
              {"color": "red", "value": 0.2}
            ]
          },
          "custom": {
            "thresholdsStyle": {"mode": "line"}
          }
        },
        "overrides": []
      }
    }
```

`new_string`:

```
    {
      "id": 7,
      "type": "timeseries",
      "title": "5xx rate by route",
      "description": "Server-side errors broken out by route. A spike here usually points at a specific handler — start there, not at infra. Dashed yellow / red lines mark the warning and critical thresholds.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "sum by (route) (rate(ps_http_requests_total{status=~\"5..\"}[5m]))",
          "legendFormat": "{{route}}",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(0.05)",
          "legendFormat": "warning (0.05/s)",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(0.2)",
          "legendFormat": "critical (0.2/s)",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "min": 0,
          "softMax": 0.25
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "warning (0.05/s)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          },
          {
            "matcher": {"id": "byName", "options": "critical (0.2/s)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          }
        ]
      }
    }
```

- [ ] **Step 2: Validate JSON**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): label 5xx-rate-by-route threshold lines + force Y-axis floor"
```

---

### Task 4: Replace Server-side latency percentiles panel (id 6) with labeled vector() lines + softMax

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (entire panel block for id 6)

**Spec rationale:** This panel has three existing data series (p50/p95/p99 → refIds A/B/C), so the new warning + critical targets use refIds D and E. The chart-wide threshold at 500 ms / 1 s is meant as "no request should ever take this long," not a per-percentile SLO. `softMax: 1.2` keeps the critical line just inside the top of the chart.

Note: this panel's existing description begins with `Measured inside the server handler — excludes the client⇄server network round-trip and TLS handshake.` — preserve the em-dash (`—`) and bidirectional arrow (`⇄`) characters exactly as Unicode.

- [ ] **Step 1: Apply the edit**

`old_string`:

```
    {
      "id": 6,
      "type": "timeseries",
      "title": "Server-side latency percentiles (p50 / p95 / p99)",
      "description": "Measured inside the server handler — excludes the client⇄server network round-trip and TLS handshake. Overall request latency across every route. Use the per-route variants by clicking 'Edit' on this panel and adding a label filter, or drill down via 5xx rate by route if the cause of a spike is unclear.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.50, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.95, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.99, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p99",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 0.5},
              {"color": "red", "value": 1}
            ]
          },
          "custom": {
            "thresholdsStyle": {"mode": "line"}
          }
        },
        "overrides": []
      }
    }
```

`new_string`:

```
    {
      "id": 6,
      "type": "timeseries",
      "title": "Server-side latency percentiles (p50 / p95 / p99)",
      "description": "Measured inside the server handler — excludes the client⇄server network round-trip and TLS handshake. Overall request latency across every route. Use the per-route variants by clicking 'Edit' on this panel and adding a label filter, or drill down via 5xx rate by route if the cause of a spike is unclear. Dashed yellow / red lines mark the warning and critical thresholds.",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.50, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.95, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.99, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "legendFormat": "p99",
          "refId": "C"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(0.5)",
          "legendFormat": "warning (500ms)",
          "refId": "D"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "vector(1)",
          "legendFormat": "critical (1s)",
          "refId": "E"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "min": 0,
          "softMax": 1.2
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "warning (500ms)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          },
          {
            "matcher": {"id": "byName", "options": "critical (1s)"},
            "properties": [
              {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
              {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
            ]
          }
        ]
      }
    }
```

- [ ] **Step 2: Validate JSON**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): label Server-side latency threshold lines + force Y-axis floor"
```

---

### Task 5: Headless Grafana load + surface visual check

**Files:** None modified.

The four implementation tasks each validated JSON shape via `jq`. This task confirms Grafana parses the file, queries the warning/critical series, and renders the dashboard with the new legend entries — then hands off to the human for the final by-eye check.

- [ ] **Step 1: Start (or restart) the monitoring stack**

```bash
docker compose -f monitoring/docker-compose.monitoring.yml up -d
docker compose -f monitoring/docker-compose.monitoring.yml restart grafana
```

Expected: `Container monitoring-grafana-1  Started` (or similar — container name may vary).

- [ ] **Step 2: Wait for Grafana to become healthy**

```bash
until curl -sf http://localhost:3000/api/health > /dev/null; do sleep 2; done && echo READY
```

Expected: `READY` within ~15 seconds.

- [ ] **Step 3: Confirm Grafana loaded the dashboard with the new shape**

```bash
curl -s -u admin:admin http://localhost:3000/api/dashboards/uid/ps-api \
  | jq '.dashboard.panels[] | select(.id == 6 or .id == 7 or .id == 9 or .id == 10) | {id, title, targets: (.targets | map({refId, legendFormat})), min: .fieldConfig.defaults.min, softMax: .fieldConfig.defaults.softMax, overrides: (.fieldConfig.overrides | map(.matcher.options))}'
```

Expected: for each of panels 6, 7, 9, 10:
- `min: 0`
- `softMax` matches spec (panel 6 = 1.2, panel 7 = 0.25, panel 9 = 110, panel 10 = 629145600)
- `targets` includes both `warning (...)` and `critical (...)` legendFormats with refIds B and C (D and E for panel 6)
- `overrides` matcher options exactly match those legendFormats

If any panel is missing the warning/critical targets or has unexpected `min` / `softMax`, STOP and report the discrepancy — don't try to fix on the host.

- [ ] **Step 4: Grafana provisioning-error grep**

```bash
docker compose -f monitoring/docker-compose.monitoring.yml logs grafana 2>&1 | grep -iE "error|fail|invalid" | grep -iE "dashboard|provision|api\.json|ps-api" || echo "no relevant errors"
```

Expected: `no relevant errors`.

- [ ] **Step 5: Hand off the visual check to the human**

The implementer reports DONE and surfaces the human-eye check. The human opens `http://localhost:3000/d/ps-api/api-health` (login `admin`/`admin` if prompted) and confirms, for each of panels 6, 7, 9, 10:

1. Two new legend rows appear: `warning (...)` in yellow and `critical (...)` in red.
2. Those lines render as **dashed**, not solid.
3. The Y-axis upper bound is at or above the critical value at all times (i.e., the red dashed line is visible even when data is far below it).
4. The Y-axis lower bound sits at 0.
5. The other panels (1, 2, 3, 4, 5, 8) are visually unchanged.

If the visual check uncovers something off (e.g., a dash pattern looks wrong, a color mismatched), capture the panel + issue and we'll iterate.

---

## Out of scope (do NOT implement here)

- Stat panels 2, 3, 4 — their existing thresholds and value-coloring stay as-is.
- Coloring the data series (e.g. goroutine line turning red when it crosses 100). Native thresholds gave us this for free; we deliberately gave it up for the labeled-line UX.
- Per-panel SLO alerting rules. Out of scope; alerting belongs in Prometheus Alertmanager, not Grafana.
- Changes to `host.json` or `agent.json`.

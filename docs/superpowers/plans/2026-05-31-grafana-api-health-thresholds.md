# Grafana API Health — Severity Thresholds & Latency Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add yellow/red severity threshold lines to four timeseries panels and matching threshold-based coloring to two stat panels in the API Health Grafana dashboard, and rename the latency panels to make clear they measure server-side latency only.

**Architecture:** All edits go into a single file: `monitoring/grafana/dashboards/api.json`. This is a Grafana-provisioned dashboard JSON file; there is no application code to test. Each task modifies one panel via the `Edit` tool, then validates the file is still valid JSON via `jq`. The final task does an end-to-end visual check in Grafana and commits everything.

**Tech Stack:** Grafana dashboard JSON (schemaVersion 39), Prometheus metric expressions, `jq` for JSON validation, Docker Compose for running Grafana locally.

**Spec:** `docs/superpowers/specs/2026-05-31-grafana-api-health-thresholds-design.md`

---

## Pre-task: Read the current dashboard

Every task below modifies one panel of `monitoring/grafana/dashboards/api.json`. Before starting any task, the implementer should `Read` that file once so the `Edit` tool can find the `old_string` blocks. The file is ~265 lines and panels are in numeric ID order.

A note on "tests": this is a dashboard JSON. There is no unit-test framework that asserts threshold values. The substitute is (a) `jq` validation that the JSON didn't get corrupted, and (b) a single visual check at the end against a running Grafana. The TDD step pattern ("write failing test, make it pass") doesn't apply — each task is `Edit → jq-validate → commit`.

---

### Task 1: Add threshold lines to the Goroutines timeseries panel (id 9)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 9, `fieldConfig.defaults`)

**Threshold values (from spec):** yellow 75, red 100.

- [ ] **Step 1: Apply the edit**

Use the `Edit` tool with these exact strings.

`old_string`:

```
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
        "defaults": {"unit": "short"},
        "overrides": []
      }
```

`new_string`:

```
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
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): add yellow/red threshold lines to Goroutines panel"
```

---

### Task 2: Add threshold lines to the Memory (RSS) timeseries panel (id 10)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 10, `fieldConfig.defaults`)

**Threshold values (from spec):** yellow 256 MiB (268435456 bytes), red 512 MiB (536870912 bytes). Grafana's `bytes` unit auto-formats these.

- [ ] **Step 1: Apply the edit**

`old_string`:

```
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
        "defaults": {"unit": "bytes"},
        "overrides": []
      }
```

`new_string`:

```
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
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): add yellow/red threshold lines to Memory (RSS) panel"
```

---

### Task 3: Add threshold lines to the 5xx rate by route panel (id 7)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 7, `fieldConfig.defaults`)

**Threshold values (from spec):** yellow 0.05 reqps, red 0.2 reqps.

- [ ] **Step 1: Apply the edit**

`old_string`:

```
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
        "defaults": {"unit": "reqps"},
        "overrides": []
      }
```

`new_string`:

```
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
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): add yellow/red threshold lines to 5xx-rate-by-route panel"
```

---

### Task 4: Rename + add threshold line + update description on Latency percentiles panel (id 6)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 6 — title, description, and `fieldConfig.defaults`)

**Changes (from spec):**
- Title: `Latency percentiles (p50 / p95 / p99)` → `Server-side latency percentiles (p50 / p95 / p99)`
- Description: prepend `Measured inside the server handler — excludes the client⇄server network round-trip and TLS handshake. ` (keep the existing description after it)
- Threshold: single chart-wide line at yellow 500 ms (0.5), red 1 s (1)

- [ ] **Step 1: Apply the edit**

`old_string`:

```
      "id": 6,
      "type": "timeseries",
      "title": "Latency percentiles (p50 / p95 / p99)",
      "description": "Overall request latency across every route. Use the per-route variants by clicking 'Edit' on this panel and adding a label filter, or drill down via 5xx rate by route if the cause of a spike is unclear.",
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
        "defaults": {"unit": "s"},
        "overrides": []
      }
```

`new_string`:

```
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
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): rename latency-percentiles panel + add threshold line"
```

---

### Task 5: Rename + add thresholds (remove fixedColor) on p95 latency stat panel (id 3)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 3 — title and `fieldConfig.defaults`)

**Changes (from spec):**
- Title: `p95 latency (now)` → `p95 server-side latency (now)`
- Remove `color: {mode: "fixed", fixedColor: "orange"}` (fixed color overrides threshold coloring)
- Add threshold steps: green / yellow @ 0.5 / red @ 1

Stat panels have no chart, so this adds threshold-driven coloring of the displayed value (the panel's `options.colorMode: "value"` setting will pick it up).

- [ ] **Step 1: Apply the edit**

`old_string`:

```
      "id": 3,
      "type": "stat",
      "title": "p95 latency (now)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.95, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "refId": "A",
          "instant": true
        }
      ],
      "options": {
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "value",
        "colorMode": "value",
        "graphMode": "area"
      },
      "fieldConfig": {
        "defaults": {"unit": "s", "decimals": 3, "color": {"mode": "fixed", "fixedColor": "orange"}},
        "overrides": []
      }
```

`new_string`:

```
      "id": 3,
      "type": "stat",
      "title": "p95 server-side latency (now)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.95, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "refId": "A",
          "instant": true
        }
      ],
      "options": {
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "value",
        "colorMode": "value",
        "graphMode": "area"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "decimals": 3,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 0.5},
              {"color": "red", "value": 1}
            ]
          }
        },
        "overrides": []
      }
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): rename p95 stat panel + threshold-driven coloring"
```

---

### Task 6: Rename + add thresholds (remove fixedColor) on p99 latency stat panel (id 4)

**Files:**
- Modify: `monitoring/grafana/dashboards/api.json` (panel id 4 — title and `fieldConfig.defaults`)

**Changes (from spec):**
- Title: `p99 latency (now)` → `p99 server-side latency (now)`
- Remove `color: {mode: "fixed", fixedColor: "red"}`
- Add threshold steps: green / yellow @ 1 / red @ 2 (p99 gets a higher bar than p95)

- [ ] **Step 1: Apply the edit**

`old_string`:

```
      "id": 4,
      "type": "stat",
      "title": "p99 latency (now)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.99, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "refId": "A",
          "instant": true
        }
      ],
      "options": {
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "value",
        "colorMode": "value",
        "graphMode": "area"
      },
      "fieldConfig": {
        "defaults": {"unit": "s", "decimals": 3, "color": {"mode": "fixed", "fixedColor": "red"}},
        "overrides": []
      }
```

`new_string`:

```
      "id": 4,
      "type": "stat",
      "title": "p99 server-side latency (now)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "expr": "histogram_quantile(0.99, sum by (le) (rate(ps_http_request_duration_seconds_bucket[5m])))",
          "refId": "A",
          "instant": true
        }
      ],
      "options": {
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "value",
        "colorMode": "value",
        "graphMode": "area"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "decimals": 3,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 1},
              {"color": "red", "value": 2}
            ]
          }
        },
        "overrides": []
      }
```

- [ ] **Step 2: Validate JSON is still well-formed**

Run: `jq . monitoring/grafana/dashboards/api.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana/dashboards/api.json
git commit -m "feat(monitoring): rename p99 stat panel + threshold-driven coloring"
```

---

### Task 7: End-to-end visual verification in Grafana

**Files:** None modified.

The previous six tasks each validated JSON shape but not Grafana rendering. This task confirms Grafana parses the file and renders the dashboard as expected.

- [ ] **Step 1: Start (or restart) the monitoring stack so Grafana picks up the changes**

Provisioned dashboards are watched, but a restart is the surest way to force a reload.

```bash
cd monitoring && docker compose -f docker-compose.monitoring.yml up -d grafana
docker compose -f docker-compose.monitoring.yml restart grafana
```

Expected: `Container monitoring-grafana-1  Started` (or similar — container name may vary).

- [ ] **Step 2: Wait for Grafana to become healthy**

```bash
until curl -sf http://localhost:3000/api/health > /dev/null; do sleep 2; done && echo READY
```

Expected: `READY` within ~15 seconds.

- [ ] **Step 3: Open the API Health dashboard in a browser**

URL: `http://localhost:3000/d/ps-api/api-health` (login `admin`/`admin` if prompted; the provisioned dashboard's uid is `ps-api`).

Confirm by eye, panel by panel:

| Panel | What to confirm |
|---|---|
| p95 server-side latency (now) — id 3 | Title shows "server-side". Value tile is green when latency is healthy (no longer the old fixed orange). |
| p99 server-side latency (now) — id 4 | Title shows "server-side". Value tile color reflects threshold state. |
| Server-side latency percentiles (p50 / p95 / p99) — id 6 | Title and description updated. Horizontal yellow line at 500 ms and red line at 1 s visible on the chart. |
| 5xx rate by route — id 7 | Yellow line at 0.05 reqps, red line at 0.2 reqps visible. |
| Goroutines — id 9 | Yellow line at 75, red line at 100 visible. |
| Memory (RSS) — id 10 | Yellow line at 256 MiB, red line at 512 MiB visible. |

If any panel fails to render or lacks the expected line, open the panel in edit mode and inspect the "Thresholds" pane — Grafana will surface JSON parsing problems there.

- [ ] **Step 4: Commit the plan + this verification record (if anything was tweaked during verification)**

If the visual check uncovered no issues, no new commit is needed. If you had to tweak values (e.g., adjust a threshold based on what looked right in production), commit those changes now:

```bash
git status
# If there are changes:
git add monitoring/grafana/dashboards/api.json
git commit -m "fix(monitoring): adjust threshold value after visual check"
```

---

## Out of scope (do NOT implement here)

- Prometheus alerting rules. The spec explicitly excludes alerting.
- Renaming the Prometheus metric (`ps_http_request_duration_seconds`). Out of scope.
- Per-series threshold overrides on panel 6. The spec chose a single chart-wide line.
- Threshold tweaks to the existing 5xx stat panel (id 2). It already has thresholds; spec leaves it alone.

# S3 Storage Footprint Dashboard

**Date:** 2026-07-31
**Status:** Approved for implementation
**Issue:** [prog-strength-infra#59](https://github.com/Prog-Strength/prog-strength-infra/issues/59)

## Problem

Prog Strength now lets users attach photos and videos to activities, and those
uploads are deliberately **not** compressed — image quality was worth more than
bytes. That trade is only safe if the bytes are visible. Today nothing reports
the S3 footprint: not the dashboards, not an alert, not a metric. The first
signal that media storage has ballooned would be the monthly bill.

Four buckets hold user-uploaded content (TCX files, avatars, activity photos,
activity videos) and a fifth holds Litestream database backups. We need a
dedicated `S3 Storage` dashboard showing object counts and sizes per bucket and
in aggregate, with the same self-explaining sections and warning/critical
thresholds the other dashboards in this repo use.

## Approach

**A small Prometheus exporter that lists the buckets directly**, rather than
reading CloudWatch's S3 storage metrics.

CloudWatch's `BucketSizeBytes` / `NumberOfObjects` are free but publish **once
per day** with 24–48h of lag, which defeats the stated goal of watching the
footprint closely. They would also need a new Grafana CloudWatch datasource,
`cloudwatch:GetMetricData` added to the instance role, and per-refresh
`GetMetricData` charges.

Listing the buckets ourselves is fresher (bounded by the exporter's refresh
interval, not by AWS's daily rollup), exact, and needs **no new AWS
permissions for the basic case** — the instance role already carries
`s3:ListBucket` on all five buckets. LIST requests cost ~$0.005 per 1,000
requests against object counts currently in the thousands; the refresh interval
is a config knob if that ever stops being true.

The shape is already proven in this project: `prog-strength-developer` runs
`ddb_exporter`, a `prometheus_client` exporter as a compose service that scans
DynamoDB on its own cadence and gets credentials from the instance profile over
IMDS. This mirrors it.

## Components

### 1. The exporter (`monitoring/s3_exporter/`)

```
monitoring/s3_exporter/
  s3_exporter.py               # thin shell: refresh loop → gauges on :9103
  s3_scan.py                   # testable scan/aggregation, no prometheus_client
  buckets.yml                  # which buckets, and their purpose label
  Dockerfile                   # python:3.12-slim + boto3 + prometheus_client
  tests/test_s3_scan.py        # unit tests over fake paginators
```

The `s3_scan` / `s3_exporter` split mirrors `ddb_exporter`'s `fleet.metrics` /
shell split: the aggregation math is unit-testable against fake paginators with
no AWS and no metrics registry, and the shell only maps samples onto gauges.

**Refresh loop.** Every `S3_EXPORTER_REFRESH_SECONDS` (default 900 — 15
minutes) it scans every configured bucket and republishes the gauges. The
cadence is deliberately decoupled from Prometheus's 15s scrape so a scrape
storm can never turn into a LIST storm. A scan failure for one bucket is
swallowed: bump `ps_s3_scan_errors_total{bucket}`, log, and leave that bucket's
last good values in place, so a transient S3 blip never zeroes the dashboard or
kills the process.

**What it counts.** Two API passes per bucket, plus one stat derived while
iterating:

- `ListObjectVersions` — every version, bucketed into `current` / `noncurrent`.
  Used on **all five** buckets, not only the two versioned ones. It is one code
  path, and on an unversioned bucket it returns the same objects with
  `VersionId=null`. The alternative (`ListObjectsV2` where unversioned) means
  that enabling versioning on the photo bucket later would silently make the
  dashboard under-report — a trap worth three extra IAM grants to avoid.
  Delete markers are counted separately and excluded from bytes; they are
  zero-byte and not billed as storage.
- `ListMultipartUploads` + `ListParts` — in-flight and abandoned multipart
  uploads. The video bucket is written by **browser-direct presigned PUT**, so
  an upload that dies mid-flight leaves parts that S3 bills for, that no
  lifecycle rule in this repo reaps, and that neither list API above can see.
  This is the single most likely source of an invisible balloon.
- Largest single object, tracked while iterating. Cheap, and it distinguishes
  "many uploads" from "one enormous video".

**Configuration (`buckets.yml`).** Bucket name → `purpose` label, in a
version-controlled file rather than environment variables. Non-secret tuning
knobs belong in config, and adding a sixth bucket becomes a one-line edit
rather than a Secrets Manager round-trip. The `purpose` values mirror the S3
`Purpose` tag each bucket already carries (`tcx-uploads`, `user-avatars`,
`activity-photos`, `activity-videos`, `database-backups`).

### 2. Metric surface

All gauges except the error counter. Prefix `ps_s3_`, consistent with the
API's `ps_` metrics.

| Metric | Labels | Meaning |
|---|---|---|
| `ps_s3_bucket_bytes` | `bucket`, `purpose`, `version_state` | Stored bytes. `version_state` is `current` or `noncurrent` |
| `ps_s3_bucket_objects` | `bucket`, `purpose`, `version_state` | Object count |
| `ps_s3_bucket_delete_markers` | `bucket`, `purpose` | Delete markers (zero-byte, excluded from bytes) |
| `ps_s3_bucket_largest_object_bytes` | `bucket`, `purpose` | Largest single object |
| `ps_s3_multipart_uploads` | `bucket`, `purpose` | In-flight/abandoned multipart uploads |
| `ps_s3_multipart_bytes` | `bucket`, `purpose` | Bytes held by those uploads |
| `ps_s3_multipart_oldest_age_seconds` | `bucket`, `purpose` | Age of the oldest one |
| `ps_s3_last_scan_timestamp_seconds` | — | Epoch seconds of the last fully successful scan |
| `ps_s3_scan_duration_seconds` | `bucket` | Duration of the last successful scan |
| `ps_s3_scan_errors_total` | `bucket` | Counter of failed scans |

Growth is **derived in PromQL** (`delta(ps_s3_bucket_bytes[24h])`), not
exported. Prometheus retention is 15 days, so 24h and 7d growth windows are
available and a 30d window is not — the dashboard uses 24h and 7d only.

### 3. Dashboard (`monitoring/grafana/dashboards/s3-storage.json`)

Title `S3 Storage`, uid `ps-s3-storage`, tag `prog-strength`. Structured like
`ps-vector-memory`: a header text panel, then a `row` per section with its own
description text panel, so an operator who has never seen it can read what each
number means without asking.

1. **Header** — what the dashboard covers, that values refresh every 15 minutes
   rather than per-second, and what it deliberately cannot see (per-object
   tags, so the orphan-reaping backlog is not represented here).
2. **Aggregate footprint** — stat tiles for total bytes (thresholded), total
   objects, 24h growth, 7d growth; plus a stacked timeseries of total bytes
   carrying the warning and critical reference lines.
3. **By bucket** — a table (bucket, purpose, objects, current bytes, noncurrent
   bytes, mean object size), a stacked timeseries of bytes by bucket, and a bar
   gauge of object counts.
4. **Photos & videos** — the issue's headline section. Count, total size, mean
   size, and largest object for each, side by side, plus their growth rates.
5. **TCX & avatars** — the same tiles at smaller scale.
6. **Versioned overhead** — current vs noncurrent bytes for `tcx-uploads` and
   `database-backups`, with a description explaining the 30-day
   noncurrent-expiration lifecycle rule, so a rising noncurrent line reads as
   expected Litestream churn rather than a leak.
7. **Waste** — abandoned multipart uploads: count, bytes, and age of the
   oldest.
8. **Exporter health** — time since last scan, scan duration, scan errors by
   bucket. Without this section the dashboard cannot be trusted, because a
   dead exporter and a stable footprint look identical.

### 4. Thresholds

Anchored to raw size rather than estimated cost. A hardcoded per-GB price
constant drifts, and at this scale the dollar figures are noise anyway — 20 GB
of S3 Standard is well under a dollar a month. **The threshold's job is to be a
tripwire on unexpected growth shape, not a cost gate**, and the panel
descriptions say exactly that so nobody later reads "critical" as "expensive".

Prog Strength is single-user and pre-launch; the footprint should stay small
for a long time. The numbers are set where a crossing means *something changed*.

| Scope | Warning | Critical |
|---|---|---|
| **Aggregate** | **5 GB** | **20 GB** |
| Activity videos | 2 GB | 10 GB |
| Activity photos | 1 GB | 5 GB |
| Database backups | 1 GB | 4 GB |
| TCX uploads | 256 MB | 1 GB |
| Avatars | 128 MB | 512 MB |

Per-bucket warnings sum to ~4.4 GB and criticals to ~20.5 GB, so a single
runaway bucket normally trips its own warning before the aggregate one — which
is the useful ordering, because the per-bucket alert names the culprit.

### 5. Alerting (`monitoring/grafana/provisioning/alerting/rules-s3-storage.yml`)

One new rules file; templates, contact point, and routing policy are shared and
untouched. Thresholds are written as literals mirroring the panel reference
lines, the same convention `rules-vector-memory.yml` uses, with a comment
cross-referencing the dashboard.

| Rule | Query | Severity | noDataState |
|---|---|---|---|
| `s3-footprint-warning` | `sum(ps_s3_bucket_bytes) > 5e9`, `for: 30m` | warning | OK |
| `s3-footprint-critical` | `sum(ps_s3_bucket_bytes) > 20e9`, `for: 30m` | critical | OK |
| `s3-exporter-stale` | `time() - ps_s3_last_scan_timestamp_seconds > 3600` | critical | **Alerting** |
| `s3-abandoned-multipart` | `ps_s3_multipart_uploads > 0`, `for: 24h` | warning | OK |

`s3-exporter-stale` is the load-bearing one. Its `noDataState: Alerting` is a
deliberate departure from the `noDataState: OK` convention used for error
counters: for a liveness monitor, **absence of the series is the failure**. The
WHOOP webhook ingestion sat dead from ship until 2026-07-31 because the
dashboard was structurally blind to its own silence; this rule is the direct
lesson. `for: 30m` on the size rules debounces a scan landing mid-evaluation.

`s3-abandoned-multipart` fires only after 24h so a genuinely in-flight video
upload never pages.

### 6. Terraform and plumbing changes

**IAM** — additive statements on the existing instance role, in
`modules/{tcx_storage,avatar_storage,activity_photo_storage,activity_video_storage,backup}`:

- `s3:ListBucketVersions` (bucket-level) — all five.
- `s3:ListBucketMultipartUploads` (bucket-level) — all five.
- `s3:ListMultipartUploadParts` (object-level) — the four that lack it;
  `activity_video_storage` already grants it.

All are policy-document additions. Nothing touches `aws_instance.backend`, so
the plan carries no `# forces replacement`.

**`deploy/api.sh`** — line 86 runs `docker compose up -d` with no `--build`.
Compose builds a `build:`-based service only when its image is missing, so
without this flag the exporter would come up once and then never pick up a
code change. Adding `--build` is required for the exporter to be deployable at
all, not a nice-to-have. Only the exporter has a `build:` stanza, so nothing
else is affected.

**`monitoring/docker-compose.monitoring.yml`** — new `s3_exporter` service:
build context `${PROG_STRENGTH_INFRA_DIR}/monitoring/s3_exporter`,
`AWS_REGION=us-east-2`, `S3_EXPORTER_REFRESH_SECONDS=900`, no published port
(Prometheus reaches it over the compose network), `restart: unless-stopped`.

**`monitoring/prometheus/prometheus.yml`** — new `s3_exporter` scrape job
targeting `s3_exporter:9103`.

**`.github/workflows/lint.yml`** — new job running the exporter's pytest suite.
The existing `grafana-alert-rules` job picks up `rules-s3-storage.yml`
automatically, since `validate_rules.py` globs the directory.

**`README.md` / `AGENTS.md`** — one row each for the new exporter, so the next
reader learns the monitoring stack has a service that talks to AWS.

## Testing

- **Unit tests** (`tests/test_s3_scan.py`, pytest) against fake paginators: byte
  and count aggregation, current vs noncurrent split, delete markers excluded
  from bytes, largest-object tracking, multipart aggregation, and per-bucket
  error isolation (one bucket failing must not blank the others). No AWS, no
  network. Run in CI by the new lint job.
- **Alert rule validation** — `validate_rules.py`, already wired into
  pre-commit and CI, enforces uid uniqueness and the paired
  `__dashboardUid__` / `__panelId__` annotations whose absence took Grafana
  down on 2026-07-31.
- **Dashboard JSON** — validated by the same pre-commit `check-yaml`/JSON
  hygiene hooks; panel queries verified against a live Prometheus after deploy.
- **Post-deploy verification** — confirm the scrape target is `up`, that each
  bucket reports a plausible non-zero size, and that
  `ps_s3_last_scan_timestamp_seconds` advances.

## Deliberately excluded

- **Per-user / top-prefix breakdown.** Would need a key-layout contract with
  the API and is not in the issue. Revisit if the product goes multi-user.
- **Estimated-cost metrics.** A hardcoded per-GB price constant drifts, and
  raw size is the chosen threshold anchor.
- **CloudWatch cross-check.** A second data path with its own cost surface,
  for a number the exporter already reports more precisely.
- **A lifecycle rule to abort stale multipart uploads.** The dashboard should
  first show whether abandoned uploads actually happen; adding a reaper is a
  separate, evidence-backed change.

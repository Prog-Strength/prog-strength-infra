# S3 Storage Footprint Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an `S3 Storage` Grafana dashboard, backed by a new Prometheus exporter that lists the five Prog Strength S3 buckets directly, so the footprint of uncompressed photo/video uploads is visible and alertable.

**Architecture:** A small Python exporter (`monitoring/s3_exporter/`) runs as a compose service in the monitoring stack, scans each bucket every 15 minutes via `ListObjectVersions` + `ListMultipartUploads`, and publishes `ps_s3_*` gauges on `:9103`. Prometheus scrapes it; a new dashboard and a new provisioned alert-rules file consume those metrics. The scan/aggregation logic lives in a boto3-free module so it is unit-testable against fake paginators.

**Tech Stack:** Python 3.12, `boto3`, `prometheus_client`, `pyyaml`, pytest, Terraform (AWS provider v6), Grafana 12.2.1 provisioned dashboards + unified alerting, Prometheus 3.5.

**Spec:** `docs/superpowers/specs/2026-07-31-s3-storage-dashboard-design.md`

---

## File Structure

| Path | Responsibility |
|---|---|
| `monitoring/s3_exporter/s3_scan.py` | **Create.** Pure scan/aggregation. No `boto3`, no `prometheus_client` imports — takes an S3 client, returns plain data. |
| `monitoring/s3_exporter/s3_exporter.py` | **Create.** Thin shell: load config, build the boto3 client, map scan results onto gauges, serve `:9103`. |
| `monitoring/s3_exporter/buckets.yml` | **Create.** Bucket name → `purpose` label. |
| `monitoring/s3_exporter/Dockerfile` | **Create.** `python:3.12-slim` + three pip deps. |
| `monitoring/s3_exporter/tests/conftest.py` | **Create.** Puts the exporter dir on `sys.path` (no pyproject in this repo). |
| `monitoring/s3_exporter/tests/test_s3_scan.py` | **Create.** Aggregation unit tests. |
| `monitoring/s3_exporter/tests/test_s3_exporter.py` | **Create.** Shell tests: gauge mapping, health, per-bucket error isolation. |
| `monitoring/docker-compose.monitoring.yml` | **Modify.** New `s3_exporter` service. |
| `monitoring/prometheus/prometheus.yml` | **Modify.** New scrape job. |
| `monitoring/grafana/dashboards/s3-storage.json` | **Create.** The dashboard. |
| `monitoring/grafana/provisioning/alerting/rules-s3-storage.yml` | **Create.** Four alert rules. |
| `deploy/api.sh:86` | **Modify.** Add `--build` so the exporter picks up code changes. |
| `.github/workflows/lint.yml` | **Modify.** New `s3-exporter-tests` job. |
| `.pre-commit-config.yaml` | **Modify.** Local pre-push hook mirroring that job. |
| `modules/tcx_storage/main.tf` | **Modify.** IAM: list-versions / list-MPU / list-parts. |
| `modules/avatar_storage/main.tf` | **Modify.** Same. |
| `modules/activity_photo_storage/main.tf` | **Modify.** Same. |
| `modules/activity_video_storage/main.tf` | **Modify.** Bucket-level only (object-level already granted). |
| `modules/backup/main.tf` | **Modify.** Same as tcx. |
| `README.md`, `AGENTS.md` | **Modify.** Document the new exporter. |

---

### Task 1: Scan + aggregation module (TDD)

**Files:**
- Create: `monitoring/s3_exporter/s3_scan.py`
- Create: `monitoring/s3_exporter/tests/conftest.py`
- Test: `monitoring/s3_exporter/tests/test_s3_scan.py`

- [ ] **Step 1: Create the test bootstrap**

This repo has no `pyproject.toml` and no packaging — tests import the module by path.

Create `monitoring/s3_exporter/tests/conftest.py`:

```python
"""Put the exporter directory on sys.path.

This repo is Terraform-first: there is no pyproject.toml and the exporter is
not an installable package. The Docker image copies the modules flat into
/app, so importing them flat here matches how they actually run.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
```

- [ ] **Step 2: Write the failing tests**

Create `monitoring/s3_exporter/tests/test_s3_scan.py`:

```python
"""Tests for the S3 footprint scan.

Everything here runs against fake paginators — no AWS, no network, no moto.
The fakes mimic the exact response shapes boto3 returns for
list_object_versions, list_multipart_uploads, and list_parts.
"""

from datetime import datetime, timezone

import pytest

import s3_scan


class FakePaginator:
    def __init__(self, pages):
        self._pages = pages

    def paginate(self, **kwargs):
        self.kwargs = kwargs
        return list(self._pages)


class FakeS3:
    """Minimal stand-in for a boto3 S3 client."""

    def __init__(self, versions=None, uploads=None, parts=None):
        self._pages = {
            "list_object_versions": versions if versions is not None else [{}],
            "list_multipart_uploads": uploads if uploads is not None else [{}],
            "list_parts": parts if parts is not None else [{}],
        }

    def get_paginator(self, operation_name):
        return FakePaginator(self._pages[operation_name])


def _at(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


def test_splits_current_from_noncurrent_versions():
    client = FakeS3(versions=[{
        "Versions": [
            {"Key": "a.jpg", "Size": 100, "IsLatest": True},
            {"Key": "a.jpg", "Size": 40, "IsLatest": False},
            {"Key": "b.jpg", "Size": 200, "IsLatest": True},
        ],
    }])

    scan = s3_scan.scan_bucket(client, "bkt", "activity-photos", now=0)

    assert scan.current_objects == 2
    assert scan.current_bytes == 300
    assert scan.noncurrent_objects == 1
    assert scan.noncurrent_bytes == 40


def test_tracks_largest_object_across_pages():
    client = FakeS3(versions=[
        {"Versions": [{"Key": "a", "Size": 10, "IsLatest": True}]},
        {"Versions": [{"Key": "b", "Size": 900, "IsLatest": True}]},
        {"Versions": [{"Key": "c", "Size": 30, "IsLatest": True}]},
    ])

    scan = s3_scan.scan_bucket(client, "bkt", "activity-videos", now=0)

    assert scan.largest_object_bytes == 900


def test_delete_markers_counted_but_excluded_from_bytes():
    client = FakeS3(versions=[{
        "Versions": [{"Key": "a", "Size": 50, "IsLatest": False}],
        "DeleteMarkers": [{"Key": "a", "IsLatest": True}],
    }])

    scan = s3_scan.scan_bucket(client, "bkt", "tcx-uploads", now=0)

    assert scan.delete_markers == 1
    assert scan.current_bytes == 0
    assert scan.noncurrent_bytes == 50


def test_empty_bucket_yields_zeroes():
    scan = s3_scan.scan_bucket(FakeS3(), "bkt", "user-avatars", now=0)

    assert scan.current_objects == 0
    assert scan.current_bytes == 0
    assert scan.largest_object_bytes == 0
    assert scan.multipart_uploads == 0


def test_multipart_uploads_sum_part_sizes_and_track_oldest():
    client = FakeS3(
        uploads=[{
            "Uploads": [
                {"Key": "v1.mp4", "UploadId": "u1", "Initiated": _at(1000)},
                {"Key": "v2.mp4", "UploadId": "u2", "Initiated": _at(500)},
            ],
        }],
        parts=[{"Parts": [{"Size": 7}, {"Size": 3}]}],
    )

    scan = s3_scan.scan_bucket(client, "bkt", "activity-videos", now=2000)

    assert scan.multipart_uploads == 2
    assert scan.multipart_bytes == 20  # 10 bytes of parts per upload
    assert scan.multipart_oldest_age_seconds == pytest.approx(1500)


def test_missing_size_keys_are_treated_as_zero():
    client = FakeS3(versions=[{
        "Versions": [{"Key": "a", "IsLatest": True}],
    }])

    scan = s3_scan.scan_bucket(client, "bkt", "tcx-uploads", now=0)

    assert scan.current_objects == 1
    assert scan.current_bytes == 0


def test_scan_passes_bucket_through_to_paginators():
    client = FakeS3()
    scan = s3_scan.scan_bucket(client, "prog-strength-avatars", "user-avatars", now=0)

    assert scan.bucket == "prog-strength-avatars"
    assert scan.purpose == "user-avatars"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `python3 -m pytest monitoring/s3_exporter/tests/test_s3_scan.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 's3_scan'`

- [ ] **Step 4: Write the implementation**

Create `monitoring/s3_exporter/s3_scan.py`:

```python
"""Bucket scanning and aggregation for the S3 footprint exporter.

Deliberately imports neither boto3 nor prometheus_client: every function takes
an already-constructed S3 client and returns plain data, so the whole module is
unit-testable against fake paginators. The exporter shell (s3_exporter.py) owns
the AWS client and the metrics registry.

Why ListObjectVersions rather than ListObjectsV2, even on unversioned buckets:
two of the five buckets (tcx-uploads, database-backups) are versioned with a
30-day noncurrent expiration, and noncurrent versions are billed storage that
ListObjectsV2 cannot see. Using one API for all buckets keeps a single code
path and means enabling versioning on another bucket later cannot silently make
the numbers wrong. On an unversioned bucket it returns the same objects with
VersionId="null" and IsLatest=True.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class BucketScan:
    """Everything one pass over one bucket produces.

    Sizes are bytes. `multipart_*` covers uploads that were started and never
    completed — S3 bills for their parts, no lifecycle rule in this repo reaps
    them, and neither the object listing nor CloudWatch's storage metrics show
    them. The video bucket is written by browser-direct presigned PUT, so an
    upload dying mid-flight is the realistic case.
    """

    bucket: str
    purpose: str
    current_objects: int = 0
    current_bytes: int = 0
    noncurrent_objects: int = 0
    noncurrent_bytes: int = 0
    delete_markers: int = 0
    largest_object_bytes: int = 0
    multipart_uploads: int = 0
    multipart_bytes: int = 0
    multipart_oldest_age_seconds: float = 0.0


def scan_bucket(client, bucket: str, purpose: str, now: float) -> BucketScan:
    """Scan one bucket and return its totals. `now` is epoch seconds."""
    scan = BucketScan(bucket=bucket, purpose=purpose)
    _scan_versions(client, bucket, scan)
    _scan_multipart(client, bucket, scan, now)
    return scan


def _scan_versions(client, bucket: str, scan: BucketScan) -> None:
    paginator = client.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=bucket):
        for version in page.get("Versions") or []:
            size = version.get("Size") or 0
            if version.get("IsLatest"):
                scan.current_objects += 1
                scan.current_bytes += size
            else:
                scan.noncurrent_objects += 1
                scan.noncurrent_bytes += size
            if size > scan.largest_object_bytes:
                scan.largest_object_bytes = size

        # Delete markers are zero-byte tombstones. They are worth counting
        # (a pile of them signals churn) but must never inflate the byte
        # totals, because AWS does not bill storage for them.
        scan.delete_markers += len(page.get("DeleteMarkers") or [])


def _scan_multipart(client, bucket: str, scan: BucketScan, now: float) -> None:
    paginator = client.get_paginator("list_multipart_uploads")
    for page in paginator.paginate(Bucket=bucket):
        for upload in page.get("Uploads") or []:
            scan.multipart_uploads += 1
            scan.multipart_bytes += _upload_bytes(
                client, bucket, upload["Key"], upload["UploadId"]
            )
            age = now - upload["Initiated"].timestamp()
            if age > scan.multipart_oldest_age_seconds:
                scan.multipart_oldest_age_seconds = age


def _upload_bytes(client, bucket: str, key: str, upload_id: str) -> int:
    """Sum the parts already uploaded for one incomplete multipart upload.

    ListMultipartUploads reports that an upload exists but not how big it is,
    so the only way to price it is to list its parts.
    """
    total = 0
    paginator = client.get_paginator("list_parts")
    for page in paginator.paginate(Bucket=bucket, Key=key, UploadId=upload_id):
        for part in page.get("Parts") or []:
            total += part.get("Size") or 0
    return total
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m pytest monitoring/s3_exporter/tests/test_s3_scan.py -q`
Expected: PASS — `7 passed`

- [ ] **Step 6: Commit**

```bash
git add monitoring/s3_exporter/s3_scan.py monitoring/s3_exporter/tests/
git commit -m "feat(s3-exporter): add bucket scan and aggregation

Counts current and noncurrent versions, delete markers, largest object,
and incomplete multipart uploads. boto3-free so it is testable against
fake paginators.

Refs #59"
```

---

### Task 2: Exporter shell, config, and image (TDD)

**Files:**
- Create: `monitoring/s3_exporter/s3_exporter.py`
- Create: `monitoring/s3_exporter/buckets.yml`
- Create: `monitoring/s3_exporter/Dockerfile`
- Test: `monitoring/s3_exporter/tests/test_s3_exporter.py`

- [ ] **Step 1: Write the failing tests**

Create `monitoring/s3_exporter/tests/test_s3_exporter.py`:

```python
"""Tests for the exporter shell.

The scan itself is covered in test_s3_scan.py. Here we prove the glue: that a
refresh maps BucketScan results onto Prometheus gauges, records its own health,
and — the important one — that one bucket failing does not blank the others or
kill the process.
"""

import pytest

import s3_exporter
from s3_scan import BucketScan

BUCKETS = [("bkt-a", "activity-photos"), ("bkt-b", "activity-videos")]


def _scanner(overrides=None):
    """Return a scan function yielding predictable per-bucket totals."""
    overrides = overrides or {}

    def scan(client, bucket, purpose, now):
        if bucket in overrides:
            raise overrides[bucket]
        return BucketScan(
            bucket=bucket,
            purpose=purpose,
            current_objects=2,
            current_bytes=1000,
            noncurrent_objects=1,
            noncurrent_bytes=100,
            delete_markers=3,
            largest_object_bytes=900,
            multipart_uploads=1,
            multipart_bytes=50,
            multipart_oldest_age_seconds=120.0,
        )

    return scan


def test_refresh_publishes_gauges_per_bucket():
    prom, metrics = s3_exporter.build_metrics()
    s3_exporter.refresh(metrics, client=None, buckets=BUCKETS, now=999, scan=_scanner())

    sv = prom.get_sample_value
    labels = {"bucket": "bkt-a", "purpose": "activity-photos"}
    assert sv("ps_s3_bucket_bytes", {**labels, "version_state": "current"}) == 1000
    assert sv("ps_s3_bucket_bytes", {**labels, "version_state": "noncurrent"}) == 100
    assert sv("ps_s3_bucket_objects", {**labels, "version_state": "current"}) == 2
    assert sv("ps_s3_bucket_delete_markers", labels) == 3
    assert sv("ps_s3_bucket_largest_object_bytes", labels) == 900
    assert sv("ps_s3_multipart_uploads", labels) == 1
    assert sv("ps_s3_multipart_bytes", labels) == 50
    assert sv("ps_s3_multipart_oldest_age_seconds", labels) == 120.0


def test_refresh_records_scan_health_when_every_bucket_succeeds():
    prom, metrics = s3_exporter.build_metrics()
    s3_exporter.refresh(metrics, client=None, buckets=BUCKETS, now=999, scan=_scanner())

    assert prom.get_sample_value("ps_s3_last_scan_timestamp_seconds") == 999
    assert prom.get_sample_value("ps_s3_scan_errors_total", {"bucket": "bkt-a"}) == 0


def test_one_failing_bucket_does_not_blank_the_others():
    prom, metrics = s3_exporter.build_metrics()
    scan = _scanner({"bkt-a": RuntimeError("access denied")})

    s3_exporter.refresh(metrics, client=None, buckets=BUCKETS, now=999, scan=scan)

    healthy = {"bucket": "bkt-b", "purpose": "activity-videos", "version_state": "current"}
    assert prom.get_sample_value("ps_s3_bucket_bytes", healthy) == 1000
    assert prom.get_sample_value("ps_s3_scan_errors_total", {"bucket": "bkt-a"}) == 1


def test_partial_failure_leaves_last_scan_timestamp_untouched():
    """A stale timestamp is what makes s3-exporter-stale fire. A scan that only
    half-worked must not look like a healthy one."""
    prom, metrics = s3_exporter.build_metrics()

    s3_exporter.refresh(metrics, client=None, buckets=BUCKETS, now=100, scan=_scanner())
    s3_exporter.refresh(
        metrics, client=None, buckets=BUCKETS, now=999,
        scan=_scanner({"bkt-a": RuntimeError("boom")}),
    )

    assert prom.get_sample_value("ps_s3_last_scan_timestamp_seconds") == 100


def test_failed_bucket_keeps_its_previous_values():
    prom, metrics = s3_exporter.build_metrics()
    labels = {"bucket": "bkt-a", "purpose": "activity-photos", "version_state": "current"}

    s3_exporter.refresh(metrics, client=None, buckets=BUCKETS, now=100, scan=_scanner())
    s3_exporter.refresh(
        metrics, client=None, buckets=BUCKETS, now=999,
        scan=_scanner({"bkt-a": RuntimeError("boom")}),
    )

    assert prom.get_sample_value("ps_s3_bucket_bytes", labels) == 1000


def test_load_buckets_reads_name_and_purpose(tmp_path):
    config = tmp_path / "buckets.yml"
    config.write_text(
        "buckets:\n"
        "  - name: prog-strength-avatars\n"
        "    purpose: user-avatars\n"
        "  - name: prog-strength-tcx-uploads\n"
        "    purpose: tcx-uploads\n"
    )

    assert s3_exporter.load_buckets(str(config)) == [
        ("prog-strength-avatars", "user-avatars"),
        ("prog-strength-tcx-uploads", "tcx-uploads"),
    ]


def test_load_buckets_rejects_an_empty_config(tmp_path):
    """Failing loud beats exporting nothing and looking healthy."""
    config = tmp_path / "buckets.yml"
    config.write_text("buckets: []\n")

    with pytest.raises(ValueError):
        s3_exporter.load_buckets(str(config))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m pytest monitoring/s3_exporter/tests/test_s3_exporter.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 's3_exporter'`

- [ ] **Step 3: Write the config file**

Create `monitoring/s3_exporter/buckets.yml`:

```yaml
# Buckets the S3 footprint exporter scans, and the `purpose` label each one
# gets on every metric.
#
# The purpose values mirror the S3 `Purpose` tag Terraform already puts on
# each bucket, so PromQL can select by content type
# (purpose="activity-videos") without hardcoding bucket names in dashboard
# queries. Bucket names mirror environments/prod.tfvars.
#
# This is version-controlled config, not environment: adding a sixth bucket
# should be a one-line edit reviewed in a PR, not a Secrets Manager change.
# Keep in sync with prod.tfvars when a bucket is added or renamed.

buckets:
  - name: prog-strength-tcx-uploads
    purpose: tcx-uploads
  - name: prog-strength-avatars
    purpose: user-avatars
  - name: prog-strength-activity-photos
    purpose: activity-photos
  - name: prog-strength-activity-videos
    purpose: activity-videos
  - name: prog-strength-database-backups
    purpose: database-backups
```

- [ ] **Step 4: Write the exporter shell**

Create `monitoring/s3_exporter/s3_exporter.py`:

```python
"""Long-lived Prometheus exporter for the Prog Strength S3 footprint.

Runs on the backend host as a docker-compose service. Every refresh interval it
scans each configured bucket (see buckets.yml) and publishes the totals as
gauges on :9103 for Prometheus to scrape over the compose network. The scan
cadence is decoupled from Prometheus's 15s scrape interval, so a scrape storm
can never become a LIST storm.

Why an exporter instead of CloudWatch: S3's free BucketSizeBytes /
NumberOfObjects metrics publish once per day with up to 48h of lag, which is
useless for watching an upload feature that can balloon in an afternoon.
Listing the buckets ourselves is exact and as fresh as the refresh interval.

Mirrors prog-strength-developer's bootstrap/ddb_exporter.py: the scan lives in
the testable s3_scan module, this is the thin shell that maps results onto
prometheus_client metrics. AWS credentials come from the instance profile via
IMDS — no keys anywhere.
"""

from __future__ import annotations

import logging
import os
import time

import boto3
import yaml
from prometheus_client import CollectorRegistry, Counter, Gauge, start_http_server

from s3_scan import scan_bucket

log = logging.getLogger("s3_exporter")

DEFAULT_PORT = 9103
DEFAULT_REFRESH_SECONDS = 900
DEFAULT_CONFIG = "buckets.yml"

#: Metrics labelled by bucket + purpose only.
_BUCKET_LABELS = ["bucket", "purpose"]
#: Metrics that additionally split current from noncurrent versions.
_VERSIONED_LABELS = ["bucket", "purpose", "version_state"]


def load_buckets(path: str) -> list[tuple[str, str]]:
    """Read buckets.yml into [(bucket_name, purpose), ...].

    An empty list is an error rather than a no-op: an exporter that scans
    nothing still serves 200s and looks perfectly healthy, which is the exact
    failure mode this dashboard exists to prevent.
    """
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle) or {}

    entries = doc.get("buckets") or []
    if not entries:
        raise ValueError(f"{path}: no buckets configured")

    return [(entry["name"], entry["purpose"]) for entry in entries]


def build_metrics() -> tuple[CollectorRegistry, dict]:
    """Construct a fresh registry and the metric handles, keyed by short name."""
    registry = CollectorRegistry()
    metrics = {
        "bytes": Gauge(
            "ps_s3_bucket_bytes",
            "Stored bytes per bucket, split into current and noncurrent versions.",
            _VERSIONED_LABELS,
            registry=registry,
        ),
        "objects": Gauge(
            "ps_s3_bucket_objects",
            "Object count per bucket, split into current and noncurrent versions.",
            _VERSIONED_LABELS,
            registry=registry,
        ),
        "delete_markers": Gauge(
            "ps_s3_bucket_delete_markers",
            "Delete markers per bucket (zero-byte tombstones, not billed as storage).",
            _BUCKET_LABELS,
            registry=registry,
        ),
        "largest": Gauge(
            "ps_s3_bucket_largest_object_bytes",
            "Size of the largest single object in the bucket.",
            _BUCKET_LABELS,
            registry=registry,
        ),
        "mpu_count": Gauge(
            "ps_s3_multipart_uploads",
            "Incomplete multipart uploads (started, never completed or aborted).",
            _BUCKET_LABELS,
            registry=registry,
        ),
        "mpu_bytes": Gauge(
            "ps_s3_multipart_bytes",
            "Bytes held by incomplete multipart uploads. Billed, and invisible to object listings.",
            _BUCKET_LABELS,
            registry=registry,
        ),
        "mpu_age": Gauge(
            "ps_s3_multipart_oldest_age_seconds",
            "Age of the oldest incomplete multipart upload.",
            _BUCKET_LABELS,
            registry=registry,
        ),
        "last_scan": Gauge(
            "ps_s3_last_scan_timestamp_seconds",
            "Epoch seconds of the last scan in which EVERY bucket succeeded.",
            registry=registry,
        ),
        "scan_duration": Gauge(
            "ps_s3_scan_duration_seconds",
            "Duration of the last successful scan, per bucket.",
            ["bucket"],
            registry=registry,
        ),
        "scan_errors": Counter(
            "ps_s3_scan_errors",
            "Failed bucket scans (the exporter keeps serving the last good values).",
            ["bucket"],
            registry=registry,
        ),
    }
    return registry, metrics


def refresh(metrics: dict, client, buckets, now: float, scan=scan_bucket) -> None:
    """Scan every bucket and publish onto the gauges.

    A failure is contained to the bucket that raised it: bump its error
    counter, log, and leave its last good gauge values in place. A transient
    S3 blip must never zero the dashboard or take the process down.

    ps_s3_last_scan_timestamp_seconds only advances when EVERY bucket
    succeeded — a half-scan that looked fresh would defeat the staleness
    alert that exists to catch a blind dashboard.
    """
    all_ok = True

    for bucket, purpose in buckets:
        # Touch the counter so the series exists from the first scrape; an
        # alert on a never-incremented counter is easier to reason about
        # than one on a missing series.
        metrics["scan_errors"].labels(bucket=bucket).inc(0)

        started = time.monotonic()
        try:
            result = scan(client, bucket, purpose, now)
        except Exception:  # noqa: BLE001 - any AWS/client error is non-fatal here
            log.exception("scan failed for bucket %s", bucket)
            metrics["scan_errors"].labels(bucket=bucket).inc()
            all_ok = False
            continue

        labels = {"bucket": bucket, "purpose": purpose}
        metrics["bytes"].labels(**labels, version_state="current").set(result.current_bytes)
        metrics["bytes"].labels(**labels, version_state="noncurrent").set(result.noncurrent_bytes)
        metrics["objects"].labels(**labels, version_state="current").set(result.current_objects)
        metrics["objects"].labels(**labels, version_state="noncurrent").set(result.noncurrent_objects)
        metrics["delete_markers"].labels(**labels).set(result.delete_markers)
        metrics["largest"].labels(**labels).set(result.largest_object_bytes)
        metrics["mpu_count"].labels(**labels).set(result.multipart_uploads)
        metrics["mpu_bytes"].labels(**labels).set(result.multipart_bytes)
        metrics["mpu_age"].labels(**labels).set(result.multipart_oldest_age_seconds)
        metrics["scan_duration"].labels(bucket=bucket).set(time.monotonic() - started)

    if all_ok:
        metrics["last_scan"].set(now)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    port = int(os.environ.get("S3_EXPORTER_PORT", DEFAULT_PORT))
    interval = int(os.environ.get("S3_EXPORTER_REFRESH_SECONDS", DEFAULT_REFRESH_SECONDS))
    config_path = os.environ.get("S3_EXPORTER_CONFIG", DEFAULT_CONFIG)

    buckets = load_buckets(config_path)
    registry, metrics = build_metrics()
    client = boto3.client("s3")

    start_http_server(port, registry=registry)
    log.info("serving on :%d, scanning %d buckets every %ds", port, len(buckets), interval)

    while True:
        refresh(metrics, client, buckets, now=time.time())
        time.sleep(interval)


if __name__ == "__main__":
    main()
```

> Note on the counter name: `prometheus_client` appends `_total` itself, so
> declaring `ps_s3_scan_errors` produces the series `ps_s3_scan_errors_total`.
> The dashboard and alert rules query the `_total` name.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m pytest monitoring/s3_exporter/tests -q`
Expected: PASS — `14 passed`

If `boto3` is not installed locally, install the test dependencies first:
`python3 -m pip install --quiet pytest pyyaml boto3 prometheus_client`

- [ ] **Step 6: Write the Dockerfile**

Create `monitoring/s3_exporter/Dockerfile`:

```dockerfile
# S3 footprint Prometheus exporter (monitoring docker-compose service).
#
# Build context is this directory — unlike prog-strength-developer's
# ddb_exporter, nothing here depends on a shared package, so the context stays
# small. Scans the Prog Strength S3 buckets and serves gauges on :9103 for
# Prometheus to scrape over the compose network.
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    'prometheus_client>=0.20' \
    'boto3>=1.34' \
    'pyyaml>=6'

COPY s3_scan.py s3_exporter.py buckets.yml ./

ENV PYTHONUNBUFFERED=1

# AWS_REGION and S3_EXPORTER_* come from the compose service env; AWS
# credentials arrive via the host's instance profile over IMDS.
CMD ["python", "s3_exporter.py"]
```

- [ ] **Step 7: Verify the image builds**

Run: `docker build -t ps-s3-exporter-test monitoring/s3_exporter`
Expected: `naming to docker.io/library/ps-s3-exporter-test` — a successful build.

- [ ] **Step 8: Commit**

```bash
git add monitoring/s3_exporter/
git commit -m "feat(s3-exporter): add the exporter shell, config, and image

Maps scan results onto ps_s3_* gauges on :9103. Per-bucket failures are
contained and never advance the last-scan timestamp, so the staleness
alert stays meaningful.

Refs #59"
```

---

### Task 3: Run the exporter tests in CI and pre-commit

**Files:**
- Modify: `.github/workflows/lint.yml`
- Modify: `.pre-commit-config.yaml`

- [ ] **Step 1: Add the CI job**

In `.github/workflows/lint.yml`, add this job after the existing `grafana-alert-rules` job and before `shellcheck`:

```yaml
  s3-exporter-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: pytest
        # The exporter is the only Python service this repo ships. Its scan
        # math decides what the S3 Storage dashboard claims your footprint
        # is, and it is unit-testable without AWS — so it gets a gate.
        run: |
          python3 -m pip install --quiet pytest pyyaml boto3 prometheus_client
          python3 -m pytest monitoring/s3_exporter/tests -q
```

> All four dependencies are needed even though no test touches AWS:
> `test_s3_exporter.py` imports `s3_exporter`, which imports `boto3` and
> `prometheus_client` at module scope. Only `s3_scan` is dependency-free, and
> that is the point — the module deciding what the footprint *is* stays
> testable in isolation.

- [ ] **Step 2: Add the matching pre-commit hook**

In `.pre-commit-config.yaml`, add to the existing `- repo: local` block's `hooks:` list, after the `grafana-alert-rules` hook:

```yaml
      # Mirrors the s3-exporter-tests job in lint.yml. Push-stage because it
      # is the slower of the two local Python hooks and the exporter changes
      # rarely; commit-stage would tax every unrelated commit.
      - id: s3-exporter-tests
        name: s3 exporter unit tests
        entry: python3 -m pytest monitoring/s3_exporter/tests -q
        language: python
        additional_dependencies: [pytest, pyyaml, boto3, prometheus_client]
        files: ^monitoring/s3_exporter/.*\.py$
        pass_filenames: false
        stages: [pre-push]
```

- [ ] **Step 3: Verify both run**

Run: `python3 -m pytest monitoring/s3_exporter/tests -q`
Expected: PASS — `14 passed`

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml')); yaml.safe_load(open('.pre-commit-config.yaml')); print('yaml ok')"`
Expected: `yaml ok`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml .pre-commit-config.yaml
git commit -m "ci: gate the s3 exporter unit tests

Refs #59"
```

---

### Task 4: Grant the exporter the S3 list permissions it needs

**Files:**
- Modify: `modules/tcx_storage/main.tf`
- Modify: `modules/backup/main.tf`
- Modify: `modules/avatar_storage/main.tf`
- Modify: `modules/activity_photo_storage/main.tf`
- Modify: `modules/activity_video_storage/main.tf`

All five already grant `s3:ListBucket`. The exporter additionally needs
`s3:ListBucketVersions` (noncurrent versions), `s3:ListBucketMultipartUploads`
(finding incomplete uploads), and `s3:ListMultipartUploadParts` (sizing them).
These are additive policy-document statements attached to the existing instance
role — nothing touches `aws_instance.backend`, so the plan must show no
`# forces replacement`.

- [ ] **Step 1: Widen the bucket-level statement in `modules/tcx_storage/main.tf`**

Replace:

```hcl
  # Bucket-level: the backend lists objects to manage uploaded activity files.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tcx_uploads.arn]
  }
```

with:

```hcl
  # Bucket-level: the backend lists objects to manage uploaded activity files.
  # ListBucketVersions and ListBucketMultipartUploads are for the S3 footprint
  # exporter (monitoring/s3_exporter), not the API: this bucket is versioned,
  # so noncurrent versions are billed storage that a plain ListBucket cannot
  # see, and incomplete multipart uploads are invisible to both.
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.tcx_uploads.arn]
  }
```

- [ ] **Step 2: Widen the object-level statement in `modules/tcx_storage/main.tf`**

Replace:

```hcl
  # Object-level: read, write, and delete TCX files under any key.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tcx_uploads.arn}/*"]
  }
```

with:

```hcl
  # Object-level: read, write, and delete TCX files under any key.
  # ListMultipartUploadParts is the exporter's — sizing an incomplete upload
  # means listing its parts, since ListMultipartUploads reports existence only.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.tcx_uploads.arn}/*"]
  }
```

- [ ] **Step 3: Apply the same two edits to `modules/backup/main.tf`**

Same change, substituting the resource reference `aws_s3_bucket.litestream`.
Bucket-level actions become:

```hcl
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.litestream.arn]
```

Object-level: add `"s3:ListMultipartUploadParts"` to the existing
`GetObject`/`PutObject`/`DeleteObject` list, resources
`["${aws_s3_bucket.litestream.arn}/*"]`. Use this comment on the bucket-level
statement, since the reason is Litestream-specific:

```hcl
  # ListBucketVersions and ListBucketMultipartUploads serve the S3 footprint
  # exporter (monitoring/s3_exporter). Litestream rewrites WAL segments
  # constantly and this bucket is versioned with a 30-day noncurrent
  # expiration, so noncurrent versions can outweigh current ones — a footprint
  # number that ignored them would be badly wrong here specifically.
```

- [ ] **Step 4: Apply the same two edits to `modules/avatar_storage/main.tf`**

Resource reference `aws_s3_bucket.avatars`. The object-level statement here
also carries `s3:PutObjectTagging` — keep it, and append
`"s3:ListMultipartUploadParts"`. Use this bucket-level comment, since this
bucket is not versioned:

```hcl
  # ListBucketVersions and ListBucketMultipartUploads serve the S3 footprint
  # exporter (monitoring/s3_exporter). This bucket is not versioned today, but
  # the exporter uses ListObjectVersions uniformly across all five buckets so
  # that enabling versioning later cannot silently make the dashboard
  # under-report.
```

- [ ] **Step 5: Apply the same two edits to `modules/activity_photo_storage/main.tf`**

Resource reference `aws_s3_bucket.activity_photos`, same comment as Step 4
(this bucket is also unversioned), object-level statement also carries
`s3:PutObjectTagging`.

- [ ] **Step 6: Edit `modules/activity_video_storage/main.tf` — bucket-level only**

Resource reference `aws_s3_bucket.activity_videos`. Widen the bucket-level
statement exactly as in Step 4. **Do not touch the object-level statements** —
this module already has a dedicated multipart statement granting
`s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts`. Add this line to
that existing statement's comment:

```hcl
  # Cleaning up interrupted multipart uploads. ListMultipartUploadParts is also
  # what lets the S3 footprint exporter price them — this bucket is the one
  # browsers PUT to directly, so an upload dying mid-flight is the realistic
  # case and its parts are billed until aborted.
```

- [ ] **Step 7: Format and validate**

Run: `terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`

Run: `tflint --recursive --format compact`
Expected: no output (no findings).

- [ ] **Step 8: Commit**

```bash
git add modules/
git commit -m "feat(storage): grant the footprint exporter its list permissions

ListBucketVersions, ListBucketMultipartUploads, and
ListMultipartUploadParts on all five buckets. Additive statements on the
existing instance role; nothing recreates the EC2 host.

Refs #59"
```

---

### Task 5: Wire the exporter into the running stack

**Files:**
- Modify: `monitoring/docker-compose.monitoring.yml`
- Modify: `monitoring/prometheus/prometheus.yml`
- Modify: `deploy/api.sh:86`

- [ ] **Step 1: Add the compose service**

In `monitoring/docker-compose.monitoring.yml`, add after the `node_exporter`
service and before `grafana`:

```yaml
  # Scans the five Prog Strength S3 buckets every 15 minutes and serves
  # footprint gauges on :9103 (scraped over the compose network — no host
  # port). Built from this repo's checkout on the host; AWS credentials come
  # from the instance profile via IMDS, so no keys are involved.
  #
  # The 15-minute cadence is deliberately far slower than Prometheus's 15s
  # scrape: LIST requests cost money per request, and the footprint of a
  # single-user app does not move between scrapes.
  s3_exporter:
    build:
      context: ${PROG_STRENGTH_INFRA_DIR:-/home/ubuntu/prog-strength-infra}/monitoring/s3_exporter
    environment:
      - AWS_REGION=us-east-2
      - S3_EXPORTER_REFRESH_SECONDS=900
    restart: unless-stopped
```

- [ ] **Step 2: Add the scrape job**

In `monitoring/prometheus/prometheus.yml`, append after the `agent` job:

```yaml
  # S3 footprint exporter. Publishes ps_s3_* gauges describing object counts
  # and stored bytes per bucket. It rescans S3 every 15 minutes on its own
  # timer, so scraping at the global 15s interval just re-reads cached values.
  - job_name: s3_exporter
    static_configs:
      - targets: ["s3_exporter:9103"]
    metrics_path: /metrics
```

- [ ] **Step 3: Make the deploy actually rebuild the exporter**

In `deploy/api.sh`, replace line 86:

```bash
docker compose "${COMPOSE_FILES[@]}" up -d
```

with:

```bash
# --build is required by the monitoring stack's s3_exporter, which is built
# from this repo's checkout rather than pulled from a registry. Without it
# compose builds the image only when it is missing, so an exporter code change
# would deploy green and silently keep running the old code.
docker compose "${COMPOSE_FILES[@]}" up -d --build
```

- [ ] **Step 4: Verify the compose file parses and the deploy tests still pass**

Run: `docker compose -f compose/api/docker-compose.yml -f monitoring/docker-compose.monitoring.yml config -q 2>/dev/null || python3 -c "import yaml; yaml.safe_load(open('monitoring/docker-compose.monitoring.yml')); print('compose yaml ok')"`
Expected: `compose yaml ok` (or silent success from `config -q`).

Run: `for t in deploy/tests/*.test.sh; do bash "$t" || exit 1; done`
Expected: all suites pass.

Run: `shellcheck -x deploy/api.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add monitoring/docker-compose.monitoring.yml monitoring/prometheus/prometheus.yml deploy/api.sh
git commit -m "feat(monitoring): run and scrape the s3 footprint exporter

Adds the compose service and scrape job, and passes --build on deploy so
the host-built exporter image picks up code changes.

Refs #59"
```

---

### Task 6: The S3 Storage dashboard

**Files:**
- Create: `monitoring/grafana/dashboards/s3-storage.json`

Follow the structure of `monitoring/grafana/dashboards/ps-vector-memory.json`
exactly: a `text` header panel, then a `row` per section, each row followed by
its own `text` description panel. Every non-text panel carries a `description`
that explains what it shows and what the thresholds mean.

**Panel ids are load-bearing** — Task 7's alert rules reference ids 8, 41, and
47 via `__panelId__`. Do not renumber. Ids need not be contiguous or ordered in
the array; `gridPos` alone determines layout.

**How the panel tables below work.** Steps 3–10 give fully-worked JSON for one
panel of each type and a table of the fields that vary for the rest. Build each
tabled panel by copying its type's exemplar and substituting `id`, `title`,
`description`, `gridPos`, `targets[].expr`, `unit`, `decimals`, and
`thresholds.steps`. The exemplars are:

- `stat` → panel 4 (Step 3)
- `timeseries` with dashed threshold lines → panel 8 (Step 3)
- `timeseries` plain multi-series → same as panel 8 without the `vector()`
  targets and without the `overrides` array
- `table` → panel 11 (Step 5)
- `bargauge` → same `options`/`fieldConfig` shape as `stat`, plus
  `"options": {"displayMode": "gradient", "orientation": "horizontal",
  "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}`
- Stacked `timeseries` (panels 12, 35) add
  `"custom": {"stacking": {"mode": "normal"}}` inside `fieldConfig.defaults`

A threshold column of "none" means a single step: `[{"color": "green", "value":
null}]`.

- [ ] **Step 1: Create the dashboard scaffold with the header**

Create `monitoring/grafana/dashboards/s3-storage.json`:

```json
{
  "title": "S3 Storage",
  "uid": "ps-s3-storage",
  "tags": ["prog-strength"],
  "schemaVersion": 39,
  "timezone": "browser",
  "refresh": "5m",
  "time": { "from": "now-7d", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "text",
      "title": "",
      "transparent": true,
      "gridPos": { "h": 4, "w": 24, "x": 0, "y": 0 },
      "options": {
        "mode": "markdown",
        "content": "### S3 Storage Footprint\nHow much S3 Prog Strength is actually using, by bucket and in aggregate. Activity photos and videos are stored **uncompressed** — quality was worth more than bytes — so this is the dashboard that keeps that trade honest.\n\n**Source:** the `s3_exporter` service lists every bucket directly (`monitoring/s3_exporter/`) and rescans **every 15 minutes**. Numbers here are minutes fresh, not seconds — a just-finished upload may not appear yet. This is still far fresher than CloudWatch's once-daily storage metrics, which is why the exporter exists.\n\n**Thresholds are growth tripwires, not cost limits.** At this scale the whole footprint costs cents per month; a crossing means *something changed shape*, not *this is expensive*. Aggregate warning **5 GB**, critical **20 GB** (see `alerting/rules-s3-storage.yml`).\n\n**Not shown:** per-object tags, so the orphan-reaping backlog (objects tagged `*-status=orphaned` awaiting lifecycle expiry) is invisible here — reading tags would mean an API call per object."
      }
    }
  ]
}
```

- [ ] **Step 2: Verify it is valid JSON**

Run: `python3 -c "import json; d=json.load(open('monitoring/grafana/dashboards/s3-storage.json')); print(d['uid'], len(d['panels']))"`
Expected: `ps-s3-storage 1`

- [ ] **Step 3: Add the "Aggregate footprint" section (panels 2–8)**

Append these panels to the `panels` array. Panel 4 is the fully-worked `stat`
exemplar and panel 8 the fully-worked thresholded-`timeseries` exemplar; build
the rest to match.

```json
    {
      "id": 2,
      "type": "row",
      "title": "Aggregate footprint",
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 4 },
      "panels": []
    },
    {
      "id": 3,
      "type": "text",
      "title": "",
      "transparent": true,
      "gridPos": { "h": 3, "w": 24, "x": 0, "y": 5 },
      "options": {
        "mode": "markdown",
        "content": "**Everything, added up.** All five buckets: TCX uploads, avatars, activity photos, activity videos, and Litestream database backups. **Total footprint** counts current *and* noncurrent object versions plus bytes held by incomplete multipart uploads — everything AWS bills for. The two growth tiles are the ones to watch: a steady footprint that suddenly gains a gigabyte in a day is the signal this dashboard was built for."
      }
    },
    {
      "id": 4,
      "type": "stat",
      "title": "Total footprint",
      "description": "Every byte across all five buckets, current and noncurrent versions together (sum(ps_s3_bucket_bytes)). Warning at 5 GB, critical at 20 GB. Those are growth tripwires rather than cost limits — 20 GB of S3 Standard is well under a dollar a month — set where a crossing means Prog Strength is storing meaningfully more than a single-user app should.",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 8 },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum(ps_s3_bucket_bytes)",
          "refId": "A",
          "instant": true
        }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "textMode": "value",
        "colorMode": "value",
        "graphMode": "area"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "decbytes",
          "decimals": 2,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 5000000000 },
              { "color": "red", "value": 20000000000 }
            ]
          }
        },
        "overrides": []
      }
    },
    {
      "id": 8,
      "type": "timeseries",
      "title": "Total footprint over time",
      "description": "The aggregate footprint plotted over the dashboard window, with dashed yellow and red lines at the 5 GB warning and 20 GB critical thresholds. The shape matters more than the value: a straight line trending gently up is normal accumulation, a step change is a new upload path or a bug. Prometheus retains 15 days, so windows longer than that will look truncated.",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum(ps_s3_bucket_bytes)",
          "legendFormat": "total",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "vector(5000000000)",
          "legendFormat": "warning (5 GB)",
          "refId": "B"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "vector(20000000000)",
          "legendFormat": "critical (20 GB)",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "decbytes", "decimals": 2, "min": 0 },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "warning (5 GB)" },
            "properties": [
              { "id": "color", "value": { "mode": "fixed", "fixedColor": "yellow" } },
              { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } }
            ]
          },
          {
            "matcher": { "id": "byName", "options": "critical (20 GB)" },
            "properties": [
              { "id": "color", "value": { "mode": "fixed", "fixedColor": "red" } },
              { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } }
            ]
          }
        ]
      }
    }
```

Panels 5–7 are `stat` panels built exactly like panel 4, differing only in the
fields below:

| id | title | gridPos | expr | unit | thresholds (green → yellow → red) |
|---|---|---|---|---|---|
| 5 | Total objects | `h4 w6 x6 y8` | `sum(ps_s3_bucket_objects)` | `short`, 0 decimals | none — informational, single green step |
| 6 | Growth (24h) | `h4 w6 x12 y8` | `sum(delta(ps_s3_bucket_bytes[24h]))` | `decbytes`, 2 decimals | `null` → `500000000` → `2000000000` |
| 7 | Growth (7d) | `h4 w6 x18 y8` | `sum(delta(ps_s3_bucket_bytes[7d]))` | `decbytes`, 2 decimals | `null` → `2000000000` → `5000000000` |

Descriptions to use verbatim:

- **5:** "Total object count across all five buckets, current and noncurrent versions together. No thresholds — count alone says little, since one video outweighs ten thousand TCX files. It is here to explain the byte totals: bytes rising while this stays flat means objects are getting bigger, not more numerous."
- **6:** "Bytes added across all buckets in the last 24 hours (sum(delta(ps_s3_bucket_bytes[24h]))). Negative values are normal — lifecycle rules reap orphaned and noncurrent objects. Warning at 500 MB/day, critical at 2 GB/day: sustained growth at that rate crosses the aggregate critical threshold inside a fortnight."
- **7:** "Bytes added across all buckets in the last 7 days. Smooths out a single large upload, so it answers 'is the trend real?' where the 24h tile answers 'did something just happen?'. Prometheus retains 15 days of data, so this tile is empty for the first week after the exporter is deployed."

- [ ] **Step 4: Verify JSON and panel ids**

Run:
```bash
python3 -c "
import json
d = json.load(open('monitoring/grafana/dashboards/s3-storage.json'))
ids = [p['id'] for p in d['panels']]
assert len(ids) == len(set(ids)), f'duplicate panel ids: {ids}'
print('panels:', ids)
"
```
Expected: `panels: [1, 2, 3, 4, 5, 6, 7, 8]`

- [ ] **Step 5: Add the "By bucket" section (panels 9–14)**

| id | type | title | gridPos | expr / config |
|---|---|---|---|---|
| 9 | row | By bucket | `h1 w24 x0 y20` | — |
| 10 | text | — | `h3 w24 x0 y21` | content below |
| 11 | table | Footprint by bucket | `h8 w12 x0 y24` | instant queries, see below |
| 12 | timeseries | Bytes by bucket | `h8 w12 x12 y24` | `sum by (bucket) (ps_s3_bucket_bytes)`, legend `{{bucket}}`, unit `decbytes`, `custom.stacking: {mode: "normal"}` |
| 13 | bargauge | Objects by bucket | `h8 w12 x0 y32` | `sum by (bucket) (ps_s3_bucket_objects)`, legend `{{bucket}}`, unit `short`, instant |
| 14 | timeseries | Growth by bucket (24h) | `h8 w12 x12 y32` | `sum by (bucket) (delta(ps_s3_bucket_bytes[24h]))`, legend `{{bucket}}`, unit `decbytes` |

Panel 10 content:

```
**Which bucket is responsible.** The aggregate tiles above tell you the footprint moved; this section tells you where. Per-bucket warning thresholds are tighter than the aggregate on purpose — videos 2 GB, photos 1 GB, backups 1 GB, TCX 256 MB, avatars 128 MB — so a single runaway bucket normally trips its own colour before the aggregate does, and the culprit is named rather than inferred. **Noncurrent** bytes only appear for the two versioned buckets (`tcx-uploads`, `database-backups`).
```

Panel 11 is a `table` with four instant targets and a `merge` transformation:

```json
      "targets": [
        { "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "sum by (bucket, purpose) (ps_s3_bucket_objects)", "refId": "A", "instant": true, "format": "table" },
        { "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "sum by (bucket) (ps_s3_bucket_bytes{version_state=\"current\"})", "refId": "B", "instant": true, "format": "table" },
        { "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "sum by (bucket) (ps_s3_bucket_bytes{version_state=\"noncurrent\"})", "refId": "C", "instant": true, "format": "table" },
        { "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "sum by (bucket) (ps_s3_bucket_bytes) / sum by (bucket) (ps_s3_bucket_objects)", "refId": "D", "instant": true, "format": "table" }
      ],
      "transformations": [
        { "id": "merge", "options": {} },
        {
          "id": "organize",
          "options": {
            "excludeByName": { "Time": true, "__name__": true },
            "renameByName": {
              "bucket": "Bucket",
              "purpose": "Purpose",
              "Value #A": "Objects",
              "Value #B": "Current bytes",
              "Value #C": "Noncurrent bytes",
              "Value #D": "Mean object size"
            }
          }
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "decbytes" },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Objects" },
            "properties": [{ "id": "unit", "value": "short" }, { "id": "decimals", "value": 0 }]
          }
        ]
      }
```

Panel 11 description: "One row per bucket: object count, bytes held by current versions, bytes held by noncurrent versions, and mean object size. Mean object size is the quickest read on the uncompressed-media trade — if the mean photo or video size climbs, users are uploading bigger files, which is a different problem from uploading more of them."

Panel 12 description: "Stored bytes per bucket, stacked so the band heights sum to the aggregate total in the section above. The band that grows is the bucket to investigate."

Panel 13 description: "Object count per bucket right now. Expect TCX and photos to dominate by count while videos dominate by bytes — that asymmetry is normal and is why both views are here."

Panel 14 description: "Bytes added per bucket over the last 24 hours. Negative bars are lifecycle rules reaping orphaned or noncurrent objects, which is the system working. A tall positive bar on one bucket localises a growth event to a single upload path."

- [ ] **Step 6: Add the "Photos & videos" section (panels 15–25)**

This is the issue's headline section. Panel 10-style text first, then eight
stat tiles and a timeseries.

| id | type | title | gridPos | expr | unit | thresholds |
|---|---|---|---|---|---|---|
| 15 | row | Photos & videos | `h1 w24 x0 y40` | — | — | — |
| 16 | text | — | `h3 w24 x0 y41` | content below | — | — |
| 17 | stat | Photos stored | `h4 w6 x0 y44` | `sum(ps_s3_bucket_objects{purpose="activity-photos"})` | `short`, 0 dec | none |
| 18 | stat | Photo storage | `h4 w6 x6 y44` | `sum(ps_s3_bucket_bytes{purpose="activity-photos"})` | `decbytes` | `null`→`1000000000`→`5000000000` |
| 19 | stat | Videos stored | `h4 w6 x12 y44` | `sum(ps_s3_bucket_objects{purpose="activity-videos"})` | `short`, 0 dec | none |
| 20 | stat | Video storage | `h4 w6 x18 y44` | `sum(ps_s3_bucket_bytes{purpose="activity-videos"})` | `decbytes` | `null`→`2000000000`→`10000000000` |
| 21 | stat | Mean photo size | `h4 w6 x0 y48` | `sum(ps_s3_bucket_bytes{purpose="activity-photos"}) / sum(ps_s3_bucket_objects{purpose="activity-photos"})` | `decbytes` | `null`→`5000000`→`15000000` |
| 22 | stat | Mean video size | `h4 w6 x6 y48` | `sum(ps_s3_bucket_bytes{purpose="activity-videos"}) / sum(ps_s3_bucket_objects{purpose="activity-videos"})` | `decbytes` | `null`→`100000000`→`300000000` |
| 23 | stat | Largest photo | `h4 w6 x12 y48` | `max(ps_s3_bucket_largest_object_bytes{purpose="activity-photos"})` | `decbytes` | `null`→`25000000`→`50000000` |
| 24 | stat | Largest video | `h4 w6 x18 y48` | `max(ps_s3_bucket_largest_object_bytes{purpose="activity-videos"})` | `decbytes` | `null`→`500000000`→`1000000000` |
| 25 | timeseries | Photo vs video storage over time | `h8 w24 x0 y52` | two targets: `sum(ps_s3_bucket_bytes{purpose="activity-photos"})` legend `photos`, `sum(ps_s3_bucket_bytes{purpose="activity-videos"})` legend `videos` | `decbytes` | — |

Panel 16 content:

```
**The reason this dashboard exists.** Activity photos and videos are stored uncompressed, so the footprint here grows faster than anywhere else and is the most likely thing to surprise you. Counts and totals answer "how much"; **mean size** and **largest** answer "why" — more uploads and bigger uploads are different problems with different fixes. Videos are written to S3 by **browser-direct presigned PUT**, bypassing the API entirely, so nothing server-side sees their size until the commit call; these tiles are the ground truth.
```

Descriptions:

- **17:** "Number of activity photo objects. Photos flow through the API, so this should track the number of activities with photos attached."
- **18:** "Total bytes in the activity photo bucket. Warning at 1 GB, critical at 5 GB — a fifth of the aggregate budget, which is roughly what photos should account for if videos stay the dominant cost."
- **19:** "Number of activity video objects. Compare with the photo count: videos should be far rarer and far larger."
- **20:** "Total bytes in the activity video bucket. Warning at 2 GB, critical at 10 GB — the loosest per-bucket budget on the dashboard, because video is expected to dominate, and half the aggregate critical, because it is also the most likely single cause of crossing it."
- **21:** "Mean photo size (total bytes ÷ object count). Uncompressed phone photos land around 3–8 MB. Warning at 5 MB and critical at 15 MB flag a shift toward larger source images — that is the number to revisit if compression is ever reconsidered."
- **22:** "Mean video size. Warning at 100 MB, critical at 300 MB. A rising mean with a flat count means users are uploading longer or higher-resolution clips, which scales cost far faster than more uploads do."
- **23:** "The single largest photo object. Warning at 25 MB, critical at 50 MB — at that size a single upload is an outlier worth looking at directly, not a trend."
- **24:** "The single largest video object. Warning at 500 MB, critical at 1 GB. Because the browser PUTs video straight to S3, nothing rejects an enormous file before it lands; this tile is how you find out one did."
- **25:** "Photo and video storage plotted together over the dashboard window. The gap between the two lines is the honest picture of what media costs: expect videos to sit well above photos and to grow in steps rather than smoothly."

- [ ] **Step 7: Add the "TCX & avatars" section (panels 26–32)**

| id | type | title | gridPos | expr | unit | thresholds |
|---|---|---|---|---|---|---|
| 26 | row | TCX & avatars | `h1 w24 x0 y60` | — | — | — |
| 27 | text | — | `h3 w24 x0 y61` | content below | — | — |
| 28 | stat | TCX files | `h4 w6 x0 y64` | `sum(ps_s3_bucket_objects{purpose="tcx-uploads"})` | `short`, 0 dec | none |
| 29 | stat | TCX storage | `h4 w6 x6 y64` | `sum(ps_s3_bucket_bytes{purpose="tcx-uploads"})` | `decbytes` | `null`→`256000000`→`1000000000` |
| 30 | stat | Avatars | `h4 w6 x12 y64` | `sum(ps_s3_bucket_objects{purpose="user-avatars"})` | `short`, 0 dec | none |
| 31 | stat | Avatar storage | `h4 w6 x18 y64` | `sum(ps_s3_bucket_bytes{purpose="user-avatars"})` | `decbytes` | `null`→`128000000`→`512000000` |
| 32 | timeseries | TCX & avatar storage over time | `h8 w24 x0 y68` | two targets: `sum(ps_s3_bucket_bytes{purpose="tcx-uploads"})` legend `tcx`, `sum(ps_s3_bucket_bytes{purpose="user-avatars"})` legend `avatars` | `decbytes` | — |

Panel 27 content:

```
**The small, steady buckets.** TCX files are XML activity exports — kilobytes each, one per imported workout, so this bucket grows linearly with usage and should never be large. Avatars are one current image per user, with superseded ones tagged `avatar-status=orphaned` and expired after 7 days by a lifecycle rule. Either of these growing quickly means something is wrong rather than something is popular: TCX because the files are tiny, avatars because there is only one user.
```

Descriptions:

- **28:** "Count of TCX activity files. Grows by one per imported workout and never shrinks — this bucket is versioned with a 30-day noncurrent expiration rather than an orphan-reaping rule."
- **29:** "Total bytes of TCX uploads, current and noncurrent versions. Warning at 256 MB, critical at 1 GB. TCX files are kilobytes, so reaching a gigabyte would mean either tens of thousands of activities or a re-upload loop."
- **30:** "Count of avatar objects. Expect roughly one per user plus any orphaned images not yet expired by the 7-day lifecycle rule. A count far above the user count means orphan tagging is failing."
- **31:** "Total bytes of avatar images. Warning at 128 MB, critical at 512 MB — the tightest budget on the dashboard, because a single-user app storing half a gigabyte of avatars is definitionally a bug."
- **32:** "TCX and avatar storage over the dashboard window. Both should be near-flat lines with a gentle upward slope on TCX. Sawtooth on avatars is the orphan lifecycle rule reaping superseded images, which is healthy."

- [ ] **Step 8: Add the "Versioned overhead" section (panels 33–38 and 51)**

| id | type | title | gridPos | expr | unit | thresholds |
|---|---|---|---|---|---|---|
| 33 | row | Versioned overhead | `h1 w24 x0 y76` | — | — | — |
| 34 | text | — | `h3 w24 x0 y77` | content below | — | — |
| 35 | timeseries | Current vs noncurrent bytes | `h8 w12 x0 y80` | `sum by (version_state) (ps_s3_bucket_bytes{purpose=~"tcx-uploads\|database-backups"})`, legend `{{version_state}}`, stacked | `decbytes` | — |
| 36 | stat | Noncurrent bytes | `h4 w6 x12 y80` | `sum(ps_s3_bucket_bytes{version_state="noncurrent"})` | `decbytes` | `null`→`2000000000`→`8000000000` |
| 37 | stat | Noncurrent share | `h4 w6 x18 y80` | `sum(ps_s3_bucket_bytes{version_state="noncurrent"}) / sum(ps_s3_bucket_bytes)` | `percentunit` | `null`→`0.5`→`0.75` |
| 38 | stat | Delete markers | `h4 w6 x12 y84` | `sum(ps_s3_bucket_delete_markers)` | `short`, 0 dec | none |
| 51 | stat | Backup storage | `h4 w6 x18 y84` | `sum(ps_s3_bucket_bytes{purpose="database-backups"})` | `decbytes` | `null`→`1000000000`→`4000000000` |

Panel 34 content:

```
**What versioning costs you.** Two buckets are versioned: `tcx-uploads` and `database-backups`. Every overwrite leaves the previous version behind, billed as storage until the 30-day `expire-noncurrent-versions` lifecycle rule reaps it. Litestream rewrites WAL segments continuously, so a substantial and *stable* noncurrent share is expected here and is not a leak — the shape to worry about is a noncurrent line that climbs without ever levelling off, which means the lifecycle rule is not keeping up. Delete markers are zero-byte tombstones: counted here because a growing pile signals churn, but excluded from every byte total because AWS does not bill for them.
```

Descriptions:

- **35:** "Current versus noncurrent bytes across the two versioned buckets, stacked. A steady-state noncurrent band is the 30-day lifecycle window doing its job. A band that grows without plateauing means objects are being rewritten faster than they expire."
- **36:** "Bytes held by noncurrent versions across all buckets — storage you are paying for that no code reads. Warning at 2 GB, critical at 8 GB. Because it should plateau, a crossing indicates rewrite rate has outgrown the 30-day expiration window."
- **37:** "Noncurrent bytes as a fraction of the total footprint. Warning above 50%, critical above 75%: at that point most of the bill is dead versions, and the fix is shortening `noncurrent_version_expiration_days` in prod.tfvars rather than reducing uploads."
- **38:** "Delete markers across all buckets. Zero-byte and unbilled, so this has no thresholds — it is a churn signal. A steadily climbing count with flat object counts means objects are being deleted and recreated rather than updated in place."
- **51:** "Total bytes in the Litestream database-backup bucket, current and noncurrent versions together. Warning at 1 GB, critical at 4 GB. This bucket is the one whose size is unrelated to user behaviour — it tracks SQLite write volume — so it lives in this section rather than beside the user-upload tiles."

- [ ] **Step 9: Add the "Waste" section (panels 39–44)**

| id | type | title | gridPos | expr | unit | thresholds |
|---|---|---|---|---|---|---|
| 39 | row | Waste | `h1 w24 x0 y88` | — | — | — |
| 40 | text | — | `h3 w24 x0 y89` | content below | — | — |
| 41 | stat | Abandoned multipart uploads | `h4 w8 x0 y92` | `sum(ps_s3_multipart_uploads)` | `short`, 0 dec | `null`→`1`→`5` |
| 42 | stat | Bytes held by multipart uploads | `h4 w8 x8 y92` | `sum(ps_s3_multipart_bytes)` | `decbytes` | `null`→`100000000`→`1000000000` |
| 43 | stat | Oldest multipart upload | `h4 w8 x16 y92` | `max(ps_s3_multipart_oldest_age_seconds)` | `s`, 0 dec | `null`→`86400`→`604800` |
| 44 | timeseries | Multipart uploads over time | `h8 w24 x0 y96` | `sum by (bucket) (ps_s3_multipart_uploads)`, legend `{{bucket}}` | `short` | — |

Panel 40 content:

```
**Storage nobody is looking at.** When a multipart upload starts and never completes, S3 keeps the uploaded parts and bills for them indefinitely. They appear in no object listing and in no CloudWatch storage metric — the only way to see them is to ask for them, which is what the exporter does. This matters most for **activity videos**, which the browser PUTs directly to S3: a closed tab or a dropped connection mid-upload leaves parts behind, and **no lifecycle rule in this repo reaps them today**. A non-zero count that persists past a day is real waste; the fix is an `abort_incomplete_multipart_upload` lifecycle rule, deliberately deferred until this panel shows it is actually happening.
```

Descriptions:

- **41:** "Count of multipart uploads that were started and never completed or aborted. A brief non-zero value during an active video upload is normal. Warning at 1 and critical at 5 are intentionally tight because the steady state is zero — the paired alert waits 24h before firing so an in-flight upload never pages."
- **42:** "Bytes held by those incomplete uploads, obtained by listing each upload's parts. Warning at 100 MB, critical at 1 GB. This is billed storage that no object listing shows."
- **43:** "Age of the oldest incomplete multipart upload. Warning at 24 hours, critical at 7 days. Anything older than a day is abandoned rather than in flight, and will sit there until something aborts it."
- **44:** "Incomplete multipart uploads per bucket over time. Expect brief spikes on the video bucket during uploads and flat zero everywhere else. A line that never returns to zero is the abandoned-parts case."

- [ ] **Step 10: Add the "Exporter health" section (panels 45–50)**

| id | type | title | gridPos | expr | unit | thresholds |
|---|---|---|---|---|---|---|
| 45 | row | Exporter health | `h1 w24 x0 y104` | — | — | — |
| 46 | text | — | `h3 w24 x0 y105` | content below | — | — |
| 47 | stat | Time since last scan | `h4 w8 x0 y108` | `time() - ps_s3_last_scan_timestamp_seconds` | `s`, 0 dec | `null`→`1800`→`3600` |
| 48 | stat | Slowest bucket scan | `h4 w8 x8 y108` | `max(ps_s3_scan_duration_seconds)` | `s`, 2 dec | `null`→`30`→`120` |
| 49 | stat | Scan errors (24h) | `h4 w8 x16 y108` | `sum(increase(ps_s3_scan_errors_total[24h]))` | `short`, 0 dec | `null`→`1`→`5` |
| 50 | timeseries | Scan errors by bucket | `h8 w24 x0 y112` | `sum by (bucket) (increase(ps_s3_scan_errors_total[1h]))`, legend `{{bucket}}` | `short` | — |

Panel 46 content:

```
**Can you trust the numbers above?** A dead exporter and a perfectly stable footprint look identical on every other panel on this dashboard — flat lines, green tiles, no errors. **Time since last scan** is the tile that distinguishes them, and it is the one with a Slack alert attached. The timestamp only advances when *every* bucket scanned successfully, so a partial failure shows up here as staleness rather than being hidden behind four working buckets.
```

Descriptions:

- **47:** "Seconds since the last scan in which every bucket succeeded. The exporter rescans every 15 minutes, so this should sawtooth between 0 and ~900. Warning at 30 minutes (two missed cycles), critical at 1 hour. This tile is the reason the dashboard can be trusted — it pages Slack, because a silently dead exporter is exactly how the WHOOP webhook stayed broken for months."
- **48:** "Duration of the last successful scan for the slowest bucket. This is a cost proxy as much as a latency one: scan time scales with object count, and so do LIST charges. Warning at 30s, critical at 2 minutes — at that point consider lengthening S3_EXPORTER_REFRESH_SECONDS."
- **49:** "Failed bucket scans in the last 24 hours. Individual failures are contained — the affected bucket keeps its last good values while the others update — so a handful here means the numbers are stale for some buckets, not wrong for all. Sustained errors usually mean an IAM permission was removed."
- **50:** "Scan failures per bucket per hour. The bucket label points straight at the problem: a single bucket failing is almost always a missing IAM action on that bucket's policy, while all five failing together is credentials or connectivity."

- [ ] **Step 11: Validate the finished dashboard**

Run:
```bash
python3 -c "
import json
d = json.load(open('monitoring/grafana/dashboards/s3-storage.json'))
ids = [p['id'] for p in d['panels']]
assert len(ids) == len(set(ids)), 'duplicate panel ids'
assert {8, 41, 47} <= set(ids), 'alert-linked panels 8/41/47 must exist'
missing = [p['id'] for p in d['panels']
           if p['type'] not in ('row', 'text') and not p.get('description')]
assert not missing, f'panels missing descriptions: {missing}'
print('panels:', len(ids), '- all non-text panels documented')
"
```
Expected: `panels: 51 - all non-text panels documented`

Every threshold in the spec's table now has a tile that carries it: aggregate
(4), videos (20), photos (18), backups (51), TCX (29), avatars (31).

- [ ] **Step 12: Commit**

```bash
git add monitoring/grafana/dashboards/s3-storage.json
git commit -m "feat(grafana): add the S3 Storage dashboard

Six documented sections: aggregate footprint, per-bucket breakdown,
photos and videos, TCX and avatars, versioned overhead, abandoned
multipart uploads, and exporter health.

Refs #59"
```

---

### Task 7: Alert rules

**Files:**
- Create: `monitoring/grafana/provisioning/alerting/rules-s3-storage.yml`

Grafana validates provisioning at **startup** and one bad rule stops the whole
provisioning service, taking dashboards and alerting down with it. Two rules
that shipped `__dashboardUid__` without `__panelId__` did exactly that on
2026-07-31. `validate_rules.py` now gates this — run it before committing.

**No literal `$` anywhere in this file.** Grafana expands `$VAR` from the
container environment in provisioning files.

- [ ] **Step 1: Write the rules file**

Create `monitoring/grafana/provisioning/alerting/rules-s3-storage.yml`:

```yaml
# S3 storage footprint alerts. Mirrors the ps-s3-storage dashboard, whose
# "Total footprint over time" panel (id 8) draws reference lines at the same
# 5 GB / 20 GB thresholds these rules evaluate.
#
# Thresholds are growth tripwires, not cost limits: 20 GB of S3 Standard costs
# well under a dollar a month. Prog Strength is single-user and pre-launch, so
# a footprint crossing these means the shape of storage changed — an upload
# path misbehaving, a reaper not reaping — long before it means a bill.
#
# for: 30m on the size rules — the exporter rescans every 15 minutes, so a
#   30-minute window needs two consecutive scans to agree before paging.
# noDataState: OK on the size rules — the series does not exist until the
#   exporter's first successful scan, and absence is covered by
#   s3-exporter-stale below rather than by every rule separately.
# execErrState: Alerting throughout — a broken query (metric renamed, exporter
#   removed) should surface loudly, per this repo's fail-loud philosophy.

apiVersion: 1

groups:
  - orgId: 1
    name: s3-storage
    folder: Prog Strength Alerts
    interval: 5m
    rules:
      - uid: s3-footprint-warning
        title: S3 footprint above warning threshold
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 3600
              to: 0
            datasourceUid: prometheus
            model:
              refId: A
              expr: sum(ps_s3_bucket_bytes)
              instant: true
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [5000000000]
        noDataState: OK
        execErrState: Alerting
        for: 30m
        labels:
          severity: warning
          service: s3-storage
        annotations:
          summary: >-
            Total S3 storage across all Prog Strength buckets is above 5 GB.
            Check which bucket grew on the By bucket section of the dashboard.
          __dashboardUid__: ps-s3-storage
          __panelId__: "8"

      - uid: s3-footprint-critical
        title: S3 footprint above critical threshold
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 3600
              to: 0
            datasourceUid: prometheus
            model:
              refId: A
              expr: sum(ps_s3_bucket_bytes)
              instant: true
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [20000000000]
        noDataState: OK
        execErrState: Alerting
        for: 30m
        labels:
          severity: critical
          service: s3-storage
        annotations:
          summary: >-
            Total S3 storage across all Prog Strength buckets is above 20 GB,
            far more than a single-user deployment should hold. Investigate
            before the next billing period.
          __dashboardUid__: ps-s3-storage
          __panelId__: "8"

      - uid: s3-exporter-stale
        title: S3 footprint exporter has stopped reporting
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 3600
              to: 0
            datasourceUid: prometheus
            model:
              refId: A
              expr: time() - ps_s3_last_scan_timestamp_seconds
              instant: true
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [3600]
        # noDataState: Alerting is deliberate and differs from every other rule
        # in this directory. For a liveness monitor the ABSENCE of the series
        # IS the failure: a dead exporter serves no metrics, and a dashboard
        # showing flat green lines from a dead exporter is worse than no
        # dashboard. The WHOOP webhook sat broken from ship until 2026-07-31
        # precisely because nothing alerted on silence.
        noDataState: Alerting
        execErrState: Alerting
        for: 15m
        labels:
          severity: critical
          service: s3-storage
        annotations:
          summary: >-
            No successful S3 scan in over an hour. The S3 Storage dashboard is
            showing stale numbers. Check the s3_exporter container on the
            backend host.
          __dashboardUid__: ps-s3-storage
          __panelId__: "47"

      - uid: s3-abandoned-multipart
        title: Abandoned S3 multipart uploads
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 3600
              to: 0
            datasourceUid: prometheus
            model:
              refId: A
              expr: sum(ps_s3_multipart_uploads)
              instant: true
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [0]
        noDataState: OK
        execErrState: Alerting
        # 24h so a genuinely in-flight video upload never pages. Anything still
        # incomplete a day later was abandoned, and its parts are billed until
        # something aborts them.
        for: 24h
        labels:
          severity: warning
          service: s3-storage
        annotations:
          summary: >-
            An S3 multipart upload has been incomplete for over 24 hours. Its
            parts are billed as storage and no lifecycle rule reaps them.
            Most likely a browser-direct activity video upload that failed.
          __dashboardUid__: ps-s3-storage
          __panelId__: "41"
```

- [ ] **Step 2: Validate the rules**

Run: `python3 monitoring/grafana/provisioning/alerting/validate_rules.py`
Expected: the validator's success output, with no problems reported for
`rules-s3-storage.yml`.

- [ ] **Step 3: Confirm the panel links resolve**

Run:
```bash
python3 -c "
import json, yaml
dash = json.load(open('monitoring/grafana/dashboards/s3-storage.json'))
ids = {str(p['id']) for p in dash['panels']}
doc = yaml.safe_load(open('monitoring/grafana/provisioning/alerting/rules-s3-storage.yml'))
for group in doc['groups']:
    for rule in group['rules']:
        ann = rule['annotations']
        assert ann['__dashboardUid__'] == dash['uid'], rule['uid']
        assert ann['__panelId__'] in ids, f\"{rule['uid']} -> panel {ann['__panelId__']} missing\"
print('all alert panel links resolve')
"
```
Expected: `all alert panel links resolve`

- [ ] **Step 4: Commit**

```bash
git add monitoring/grafana/provisioning/alerting/rules-s3-storage.yml
git commit -m "feat(alerting): add S3 footprint and exporter-liveness alerts

Warning/critical on aggregate size, a 24h abandoned-multipart warning,
and a staleness alert with noDataState: Alerting so a dead exporter
cannot show flat green lines forever.

Refs #59"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Document the exporter in `AGENTS.md`**

In the "Repo layout" section, after the sentence listing the non-Terraform
directories (`compose/`, `caddy/`, `monitoring/`), add:

```markdown
`monitoring/s3_exporter/` is the one piece of application code this repo
ships: a small Python Prometheus exporter that lists the S3 buckets and
publishes footprint gauges for the `S3 Storage` dashboard. It runs as a
compose service on the backend host, is built there rather than pulled from
ECR (so `deploy/api.sh` passes `--build`), and reads AWS credentials from the
instance profile. Its unit tests are a PR gate (`lint.yml`).
```

- [ ] **Step 2: Document the exporter in `README.md`**

In the monitoring section, add a short subsection:

```markdown
### S3 footprint exporter

`monitoring/s3_exporter/` scans the five application buckets every 15 minutes
and serves `ps_s3_*` gauges on `:9103` for Prometheus. The bucket list lives in
`monitoring/s3_exporter/buckets.yml` and must be updated when a bucket is added
or renamed in `environments/prod.tfvars`.

Tuning knobs (compose service env, `docker-compose.monitoring.yml`):

| Variable | Default | Notes |
| --- | --- | --- |
| `S3_EXPORTER_REFRESH_SECONDS` | `900` | Seconds between full scans. Raise it if scan duration climbs — LIST requests are billed per request. |
| `S3_EXPORTER_PORT` | `9103` | Must match the Prometheus scrape target. |
| `S3_EXPORTER_CONFIG` | `buckets.yml` | Path to the bucket list inside the image. |

Run the tests with `python3 -m pytest monitoring/s3_exporter/tests -q`.
```

- [ ] **Step 3: Commit**

```bash
git add README.md AGENTS.md
git commit -m "docs: document the S3 footprint exporter

Refs #59"
```

---

### Task 9: Verify end to end and open the PR

- [ ] **Step 1: Run every local gate**

```bash
terraform fmt -check -recursive
tflint --recursive --format compact
python3 monitoring/grafana/provisioning/alerting/validate_rules.py
python3 -m pytest monitoring/s3_exporter/tests -q
shellcheck -x modules/compute/bootstrap.sh deploy/*.sh deploy/lib/*.sh deploy/tests/*.sh
for t in deploy/tests/*.test.sh; do bash "$t" || exit 1; done
```
Expected: all pass, no output from `fmt -check` or `tflint`.

- [ ] **Step 2: Open the PR**

```bash
git push -u origin feat/s3-storage-dashboard
gh pr create --title "feat(monitoring): S3 storage footprint dashboard" --body "$(cat <<'EOF'
Closes #59.

Adds an `S3 Storage` Grafana dashboard backed by a new Prometheus exporter
that lists the five application buckets directly.

**Why an exporter rather than CloudWatch:** S3's free storage metrics publish
once a day with up to 48h of lag, which is useless for watching an upload
feature that can balloon in an afternoon. Listing the buckets is exact, as
fresh as the 15-minute refresh interval, and the instance role already had
`s3:ListBucket` on all five.

**What it counts:** current and noncurrent object versions, delete markers
(counted, not billed), largest object per bucket, and incomplete multipart
uploads — the last of which are billed, reaped by no lifecycle rule, and
invisible to both object listings and CloudWatch. That matters most for
activity videos, which browsers PUT directly to S3.

**Thresholds are growth tripwires, not cost limits.** Aggregate warning 5 GB,
critical 20 GB.

**Alerts:** aggregate size warning/critical, a 24h abandoned-multipart warning,
and an exporter-staleness alert with `noDataState: Alerting` — a dead exporter
and a stable footprint look identical on every other panel.

**Note for review:** `deploy/api.sh` now passes `--build`. The exporter is
built on the host rather than pulled from ECR, and without `--build` compose
would keep running a stale image after a code change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Read the Terraform plan comment before merging**

The plan must show only `aws_iam_policy` updates (five of them) and **no**
`aws_instance.backend` replacement. If any resource shows `# forces
replacement`, stop and fix the root cause.

- [ ] **Step 4: Verify on the host after merge**

The monitoring stack redeploys with the next API release. Once it has:

```bash
# Exporter is up and scraping cleanly
curl -s localhost:9090/api/v1/targets | python3 -m json.tool | grep -A3 s3_exporter

# Every bucket reports
curl -s 'localhost:9090/api/v1/query?query=ps_s3_bucket_bytes' | python3 -m json.tool
```
Expected: the `s3_exporter` target is `up`, and five buckets appear with
plausible non-zero `current` values. Then open
`https://monitoring.progstrength.fitness/d/ps-s3-storage` and confirm no panel
reads "No data" apart from the 7-day growth tile, which needs a week of history.

---

## Notes for the implementer

- **Do not renumber dashboard panels.** Alert rules bind to panel ids 8, 41,
  and 47 through `__panelId__`, and a mismatch is caught by Task 7 Step 3.
- **Never put a literal `$` in a provisioning YAML file.** Grafana expands it
  from the container environment; `validate_rules.py` will reject it.
- **One concern per PR is the repo rule**, but this change is a single
  concern deliberately split across commits: exporter, permissions, wiring,
  dashboard, alerts, docs. Keep the commits separate so the diff reads in that
  order.
- **`ps_s3_scan_errors` vs `ps_s3_scan_errors_total`:** `prometheus_client`
  appends `_total` to counter names. Declare the former, query the latter.

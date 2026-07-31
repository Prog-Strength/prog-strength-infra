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

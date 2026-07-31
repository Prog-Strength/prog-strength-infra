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

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


class _StopLoop(Exception):
    """Raised from the patched time.sleep to escape main()'s infinite loop."""


def _write_config(tmp_path):
    config = tmp_path / "buckets.yml"
    config.write_text("buckets:\n  - name: bkt-a\n    purpose: activity-photos\n")
    return str(config)


def _patch_main_collaborators(monkeypatch, tmp_path, *, port=None, refresh_seconds=None):
    """Wire main()'s external dependencies to spies and cap the loop at one
    iteration. Returns a dict that main() fills in as it runs."""
    calls = {}

    monkeypatch.setenv("S3_EXPORTER_CONFIG", _write_config(tmp_path))
    if port is not None:
        monkeypatch.setenv("S3_EXPORTER_PORT", str(port))
    else:
        monkeypatch.delenv("S3_EXPORTER_PORT", raising=False)
    if refresh_seconds is not None:
        monkeypatch.setenv("S3_EXPORTER_REFRESH_SECONDS", str(refresh_seconds))
    else:
        monkeypatch.delenv("S3_EXPORTER_REFRESH_SECONDS", raising=False)

    monkeypatch.setattr(s3_exporter.boto3, "client", lambda service: calls.setdefault("client", "fake-s3-client"))

    real_build_metrics = s3_exporter.build_metrics

    def spy_build_metrics():
        registry, metrics = real_build_metrics()
        calls["registry"] = registry
        calls["metrics"] = metrics
        return registry, metrics

    monkeypatch.setattr(s3_exporter, "build_metrics", spy_build_metrics)

    def fake_start_http_server(port, registry=None):
        calls["server_port"] = port
        calls["server_registry"] = registry

    monkeypatch.setattr(s3_exporter, "start_http_server", fake_start_http_server)

    def fake_refresh(metrics, client, buckets, now):
        calls["refresh_metrics"] = metrics
        calls["refresh_client"] = client
        calls["refresh_buckets"] = buckets
        calls["refresh_now"] = now

    monkeypatch.setattr(s3_exporter, "refresh", fake_refresh)

    def fake_sleep(seconds):
        calls["sleep_seconds"] = seconds
        raise _StopLoop()

    monkeypatch.setattr(s3_exporter.time, "sleep", fake_sleep)

    return calls


def test_main_wires_env_config_registry_and_calls_refresh_before_sleeping(monkeypatch, tmp_path):
    calls = _patch_main_collaborators(monkeypatch, tmp_path)

    with pytest.raises(_StopLoop):
        s3_exporter.main()

    # Defaults, since S3_EXPORTER_PORT / S3_EXPORTER_REFRESH_SECONDS are unset.
    assert calls["server_port"] == s3_exporter.DEFAULT_PORT
    assert calls["sleep_seconds"] == s3_exporter.DEFAULT_REFRESH_SECONDS

    # The registry handed to start_http_server must be the one build_metrics()
    # actually built -- not a second, disconnected registry -- or Prometheus
    # would scrape an empty set of series.
    assert calls["server_registry"] is calls["registry"]
    assert calls["refresh_metrics"] is calls["metrics"]
    assert calls["refresh_client"] == "fake-s3-client"
    assert calls["refresh_buckets"] == [("bkt-a", "activity-photos")]

    # refresh() only ran because it's captured in `calls`; the loop reaches
    # time.sleep() (and raises _StopLoop) strictly after refresh() returns.
    assert "refresh_buckets" in calls


def test_main_honours_nondefault_port_and_refresh_interval(monkeypatch, tmp_path):
    calls = _patch_main_collaborators(monkeypatch, tmp_path, port=9999, refresh_seconds=42)

    with pytest.raises(_StopLoop):
        s3_exporter.main()

    assert calls["server_port"] == 9999
    assert calls["sleep_seconds"] == 42

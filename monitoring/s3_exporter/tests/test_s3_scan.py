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
    """Minimal stand-in for a boto3 S3 client.

    Retains the paginator it hands out for each operation (keyed by
    operation name, last one wins) so tests can assert on the kwargs a
    paginator's `.paginate()` was actually called with -- not just the
    aggregated result, which would pass even if scan_bucket called the
    wrong operation with the wrong arguments.
    """

    def __init__(self, versions=None, uploads=None, parts=None):
        self._pages = {
            "list_object_versions": versions if versions is not None else [{}],
            "list_multipart_uploads": uploads if uploads is not None else [{}],
            "list_parts": parts if parts is not None else [{}],
        }
        self.paginators = {}

    def get_paginator(self, operation_name):
        paginator = FakePaginator(self._pages[operation_name])
        self.paginators[operation_name] = paginator
        return paginator


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
    # A multipart upload is included so there is a list_parts call to
    # inspect too -- that call is the one most at risk of a Key/UploadId
    # mixup, since both are plain strings passed positionally in spirit.
    client = FakeS3(
        uploads=[{
            "Uploads": [
                {"Key": "vid.mp4", "UploadId": "abc123", "Initiated": _at(0)},
            ],
        }],
    )

    scan = s3_scan.scan_bucket(client, "prog-strength-avatars", "user-avatars", now=0)

    assert scan.bucket == "prog-strength-avatars"
    assert scan.purpose == "user-avatars"

    assert client.paginators["list_object_versions"].kwargs == {
        "Bucket": "prog-strength-avatars",
    }
    assert client.paginators["list_multipart_uploads"].kwargs == {
        "Bucket": "prog-strength-avatars",
    }
    assert client.paginators["list_parts"].kwargs == {
        "Bucket": "prog-strength-avatars",
        "Key": "vid.mp4",
        "UploadId": "abc123",
    }


def test_largest_object_spans_noncurrent_versions():
    # largest_object_bytes exists to answer "what could be costing money",
    # not "what is currently live" -- a noncurrent version is still billed
    # storage until its 30-day expiration, so it must be able to win here
    # even though a smaller object is the one actually reachable.
    client = FakeS3(versions=[{
        "Versions": [
            {"Key": "a", "Size": 10, "IsLatest": True},
            {"Key": "a", "Size": 5000, "IsLatest": False},
        ],
    }])

    scan = s3_scan.scan_bucket(client, "bkt", "activity-videos", now=0)

    assert scan.largest_object_bytes == 5000

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

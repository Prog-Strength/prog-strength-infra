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

    Sizes are bytes. `largest_object_bytes` spans BOTH current and
    noncurrent versions, not just what is currently live: a noncurrent
    version is still billed storage for up to 30 days after being
    superseded, and this field exists to answer "what could be costing
    money" rather than "what is reachable" -- so a huge noncurrent version
    must be able to win here even while a smaller object is the live one.

    `multipart_*` covers uploads that were started and never completed — S3
    bills for their parts, no lifecycle rule in this repo reaps them, and
    neither the object listing nor CloudWatch's storage metrics show them.
    The video bucket is written by browser-direct presigned PUT, so an
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

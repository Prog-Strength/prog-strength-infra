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

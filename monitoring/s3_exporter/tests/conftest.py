"""Put the exporter directory on sys.path.

This repo is Terraform-first: there is no pyproject.toml and the exporter is
not an installable package. The Docker image copies the modules flat into
/app, so importing them flat here matches how they actually run.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

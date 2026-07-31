#!/usr/bin/env python3
"""Validate provisioned Grafana alert rules before they reach a real Grafana.

Why this exists: Grafana validates provisioning files at STARTUP, and a single
invalid rule is fatal to the whole provisioning service —

    level=error msg="Failed to provision alerting" error="alert rules: invalid
      alert rule: both annotations __dashboardUid__ and __panelId__ must be
      specified"
    level=error msg="Stopped background service"
      service=*provisioning.ProvisioningServiceImpl

— which takes Grafana down with it. There is no partial application and no
warning: one malformed annotation in one rule means no dashboards, no alerting,
no monitoring at all, discovered only when someone notices Grafana is gone.
That happened on 2026-07-31 (rules-whoop.yml shipped __dashboardUid__ without
__panelId__), which is why these checks are now a PR gate.

Checks, all of them failure modes Grafana only reports at boot:

  1. __dashboardUid__ and __panelId__ are all-or-nothing per rule.
  2. Rule uids are unique across every file (a duplicate silently clobbers).
  3. Required scalar fields are present (uid, title, condition).
  4. `condition` names a refId the rule's own `data` block actually defines.
  5. No literal '$' anywhere — Grafana expands $VAR from the container
     environment in provisioning files, so a stray dollar becomes an empty
     string. (See the alerting README's gotchas.)

Run directly, or via pre-commit / lint.yml:

    python3 monitoring/grafana/provisioning/alerting/validate_rules.py
"""

from __future__ import annotations

import glob
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment guard
    sys.exit("validate_rules: PyYAML is required (pip install pyyaml)")

#: Annotations Grafana treats as a linked pair. Supplying exactly one is the
#: fatal-at-boot case documented above.
PANEL_LINK_PAIR = ("__dashboardUid__", "__panelId__")

#: Scalar rule fields that must be present and non-empty.
REQUIRED_FIELDS = ("uid", "title", "condition")


def check_file(path: str, seen_uids: dict[str, str]) -> list[str]:
    """Return a list of human-readable problems found in one rules file."""
    problems: list[str] = []

    with open(path, encoding="utf-8") as handle:
        raw = handle.read()

    try:
        doc = yaml.safe_load(raw) or {}
    except yaml.YAMLError as exc:
        return [f"{path}: not valid YAML: {exc}"]

    if "$" in raw:
        # Cheap file-level scan: Grafana interpolates $VAR/${VAR} from the
        # environment, so a literal dollar silently becomes "". A deliberate
        # dollar must be written '$$'.
        for lineno, line in enumerate(raw.splitlines(), start=1):
            if "$" in line and "$$" not in line:
                problems.append(
                    f"{path}:{lineno}: literal '$' is interpolated by Grafana "
                    f"provisioning — use '$$' if you meant a dollar sign"
                )

    for group in doc.get("groups", []) or []:
        group_name = group.get("name", "<unnamed>")
        for rule in group.get("rules", []) or []:
            uid = rule.get("uid") or "<missing-uid>"
            where = f"{path} [{group_name}/{uid}]"

            for field in REQUIRED_FIELDS:
                if not rule.get(field):
                    problems.append(f"{where}: missing required field '{field}'")

            if rule.get("uid"):
                if uid in seen_uids:
                    problems.append(
                        f"{where}: duplicate rule uid, already defined in {seen_uids[uid]}"
                    )
                else:
                    seen_uids[uid] = path

            annotations = rule.get("annotations") or {}
            present = [key for key in PANEL_LINK_PAIR if key in annotations]
            if len(present) == 1:
                missing = next(k for k in PANEL_LINK_PAIR if k not in annotations)
                problems.append(
                    f"{where}: has {present[0]} but not {missing} — Grafana "
                    f"requires both or neither, and rejects the entire "
                    f"provisioning run otherwise"
                )

            condition = rule.get("condition")
            ref_ids = {node.get("refId") for node in (rule.get("data") or [])}
            if condition and condition not in ref_ids:
                known = ", ".join(sorted(r for r in ref_ids if r)) or "none"
                problems.append(
                    f"{where}: condition '{condition}' does not match any refId "
                    f"in the rule's data block (defined: {known})"
                )

    return problems


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    paths = sorted(glob.glob(os.path.join(here, "rules-*.yml")))

    if not paths:
        print("validate_rules: no rules-*.yml files found", file=sys.stderr)
        return 1

    seen_uids: dict[str, str] = {}
    problems: list[str] = []
    for path in paths:
        problems.extend(check_file(path, seen_uids))

    rel = [os.path.relpath(p, here) for p in paths]
    if problems:
        print(f"validate_rules: FAILED ({len(problems)} problem(s))", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"validate_rules: OK — {len(seen_uids)} rule(s) across {len(rel)} file(s): {', '.join(rel)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

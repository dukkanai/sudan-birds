#!/usr/bin/env python3
"""Small defense-in-depth policy checks, not a full security assessment."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
failures = []
workflows = ROOT / ".github" / "workflows"
for path in workflows.glob("*.yml"):
    content = path.read_text()
    if re.search(r"^\s*pull_request_target\s*:", content, re.M):
        failures.append(f"{path.name}: privileged PR trigger forbidden")
    for use in re.findall(r"uses:\s*([^\s]+)", content):
        if not use.startswith("./") and not re.fullmatch(r"[\w./-]+@[a-f0-9]{40}", use):
            failures.append(f"{path.name}: action must be pinned to full SHA")
    if "contents: read" not in content:
        failures.append(f"{path.name}: explicit read-only token required")

schema = "\n".join(p.read_text() for p in (ROOT / "supabase/migrations").glob("*.sql"))
tables = re.findall(r"create table(?: if not exists)? public\.([a-z_]+)", schema, re.I)
for table in tables:
    if not re.search(rf"alter table public\.{table}\s+enable row level security", schema, re.I):
        # A reviewed dynamic loop must still name every table explicitly.
        if not ("enable row level security" in schema.lower() and f"'{table}'" in schema):
            failures.append(f"{table}: no RLS enablement found")
for forbidden in ("likes", "reactions", "follows", "reposts", "subscriptions", "payments"):
    if forbidden in tables:
        failures.append(f"Out-of-scope social/payment table: {forbidden}")

for path in (ROOT / "app/lib").rglob("*.dart"):
    text = path.read_text()
    if re.search(r"\b(?:print|debugPrint)\s*\(", text):
        failures.append(f"{path.relative_to(ROOT)}: unrestricted logging forbidden")
    if re.search(r"(?:R2_ACCESS_KEY|R2_SECRET|SUPABASE_SERVICE_ROLE_KEY)", text):
        failures.append(f"{path.relative_to(ROOT)}: server secret referenced in client")

if failures:
    print("Repository policy checks failed:")
    print("\n".join(f"- {f}" for f in failures))
    sys.exit(1)
print(f"Repository policy checks passed ({len(tables)} tables checked).")

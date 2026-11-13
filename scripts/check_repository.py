#!/usr/bin/env python3
"""Small defense-in-depth policy checks, not a full security assessment."""
from pathlib import Path
import re
import hashlib
import sys
import tomllib
from workflow_permissions import has_no_token_permissions

ROOT = Path(__file__).resolve().parents[1]
failures = []
# Only these reviewed application handlers replace the legacy-secret gateway
# with Auth.getUser and caller RLS (media-read also permits anonymous RLS reads).
# The expired diagnostic keeps its separate gateway boundary and stays undeployed.
expected_gateway = {
    "contact": False,
    "media": False,
    "media-read": False,
    "account-delete": False,
    "lifecycle": False,
    "codec-diagnostic": True,
}
try:
    functions = tomllib.loads((ROOT / "supabase/config.toml").read_text()).get("functions", {})
    if (functions.keys() != expected_gateway.keys()
            or any(functions[name].get("verify_jwt") is not expected
                   for name, expected in expected_gateway.items())):
        failures.append("Edge gateway settings differ from the reviewed application/diagnostic boundary")
except (tomllib.TOMLDecodeError, AttributeError, TypeError):
    failures.append("Edge gateway configuration cannot be verified")
# Official Gradle 8.14 distribution checksum, verified from
# https://services.gradle.org/distributions/gradle-8.14-all.zip.sha256
wrapper = (ROOT / "app/android/gradle/wrapper/gradle-wrapper.properties").read_text()
if ("distributionUrl=https\\://downloads.gradle.org/distributions/gradle-8.14-all.zip" not in wrapper
        or "distributionSha256Sum=efe9a3d147d948d7528a9887fa35abcf24ca1a43ad06439996490f77569b02d1" not in wrapper):
    failures.append("Gradle wrapper: reviewed official distribution and checksum pin required")
workflows = ROOT / ".github" / "workflows"
for path in workflows.glob("*.yml"):
    content = path.read_bytes().decode('utf-8')
    if re.search(r"^\s*pull_request_target\s*:", content, re.M):
        failures.append(f"{path.name}: privileged PR trigger forbidden")
    for use in re.findall(r"uses:\s*([^\s]+)", content):
        if not use.startswith("./") and not re.fullmatch(r"[\w./-]+@[a-f0-9]{40}", use):
            failures.append(f"{path.name}: action must be pinned to full SHA")
    # Explicit zero privileges are narrower than read-only. Reject job-level
    # permission overrides on this path rather than granting an unused token.
    if "contents: read" not in content and not has_no_token_permissions(content):
        failures.append(f"{path.name}: explicit read-only or zero-token permissions required")

migrations = ROOT / "supabase/migrations"
# These files have been applied remotely. Destructive feature removal must be a
# new migration, never a rewrite of deployed database history.
for name, digest in {
    "202611080001_foundation.sql": "d45a802eb7f778eb602d578d1aaf744ea64b96636d05634345ce9e7ad72c4693",
    "202611090001_verified_media_and_deletion.sql": "da37035a01eb5c8ca4bbe0ef9937a69581d28c331ca9b40d240b8aad5d119cbe",
}.items():
    path = migrations / name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        failures.append(f"{name}: applied migration history changed")
schema = "\n".join(p.read_text() for p in sorted(migrations.glob("*.sql")))
tables = re.findall(r"create table(?: if not exists)? public\.([a-z_]+)", schema, re.I)
for table in tables:
    if not re.search(rf"alter table public\.{table}\s+enable row level security", schema, re.I):
        # A reviewed dynamic loop must still name every table explicitly.
        if not ("enable row level security" in schema.lower() and f"'{table}'" in schema):
            failures.append(f"{table}: no RLS enablement found")
for forbidden in ("likes", "reactions", "follows", "reposts", "subscriptions", "payments"):
    if forbidden in tables:
        failures.append(f"Out-of-scope social/payment table: {forbidden}")

# Only an ordered CREATE/DROP model, not a replacement for executing migrations.
active_tables = set()
for match in re.finditer(r"(create|drop) table(?: if (?:not )?exists)? public\.([a-z_]+)", schema, re.I):
    action, table = match.groups()
    if action.lower() == "create":
        active_tables.add(table.lower())
    else:
        active_tables.discard(table.lower())
for removed in ("posts", "replies", "topics"):
    if removed in active_tables:
        failures.append(f"Discontinued table remains in final schema: {removed}")
    if re.search(rf"public\.{removed}\b", (ROOT / "supabase/seed.sql").read_text()):
        failures.append(f"Seed still references discontinued table: {removed}")
for path in migrations.glob("*.sql"):
    if path.name > "202611090001_verified_media_and_deletion.sql" and re.search(
        r"drop\s+(?:table|column|function)\b[^;]*\bcascade\b", path.read_text(), re.I
    ):
        failures.append(f"{path.name}: broad cascading drop needs explicit dependency review")

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
print(f"Repository policy checks passed ({len(tables)} historical table definitions checked).")

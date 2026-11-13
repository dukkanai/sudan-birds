#!/usr/bin/env python3
"""Install the pinned official Linux amd64 CLI, with no npm postinstall."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile


VERSION = "2.67.1"
# Verified against https://api.github.com/repos/supabase/cli/releases/tags/v2.67.1
ASSET_URL = "https://api.github.com/repos/supabase/cli/releases/assets/328122062"
ARCHIVE_BYTES = 28_814_751
ARCHIVE_SHA256 = "7326f45a3354b6e44d948e4c6500ea9813247268887403ddfe9691ac2033f80e"
MAX_UNPACKED_BYTES = 128 * 1024 * 1024
ALLOWED_MEMBERS = {"LICENSE", "README.md", "supabase"}


def download_archive(destination):
    # The public release-download path repeatedly returned error pages in CI.
    # Use GitHub's official asset API, never a mirror, token, or unverified binary.
    # curl's normal retry policy retries transient failures, not 401/403 denials.
    subprocess.run([
        "curl", "--disable", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "3",
        "--connect-timeout", "10", "--max-time", "60", "--retry", "2",
        "--retry-delay", "2", "--retry-max-time", "180",
        "--max-filesize", str(ARCHIVE_BYTES),
        "--header", "Accept: application/octet-stream",
        "--header", "X-GitHub-Api-Version: 2022-11-28",
        "--output", str(destination), ASSET_URL,
    ], check=True, timeout=200)


def verify_archive(path):
    if path.stat().st_size != ARCHIVE_BYTES:
        raise ValueError("Official CLI archive size mismatch; refusing extraction")
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != ARCHIVE_SHA256:
        raise ValueError("Official CLI SHA256 mismatch; refusing extraction")


def extract_binary(archive_path, binary_path):
    # Verification must precede even parsing the archive. Never extract archive
    # paths, links, modes or ownership: write only the one named regular file.
    verify_archive(archive_path)
    seen = set()
    unpacked = 0
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            if (member.name not in ALLOWED_MEMBERS or member.name in seen
                    or not member.isfile() or member.issparse()):
                raise ValueError("Unexpected CLI archive member")
            seen.add(member.name)
            unpacked += member.size
            if member.size < 0 or unpacked > MAX_UNPACKED_BYTES:
                raise ValueError("CLI archive exceeds extraction limit")
            if member.name == "supabase":
                if member.size == 0:
                    raise ValueError("CLI binary is empty")
                with archive.extractfile(member) as source, binary_path.open("xb") as target:
                    shutil.copyfileobj(source, target, length=64 * 1024)
                if binary_path.stat().st_size != member.size:
                    raise ValueError("CLI binary is truncated")
    if "supabase" not in seen:
        raise ValueError("CLI binary is missing")


def install(target):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("This pinned installer requires Linux amd64")
    target.parent.mkdir(parents=True, exist_ok=True)
    # A failed download/extraction/version check leaves no executable at target.
    # An existing installation, if any, is only replaced after full validation.
    with tempfile.TemporaryDirectory(prefix=".supabase-install-", dir=target.parent) as work:
        archive = Path(work) / "supabase.tar.gz"
        binary = Path(work) / "supabase"
        download_archive(archive)
        extract_binary(archive, binary)
        binary.chmod(0o755)
        result = subprocess.run([str(binary), "--version"], check=True,
                                timeout=10, capture_output=True, text=True)
        if result.stdout.strip() != VERSION:
            raise ValueError("Installed CLI version does not match pin")
        os.replace(binary, target)


def main():
    try:
        runner_temp = Path(os.environ["RUNNER_TEMP"])
        if not runner_temp.is_absolute():
            raise ValueError("RUNNER_TEMP must be an absolute directory")
        install(runner_temp / "birds-cli/node_modules/.bin/supabase")
    except (KeyError, OSError, ValueError, tarfile.TarError,
            subprocess.SubprocessError) as error:
        print(f"Supabase CLI installation failed: {error}", file=sys.stderr)
        return 1
    print(f"Installed checksum-verified official Supabase CLI {VERSION}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

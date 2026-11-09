import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import install_supabase as installer


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.archive = self.root / "asset.tar.gz"
        self.binary = self.root / "supabase"

    def fixture(self, members=None):
        if members is None:
            members = [("LICENSE", b"license"), ("supabase", b"synthetic CLI")]
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, data in members:
                info = name if isinstance(name, tarfile.TarInfo) else tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        # Test fixtures get isolated mock pins. No runtime pin override exists.
        self.addCleanup(patch.stopall)
        patch.object(installer, "ARCHIVE_BYTES", self.archive.stat().st_size).start()
        patch.object(installer, "ARCHIVE_SHA256",
                     hashlib.sha256(self.archive.read_bytes()).hexdigest()).start()

    def test_official_pin_and_destination(self):
        self.assertEqual(installer.VERSION, "2.67.1")
        self.assertEqual(installer.ARCHIVE_BYTES, 28_814_751)
        self.assertEqual(installer.ARCHIVE_SHA256,
                         "7326f45a3354b6e44d948e4c6500ea9813247268887403ddfe9691ac2033f80e")
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}), \
                patch.object(installer, "install") as install:
            self.assertEqual(installer.main(), 0)
        install.assert_called_once_with(self.root / "birds-cli/node_modules/.bin/supabase")

    def test_download_has_https_size_time_and_retry_bounds(self):
        with patch.object(subprocess, "run") as run:
            installer.download_archive(self.archive)
        args, kwargs = run.call_args
        command = args[0]
        self.assertEqual(command[:2], ["curl", "--disable"])
        self.assertEqual(command[-1],
                         "https://api.github.com/repos/supabase/cli/releases/assets/328122062")
        for option, expected in {
            "--proto": "=https", "--proto-redir": "=https", "--max-redirs": "3",
            "--connect-timeout": "10", "--max-time": "60", "--retry": "2",
            "--retry-delay": "2", "--retry-max-time": "180",
            "--max-filesize": "28814751", "--output": str(self.archive),
        }.items():
            self.assertEqual(command[command.index(option) + 1], expected)
        self.assertIn("--fail", command)
        self.assertIn("Accept: application/octet-stream", command)
        for forbidden in ("--insecure", "--retry-all-errors", "--location-trusted"):
            self.assertNotIn(forbidden, command)
        self.assertEqual(kwargs, dict(check=True, timeout=200))

    def test_size_and_html_refused_before_parsing_or_execution(self):
        for body in (b"", b"<html>Bad Gateway</html>", b"{}", b"\x1f\x8btruncated"):
            self.archive.write_bytes(body)
            with self.subTest(body=body), patch.object(tarfile, "open") as parse, \
                    patch.object(subprocess, "run") as execute, self.assertRaises(ValueError):
                installer.extract_binary(self.archive, self.binary)
            parse.assert_not_called()
            execute.assert_not_called()
            self.assertFalse(self.binary.exists())

    def test_same_size_corruption_refused_before_parsing(self):
        self.fixture()
        data = bytearray(self.archive.read_bytes())
        data[-1] ^= 1
        self.archive.write_bytes(data)
        with patch.object(tarfile, "open") as parse, self.assertRaisesRegex(ValueError, "SHA256"):
            installer.extract_binary(self.archive, self.binary)
        parse.assert_not_called()

    def test_only_binary_extracted_without_archive_permissions(self):
        info = tarfile.TarInfo("supabase")
        info.mode = 0o7777
        self.fixture([("LICENSE", b"license"), ("README.md", b"readme"), (info, b"CLI")])
        installer.extract_binary(self.archive, self.binary)
        self.assertEqual(self.binary.read_bytes(), b"CLI")
        self.assertEqual({path.name for path in self.root.iterdir()}, {"asset.tar.gz", "supabase"})
        self.assertEqual(self.binary.stat().st_mode & 0o7000, 0)

    def test_paths_and_unexpected_members_refused(self):
        for name in ("../supabase", "/supabase", "bin/supabase", "./supabase", "unexpected"):
            with self.subTest(name=name):
                self.fixture([(name, b"bad")])
                with self.assertRaisesRegex(ValueError, "member"):
                    installer.extract_binary(self.archive, self.binary)
                self.assertFalse(self.binary.exists())

    def test_links_devices_directories_and_sparse_files_refused(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE,
                     tarfile.BLKTYPE, tarfile.FIFOTYPE, tarfile.DIRTYPE):
            info = tarfile.TarInfo("supabase")
            info.type = kind
            info.linkname = "../outside"
            with self.subTest(kind=kind):
                self.fixture([(info, b"")])
                with self.assertRaisesRegex(ValueError, "member"):
                    installer.extract_binary(self.archive, self.binary)
        self.fixture()
        with patch.object(tarfile.TarInfo, "issparse", return_value=True), \
                self.assertRaisesRegex(ValueError, "member"):
            installer.extract_binary(self.archive, self.binary)

    def test_missing_empty_and_duplicate_binary_refused(self):
        for members in ([('LICENSE', b"license")], [('supabase', b"")],
                        [('supabase', b"one"), ('supabase', b"two")]):
            with self.subTest(members=members):
                self.fixture(members)
                with self.assertRaises(ValueError):
                    installer.extract_binary(self.archive, self.binary)

    def test_unpacked_byte_limit_includes_ignored_members(self):
        self.fixture([("README.md", b"12345"), ("supabase", b"12345")])
        with patch.object(installer, "MAX_UNPACKED_BYTES", 9), \
                self.assertRaisesRegex(ValueError, "limit"):
            installer.extract_binary(self.archive, self.binary)
        self.assertFalse(self.binary.exists())

    def test_matching_pin_is_still_required_to_be_gzip_tar(self):
        self.archive.write_bytes(b"not an archive")
        with patch.object(installer, "ARCHIVE_BYTES", self.archive.stat().st_size), \
                patch.object(installer, "ARCHIVE_SHA256",
                             hashlib.sha256(self.archive.read_bytes()).hexdigest()), \
                self.assertRaises(tarfile.TarError):
            installer.extract_binary(self.archive, self.binary)

    def perform_install(self, version="2.67.1\n", download_error=None):
        target = self.root / "bin/supabase"
        def download(path):
            if download_error:
                raise download_error
            path.write_bytes(self.archive.read_bytes())
        with patch.object(installer.platform, "system", return_value="Linux"), \
                patch.object(installer.platform, "machine", return_value="x86_64"), \
                patch.object(installer, "download_archive", side_effect=download), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 0, version, "")) as execute:
            installer.install(target)
        return target, execute

    def test_verified_install_checks_version_then_publishes_atomically(self):
        self.fixture()
        target, execute = self.perform_install()
        self.assertEqual(target.read_bytes(), b"synthetic CLI")
        self.assertEqual(target.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(list(target.parent.iterdir()), [target])
        args, kwargs = execute.call_args
        self.assertEqual(args[0][1:], ["--version"])
        self.assertEqual(kwargs, dict(check=True, timeout=10, capture_output=True, text=True))

    def test_download_failure_and_timeout_never_extract_or_execute(self):
        for error in (subprocess.CalledProcessError(22, "curl"),
                      subprocess.TimeoutExpired("curl", 200)):
            with self.subTest(error=error), patch.object(installer, "extract_binary") as extract, \
                    self.assertRaises(subprocess.SubprocessError):
                self.perform_install(download_error=error)
            extract.assert_not_called()
            self.assertEqual(list((self.root / "bin").iterdir()), [])

    def test_corrupt_download_never_executes_or_publishes(self):
        self.fixture()
        target = self.root / "bin/supabase"
        data = bytearray(self.archive.read_bytes())
        data[-1] ^= 1
        with patch.object(installer.platform, "system", return_value="Linux"), \
                patch.object(installer.platform, "machine", return_value="x86_64"), \
                patch.object(installer, "download_archive", side_effect=lambda p: p.write_bytes(data)), \
                patch.object(subprocess, "run") as execute, \
                self.assertRaisesRegex(ValueError, "SHA256"):
            installer.install(target)
        execute.assert_not_called()
        self.assertEqual(list(target.parent.iterdir()), [])

    def test_bad_version_preserves_existing_install_and_cleans_temporary_files(self):
        self.fixture()
        target = self.root / "bin/supabase"
        target.parent.mkdir()
        target.write_bytes(b"previous CLI")
        with self.assertRaisesRegex(ValueError, "version"):
            self.perform_install(version="wrong version")
        self.assertEqual(target.read_bytes(), b"previous CLI")
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_other_platform_refused_before_download(self):
        for system, machine in (("Darwin", "x86_64"), ("Linux", "aarch64")):
            with self.subTest(system=system, machine=machine), \
                    patch.object(installer.platform, "system", return_value=system), \
                    patch.object(installer.platform, "machine", return_value=machine), \
                    patch.object(installer, "download_archive") as download, \
                    self.assertRaisesRegex(ValueError, "Linux amd64"):
                installer.install(self.binary)
            download.assert_not_called()


if __name__ == "__main__":
    unittest.main()

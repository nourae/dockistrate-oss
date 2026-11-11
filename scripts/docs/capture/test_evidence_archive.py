"""Evidence archive tests: original bytes, deterministic output and safe reads."""

import gzip
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

from .evidence_archive import pack_directory, read_archive, read_member, write_archive


class EvidenceArchiveTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="dockistrate-archive-check-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def malformed_archive(self, entries):
        path = self.root / "malformed.tar.gz"
        with gzip.open(path, "wb") as stream, tarfile.open(fileobj=stream, mode="w") as archive:
            for name, kind in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    member.size = 4
                    archive.addfile(member, io.BytesIO(b"test"))
                else:
                    member.linkname = "outside"
                    archive.addfile(member)
        return path

    def test_exact_pty_bytes_and_deterministic_archive(self):
        raw = b"\x1b[H\x1b[2JReview\r\n> 1) Run\r\n\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\x00"
        members = {"journey.pty.log": raw, "commands.jsonl": b'{"input":"withheld"}\n'}
        first, second = self.root / "first.tar.gz", self.root / "second.tar.gz"
        metadata = write_archive(first, members)
        other = write_archive(second, dict(reversed(list(members.items()))))
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(metadata, other)
        self.assertEqual(read_member(first, "journey.pty.log", expected_archive_sha256=metadata["sha256"],
                                     expected_member_sha256=metadata["members"]["journey.pty.log"]["sha256"]), raw)
        self.assertEqual(read_archive(first), members)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["first.tar.gz", "second.tar.gz"])

    def test_directory_metadata_does_not_change_archive(self):
        source = self.root / "source"
        source.mkdir()
        file = source / "event.jsonl"
        file.write_bytes(b"{\"kind\":\"menu\"}\r\n")
        first, second = self.root / "one.tar.gz", self.root / "two.tar.gz"
        pack_directory(source, first)
        file.chmod(0o600)
        os.utime(file, (123, 456))
        pack_directory(source, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_missing_and_hash_mismatched_members_are_rejected(self):
        path = self.root / "valid.tar.gz"
        write_archive(path, {"record.pty.log": b"original\r\n"})
        with self.assertRaisesRegex(ValueError, "Missing evidence member"):
            read_member(path, "missing.pty.log")
        with self.assertRaisesRegex(ValueError, "archive SHA-256 mismatch"):
            read_member(path, "record.pty.log", expected_archive_sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "member SHA-256 mismatch"):
            read_member(path, "record.pty.log", expected_member_sha256="0" * 64)

    def test_unsafe_paths_are_rejected_before_packing_or_reading(self):
        for name in ("../escape", "/absolute", "a/../escape", "a//b", "./same", "a\\b", "C:/absolute"):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    write_archive(self.root / "bad.tar.gz", {name: b"test"})
                path = self.malformed_archive([("safe", tarfile.REGTYPE), (name, tarfile.REGTYPE)])
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    read_member(path, "safe")

    def test_links_and_duplicate_members_are_rejected(self):
        for entries in ([('safe', tarfile.REGTYPE), ('link', tarfile.SYMTYPE)],
                        [('safe', tarfile.REGTYPE), ('link', tarfile.LNKTYPE)],
                        [('safe', tarfile.REGTYPE), ('safe', tarfile.REGTYPE)]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                read_member(self.malformed_archive(entries), "safe")
        source = self.root / "linked"
        source.mkdir()
        (source / "link").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            pack_directory(source, self.root / "linked.tar.gz")

    def test_compressed_size_does_not_bypass_read_limit(self):
        path = self.root / "large.tar.gz"
        write_archive(path, {"repeated.log": b"x" * 20000})
        self.assertLess(path.stat().st_size, 1000)
        with self.assertRaisesRegex(ValueError, "read limit"):
            read_member(path, "repeated.log", max_bytes=10000)

    def test_truncated_compression_trailer_is_rejected(self):
        path = self.root / "truncated.tar.gz"
        write_archive(path, {"record.pty.log": b"original\r\n"})
        path.write_bytes(path.read_bytes()[:-8])
        with self.assertRaisesRegex(ValueError, "Invalid evidence archive"):
            read_member(path, "record.pty.log")


if __name__ == "__main__":
    unittest.main()

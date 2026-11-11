"""Deterministic evidence archives with bounded, extraction-free member reads.

Callers must sanitize non-PTY evidence before packing. This module preserves
every supplied byte, including the original PTY's CRLF and ANSI sequences.
"""

import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import zlib


MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


def validate_member_name(name):
    if (not isinstance(name, str) or not name or "\x00" in name or "\\" in name or
            name.startswith("/") or re.match(r"^[A-Za-z]:", name) or
            any(part in ("", ".", "..") for part in name.split("/")) or
            PurePosixPath(name).as_posix() != name):
        raise ValueError("Unsafe evidence member name: " + repr(name))
    return name


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_archive(destination, members):
    """Pack a mapping of relative POSIX names to reviewed bytes atomically.

    Return ``{sha256, size, members: {name: {sha256, size}}}``. The gzip/tar
    timestamps, ownership, modes, names and order are independent of the host.
    """
    names = sorted(validate_member_name(name) for name in members)
    for name in names:
        if not isinstance(members[name], bytes):
            raise TypeError("Evidence members must contain bytes: " + name)
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError("Archive destination must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    metadata = {}
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix="." + destination.name + ".",
                                         dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0,
                               compresslevel=6) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for name in names:
                        data = members[name]
                        member = tarfile.TarInfo(name)
                        member.size = len(data)
                        member.mode = 0o644
                        member.mtime = member.uid = member.gid = 0
                        member.uname = member.gname = ""
                        archive.addfile(member, io.BytesIO(data))
                        metadata[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {"sha256": sha256_file(destination), "size": destination.stat().st_size,
            "members": metadata}


def pack_directory(source, destination):
    """Pack an already sanitized evidence directory, rejecting links/special files."""
    source, destination = Path(source), Path(destination)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Evidence source must be a real directory")
    if destination.resolve().is_relative_to(source.resolve()):
        raise ValueError("Archive destination must be outside the evidence directory")
    members = {}
    for path in source.rglob("*"):
        if path.is_symlink():
            raise ValueError("Evidence directory must not contain symlinks: " + str(path))
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("Evidence directory contains a special file: " + str(path))
        members[path.relative_to(source).as_posix()] = path.read_bytes()
    return write_archive(destination, members)


class _BoundedReader:
    def __init__(self, stream, limit):
        self.stream, self.remaining = stream, limit

    def read(self, size=-1):
        if size < 0 or size > self.remaining:
            raise ValueError("Evidence archive exceeds the uncompressed read limit")
        data = self.stream.read(size)
        self.remaining -= len(data)
        return data


def _read_members(path, requested, expected_archive_sha256, max_bytes):
    path = Path(path)
    results, seen = {}, set()
    try:
        with path.open("rb") as source:
            if max_bytes <= 0 or os.fstat(source.fileno()).st_size > max_bytes:
                raise ValueError("Evidence archive exceeds the compressed read limit")
            if expected_archive_sha256 is not None:
                digest = hashlib.sha256()
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
                if digest.hexdigest() != expected_archive_sha256:
                    raise ValueError("Evidence archive SHA-256 mismatch: " + str(path))
                source.seek(0)
            with gzip.GzipFile(fileobj=source, mode="rb") as compressed:
                bounded = _BoundedReader(compressed, max_bytes)
                with tarfile.open(fileobj=bounded, mode="r|", ignore_zeros=True) as archive:
                    for member in archive:
                        name = validate_member_name(member.name)
                        if name in seen:
                            raise ValueError("Duplicate evidence member: " + name)
                        seen.add(name)
                        if not member.isfile() or member.size < 0 or member.size > max_bytes:
                            raise ValueError("Evidence member is not a bounded regular file: " + name)
                        if requested is None or name in requested:
                            reader = archive.extractfile(member)
                            if reader is None:
                                raise ValueError("Unreadable evidence member: " + name)
                            data = reader.read(member.size + 1)
                            if len(data) != member.size:
                                raise ValueError("Truncated evidence member: " + name)
                            results[name] = data
    except (tarfile.TarError, EOFError, gzip.BadGzipFile, zlib.error) as error:
        raise ValueError("Invalid evidence archive: " + str(path)) from error
    if requested is not None and not requested.issubset(results):
        raise ValueError("Missing evidence member: " + ", ".join(sorted(requested - results.keys())))
    return results


def read_archive(path, *, expected_archive_sha256=None, max_bytes=MAX_ARCHIVE_BYTES):
    """Read and validate all members once for a caller's per-archive cache."""
    return _read_members(path, None, expected_archive_sha256, max_bytes)


def read_member(path, name, *, expected_archive_sha256=None,
                expected_member_sha256=None, max_bytes=MAX_ARCHIVE_BYTES):
    """Return one member's exact bytes without extracting anything to disk."""
    name = validate_member_name(name)
    data = _read_members(path, {name}, expected_archive_sha256, max_bytes)[name]
    if expected_member_sha256 is not None and hashlib.sha256(data).hexdigest() != expected_member_sha256:
        raise ValueError("Evidence member SHA-256 mismatch: " + name)
    return data

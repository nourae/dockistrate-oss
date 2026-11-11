"""BSD stat fixture with Darwin fdescfs path metadata and real stdin fstat."""

import os
import sys


def record(variable, message):
    path = os.environ.get(variable)
    if path:
        with open(path, "a") as handle:
            handle.write(message + "\n")


def unsupported(message):
    record("RESTORE_STAT_UNSUPPORTED", message)
    print(message, file=sys.stderr)
    sys.exit(97)


args = sys.argv[1:]
follow = False
if args and args[0] == "-L":
    follow = True
    args = args[1:]
if args and args[0] in ("-Lc", "-Lf"):
    follow = True
    args = ["-" + args[0][2:]] + args[1:]
if args and args[0] == "-c":
    sys.exit(1)  # BSD stat does not accept GNU's format option.
if len(args) < 2 or args[0] != "-f":
    unsupported("unsupported BSD stat invocation: " + repr(args))
format_string = args[1]
paths = args[2:]
if paths and paths[0] == "--":
    paths = paths[1:]
if not paths:
    paths = [None]  # BSD stat without a pathname calls fstat on stdin.

for path in paths:
    try:
        # The launcher duplicates original stdin before replacing Python's
        # standard stream: Python cannot initialize with a directory on fd 0.
        # fstat on that duplicate preserves the original object and offset.
        if path is None:
            metadata = os.fstat(int(os.environ.get("RESTORE_STAT_STDIN_FD", "0")))
        elif path.startswith("/dev/fd/") or path == "/dev/stdin":
            # Model the descriptor-path difference from the opened object,
            # not the host's own fdescfs metadata. The latter can already
            # differ from fstat and would make the simulation platform-specific.
            number = "0" if path == "/dev/stdin" else path[len("/dev/fd/"):]
            if not number or any(character not in "0123456789" for character in number):
                raise ValueError("invalid descriptor path")
            descriptor = int(number)
            if descriptor == 0:
                descriptor = int(os.environ.get("RESTORE_STAT_STDIN_FD", "0"))
            metadata = os.fstat(descriptor)
        else:
            metadata = os.stat(path, follow_symlinks=follow)
    except (OSError, ValueError, OverflowError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    device, inode = metadata.st_dev, metadata.st_ino
    kind = "path"
    if path is None:
        kind = "stdin"
    elif path.startswith("/dev/fd/") or path == "/dev/stdin":
        # Simulate a different device while preserving the opened file's inode.
        # Descriptor-path metadata is not
        # a portable replacement for fstat on the already-open file itself.
        kind = "fdescfs"
        device = device + 1
    record("RESTORE_STAT_TRACE", "%s\t%s\t%s" % (kind, format_string, path or ""))
    mode = format(metadata.st_mode, "o")
    low_mode = format(metadata.st_mode & 0o777, "o")
    mtime = metadata.st_mtime_ns // 1000000000
    ctime = metadata.st_ctime_ns // 1000000000
    identity = "%s:%s:%s:%s:%s" % (device, inode, metadata.st_size, mtime, ctime)
    formats = {
        "%p": mode,
        "%Lp": low_mode,
        "%l": str(metadata.st_nlink),
        "%d:%i": "%s:%s" % (device, inode),
        "%m": str(mtime),
        "%z": str(metadata.st_size),
        "%d:%i:%z:%m:%c": identity,
        "%d:%i:%z:%m:%c:%p": identity + ":" + mode,
        "%u %g %Lp": "%s %s %s" % (metadata.st_uid, metadata.st_gid, low_mode),
        "%d %i %u %g %Lp %l": "%s %s %s %s %s %s" % (
            device, inode, metadata.st_uid, metadata.st_gid, low_mode, metadata.st_nlink),
        "%d %i %u %g %p %l": "%s %s %s %s %s %s" % (
            device, inode, metadata.st_uid, metadata.st_gid, mode, metadata.st_nlink),
        "%d %i %u %g %p %l|%z|%.9Fm|%.9Fc": "%s %s %s %s %s %s|%s|%s.%09d|%s.%09d" % (
            device, inode, metadata.st_uid, metadata.st_gid, mode, metadata.st_nlink,
            metadata.st_size, mtime, metadata.st_mtime_ns % 1000000000,
            ctime, metadata.st_ctime_ns % 1000000000),
        "%p|%.9Fm": "%s|%s.%09d" % (mode, mtime, metadata.st_mtime_ns % 1000000000),
    }
    if format_string not in formats:
        unsupported("unsupported BSD stat format: " + format_string)
    print(formats[format_string])

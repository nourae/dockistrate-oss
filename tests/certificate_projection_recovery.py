"""Reject snapshot recovery outside the captured manifest's exact authority."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def inventory(root):
    result = {}
    for path in [root] + sorted(root.rglob('*')):
        info = path.lstat()
        item = [info.st_dev, info.st_ino, info.st_uid, info.st_gid,
                stat.S_IMODE(info.st_mode), info.st_mtime_ns, info.st_ctime_ns]
        if path.is_symlink():
            item += ['link', os.readlink(path)]
        elif path.is_file():
            item += ['file', hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            item += ['directory']
        result[str(path.relative_to(root))] = item
    return result


def main():
    bash, helper, root_text, generation, sentinel_text, case = sys.argv[1:]
    root, sentinel = Path(root_text), Path(sentinel_text)
    mounts = 'mount:%s:false\ncomplete\n' % os.fsencode(generation).hex()
    captured = subprocess.run([bash, helper, 'capture', root_text, '-'],
                              input=mounts, text=True, capture_output=True, check=True)
    token = captured.stdout.rstrip('\n').split(':')
    assert token[0] == 'dockistrate-projection-token-v2' and len(token) == 5
    manifest = bytes.fromhex(token[4]).decode('ascii').splitlines()
    key_index = next(index for index, line in enumerate(manifest) if ':server-key:' in line)
    key_entry = manifest[key_index].split(':')
    key = Path(generation) / os.fsdecode(bytes.fromhex(key_entry[0]))
    if case == 'bytes':
        key.write_bytes(b'changed snapshot key bytes\n')
        key.chmod(0o600)
        if os.geteuid() == 0:
            os.chown(key, 0, 0)
    elif case == 'token':
        key_entry[2] = '600' if key_entry[2] != '600' else '640'
        manifest[key_index] = ':'.join(key_entry)
        token[4] = ('\n'.join(manifest)+'\n').encode('ascii').hex()
    elif case == 'symlink':
        key.unlink()
        key.symlink_to(sentinel)
    else:
        raise AssertionError('Unknown recovery test case')
    before = inventory(root)
    foreign_before = inventory(sentinel.parent)
    recovered = subprocess.run([bash, helper, 'recover', root_text, '-'],
                               input=':'.join(token), text=True, capture_output=True)
    assert recovered.returncode != 0, 'Unsafe snapshot recovery unexpectedly succeeded'
    assert 'Certificate projection:' in recovered.stderr, recovered.stderr
    assert inventory(root) == before, 'Rejected recovery modified snapshot state or published a generation'
    assert inventory(sentinel.parent) == foreign_before, 'Rejected recovery modified foreign sentinel'
    print('Snapshot recovery rejection passed: ' + case)


if __name__ == '__main__':
    main()

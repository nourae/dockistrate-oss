"""Model BSD mkdir group inheritance around native shell filesystem operations.

The stat/chown wrappers alter only the reported directory group until production
normalizes it. Real files, descriptors, contents, identities and metadata remain
native; no runtime Python code is imported by this developer-only fixture.
"""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


WRAPPER = r'''#!/usr/bin/env python3
import fcntl,json,os,stat,subprocess,sys
settings=json.loads(os.environ['PROJECTION_GROUP_FIXTURE'])
command=sys.argv[1]
args=sys.argv[2:]
result=subprocess.run([settings[command]]+args,stdin=9,stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=False)
sys.stderr.buffer.write(result.stderr)
if result.returncode:
    sys.stdout.buffer.write(result.stdout); sys.exit(result.returncode)
path=args[-1] if args else '.'
stdin_stat=command=='stat' and path.startswith('%')
try:
    info=os.fstat(9) if stdin_stat else os.stat(path)
except OSError:
    sys.stdout.buffer.write(result.stdout); sys.exit(0)
if not stat.S_ISDIR(info.st_mode):
    sys.stdout.buffer.write(result.stdout); sys.exit(0)
identity='%s:%s'%(info.st_dev,info.st_ino)
if stdin_stat:
    cwd_info=os.stat('.')
    physical=os.getcwd() if (cwd_info.st_dev,cwd_info.st_ino)==(info.st_dev,info.st_ino) else ''
else:
    physical=os.path.realpath(path)
with open(settings['state'],'a+') as handle:
    fcntl.flock(handle,fcntl.LOCK_EX)
    handle.seek(0)
    text=handle.read()
    state=json.loads(text) if text else {'created':{},'normalized':[]}
    owned=physical.startswith(settings['root']+'/.stage-')
    nested=os.path.basename(physical) in ('custom','live','server.example.test')
    if owned and (not settings['nested_only'] or nested) and identity not in state['created']:
        state['created'][identity]={'path':physical,'group':os.getegid()+10000}
    if command=='chown' and identity in state['created']:
        state['created'][identity]['group']=int(args[0].split(':')[1])
        state['normalized'].append(identity)
    if command=='stat' and identity in state['created']:
        header, separator, remainder=result.stdout.decode().partition('|')
        fields=header.split()
        if len(fields)==6 and all(field.isalnum() for field in fields):
            fields[3]=str(state['created'][identity]['group'])
            result.stdout=(' '.join(fields)+separator+remainder if separator else ' '.join(fields)+'\n').encode()
    handle.seek(0); handle.truncate(); json.dump(state,handle)
sys.stdout.buffer.write(result.stdout)
'''

LAUNCHER = r'''#!/usr/bin/env bash
# BSD stat can inspect a directory on stdin; Python cannot start with it there.
# Keep the genuine descriptor for native stat and the fixture's own fstat.
exec "$PROJECTION_GROUP_PYTHON" "$PROJECTION_GROUP_WRAPPER" "${0##*/}" "$@" 9<&0 </dev/null
'''


def check_stdin_wrapper(directory, settings, env):
    """Exercise the BSD stdin boundary even when this test runs on GNU stat."""
    native = settings['stat']
    style = subprocess.run([native, '-c', '%d:%i', str(directory)], capture_output=True)
    args = ['-c', '%d:%i', '-'] if style.returncode == 0 else ['-f', '%d:%i']
    marker = directory / 'stdin-probe'
    marker.write_bytes(b'unchanged descriptor offset\n')
    for path in (directory, marker):
        descriptor = os.open(path, os.O_RDONLY)
        try:
            regular = stat.S_ISREG(os.fstat(descriptor).st_mode)
            if regular:
                os.read(descriptor, 1)
                offset = os.lseek(descriptor, 0, os.SEEK_CUR)
            expected = subprocess.run([native, *args], stdin=descriptor, capture_output=True)
            observed = subprocess.run([str(directory / 'stat'), *args], stdin=descriptor,
                                      capture_output=True, env=env)
            assert expected.returncode == observed.returncode == 0, observed.stderr.decode(errors='replace')
            assert observed.stdout == expected.stdout, 'Stat wrapper changed the pinned stdin identity'
            if regular:
                assert os.lseek(descriptor, 0, os.SEEK_CUR) == offset, 'Stat wrapper consumed stdin'
        finally:
            os.close(descriptor)


def main():
    bash, helper, certificates, destination, shape = sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix='projection-group-model-') as temporary:
        directory = Path(temporary)
        settings = dict(stat=shutil.which('stat'), chown=shutil.which('chown'),
                        state=str(directory/'state.json'), root=os.path.realpath(destination),
                        nested_only=shape == 'nested')
        helper_wrapper = directory / 'wrapper.py'
        helper_wrapper.write_text(WRAPPER)
        for name in ('stat','chown'):
            wrapper = directory/name
            wrapper.write_text(LAUNCHER)
            wrapper.chmod(0o755)
        env = dict(os.environ, PATH=str(directory)+os.pathsep+os.environ['PATH'],
                   PROJECTION_GROUP_FIXTURE=json.dumps(settings),
                   PROJECTION_GROUP_PYTHON=sys.executable, PROJECTION_GROUP_WRAPPER=str(helper_wrapper))
        check_stdin_wrapper(directory, settings, env)
        fields = []
        if shape != 'empty':
            relative='custom/live/server.example.test/'
            for role,name in [('server-cert','fullchain.pem'),('server-key','privkey.pem')]:
                fields += [role, os.path.join(certificates,relative,name), relative+name]
        payload=b'\0'.join(os.fsencode(value) for value in fields+['complete'])+b'\0'
        def run(command, target, data=b''):
            result=subprocess.run([bash,helper,command,certificates if command=='build' else destination,target],
                                  input=data,capture_output=True,env=env)
            assert result.returncode==0, result.stderr.decode(errors='replace')
            return os.fsdecode(result.stdout)
        selected=run('build',destination,payload)
        run('verify',selected)
        assert run('build',destination,payload)==selected, 'Stable projection was not reused'
        state=json.loads(Path(settings['state']).read_text())
        assert state['created'], 'Directory group inheritance was not exercised'
        assert set(state['created']) <= set(state['normalized']), 'An inherited directory group was not normalized'
        assert len(list(Path(destination).glob('gen-*')))==1, 'Stable preparation published an extra generation'
        if shape != 'empty':
            nested=[item for item in state['created'].values()
                    if os.path.basename(item['path']) in ('custom','live','server.example.test')]
            assert len(nested)>=3, 'Nested inherited groups were not exercised'
            source=os.stat(os.path.join(certificates,'custom/live/server.example.test/privkey.pem'))
            copied=os.stat(os.path.join(selected,'custom/live/server.example.test/privkey.pem'))
            assert (copied.st_uid,copied.st_gid,stat.S_IMODE(copied.st_mode)) == (source.st_uid,source.st_gid,stat.S_IMODE(source.st_mode)), 'Directory repair changed mapped server key metadata'
        print('Inherited directory group checks passed: '+shape)


if __name__=='__main__':
    main()

#!/usr/bin/env python3
"""Restore verified, archived native session material into a new owner home."""
import hashlib
import ctypes
import fcntl
import json
import os
import re
import stat
import sys
import uuid
from pathlib import Path

from harness_session_archive import ArchiveError, archive, verify

UUID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
CHUNK = 1024 * 1024
METADATA_BYTES = 65536


class RestoreError(RuntimeError):
    pass


def _stamp(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _directory(path, parent=None):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(fd); raise RestoreError('unsafe restore directory')
    return fd


def _file(parent, name, write=False):
    fd = os.open(name, (os.O_RDWR if write else os.O_RDONLY) | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(fd); raise RestoreError('unsafe restore metadata')
    return fd


def _metadata(parent, name):
    fd = _file(parent, name)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if before.st_size > METADATA_BYTES: raise RestoreError('restore metadata exceeds limit')
        data = stream.read(METADATA_BYTES + 1)
        if len(data) > METADATA_BYTES or _stamp(os.fstat(stream.fileno())) != _stamp(before):
            raise RestoreError('restore metadata changed while reading')
    return data.decode(), _stamp(before)


def _relative_file(parent, relative, create=False):
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(part in ('.','..') for part in parts):
        raise RestoreError('invalid restore relative path')
    current = os.dup(parent)
    try:
        for part in parts[:-1]:
            if create:
                try: os.mkdir(part, 0o700, dir_fd=current)
                except FileExistsError: pass
            child = _directory(part, current); os.close(current); current = child
        if create:
            return os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=current)
        return _file(current, parts[-1])
    finally:
        os.close(current)


class _Target:
    def __init__(self, target, state, source, owner):
        self.fds = []
        if not isinstance(owner,str) or not UUID.fullmatch(owner): raise RestoreError('invalid target owner')
        if any('..' in Path(path).parts for path in (target,state,source)):
            raise RestoreError('restore paths cannot contain parent traversal')
        self.owner = owner; self.raw_state = Path(os.path.abspath(state)); self.state = self.raw_state.resolve(strict=True)
        # Canonicalize the base once for OS aliases such as /var. Never resolve
        # worktrees/<owner> to define what that owner is allowed to name.
        self.source = Path(source).resolve(strict=True); self.path = self.state/'worktrees'/owner
        if Path(os.path.abspath(target)) not in (self.path,self.raw_state/'worktrees'/owner):
            raise RestoreError('invalid target owner binding')
        try:
            self.state_fd = self.keep(_directory(self.raw_state))
            self.raw_source = Path(os.path.abspath(source)); self.source_fd = self.keep(_directory(source))
            self.worktrees = self.keep(_directory('worktrees',self.state_fd))
            self.sessions = self.keep(_directory('sessions',self.state_fd))
            self.target = self.keep(_directory(owner,self.worktrees))
            self.record = self.keep(_directory(owner,self.sessions))
            self.snapshots = {name:_metadata(self.record,name) for name in ('session-root','source-root','journal')}
            if self.snapshots['session-root'][0].strip() not in (str(self.path),str(self.raw_state/'worktrees'/owner)):
                raise RestoreError('invalid target session-root')
            if self.snapshots['source-root'][0].strip() not in (str(self.source),str(Path(os.path.abspath(source)))):
                raise RestoreError('invalid target source-root')
            if not self.snapshots['journal'][0].startswith('state=OPEN\n'):
                raise RestoreError('target is not a fresh owned worktree')
            self.identities = {fd:(os.fstat(fd).st_dev,os.fstat(fd).st_ino) for fd in self.fds}
            self.assert_current()
        except BaseException:
            self.close(); raise

    def keep(self, fd):
        self.fds.append(fd); return fd

    def assert_current(self):
        for path,parent,bound in ((self.raw_state,None,self.state_fd),(self.raw_source,None,self.source_fd),('worktrees',self.state_fd,self.worktrees),('sessions',self.state_fd,self.sessions),(self.owner,self.worktrees,self.target),(self.owner,self.sessions,self.record)):
            current = _directory(path,parent)
            try:
                info = os.fstat(current)
                if (info.st_dev,info.st_ino) != self.identities[bound]: raise RestoreError('restore directory binding changed')
            finally: os.close(current)
        if any(_metadata(self.record,name) != expected for name,expected in self.snapshots.items()):
            raise RestoreError('restore target metadata changed')

    def close(self):
        for fd in reversed(self.fds): os.close(fd)
        self.fds = []


def _native_id(parent, relative):
    with os.fdopen(_relative_file(parent,relative), 'rb') as stream:
        for line in stream.read(64 * 1024).splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            payload = event.get('payload') if isinstance(event, dict) else None
            value = payload.get('id') if isinstance(payload, dict) else None
            if event.get('type') == 'session_meta' and isinstance(value, str) and UUID.fullmatch(value):
                return value
    return None


def _copy_verified(source, destination, expected, *, archive_fd, staging_fd):
    digest, copied = hashlib.sha256(), 0
    source_fd = _relative_file(archive_fd,expected['path'])
    with os.fdopen(source_fd, 'rb', buffering=0) as incoming, os.fdopen(_relative_file(staging_fd,str(Path(expected['path']).relative_to('codex')),True),'wb',buffering=0) as outgoing:
        before = os.fstat(incoming.fileno())
        if before.st_size != expected['bytes']: raise RestoreError('archive size changed')
        while True:
            chunk = incoming.read(CHUNK)
            if not chunk:
                break
            copied += len(chunk)
            if copied > expected['bytes']: raise RestoreError('archive grew during restore')
            outgoing.write(chunk); digest.update(chunk)
        outgoing.flush(); os.fsync(outgoing.fileno())
        if _stamp(os.fstat(incoming.fileno())) != _stamp(before): raise RestoreError('archive changed during restore')
    if copied != expected['bytes'] or digest.hexdigest() != expected['sha256']:
        raise RestoreError('archive content no longer matches manifest')


def _fsync(fd):
    for name in os.listdir(fd):
        info = os.stat(name,dir_fd=fd,follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child = _directory(name,fd)
            try: _fsync(child)
            finally: os.close(child)
    os.fsync(fd)


def _write_import(record, owner, source, old, native):
    payload = {'schema': 1, 'session_id': owner, 'source_root': str(source.resolve()),
               'imports': [{'runtime': 'codex', 'native_id': native, 'source_owner': old}]}
    name = 'restored-native-sessions'; temp = '.restored-native-'+uuid.uuid4().hex
    if name in os.listdir(record): raise RestoreError('target import ledger already exists')
    fd = os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=record)
    published = False; identity = None
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write((json.dumps(payload,sort_keys=True,separators=(',',':'))+'\n').encode());stream.flush();os.fsync(stream.fileno())
            info = os.fstat(stream.fileno())
        identity = info.st_dev,info.st_ino
        os.link(temp,name,src_dir_fd=record,dst_dir_fd=record,follow_symlinks=False);published=True
        os.unlink(temp,dir_fd=record)
        os.fsync(record)
        return identity
    except BaseException:
        if published:_remove_import(record,identity)
        try: os.unlink(temp,dir_fd=record)
        except OSError: pass
        raise


def _archive_closed_live(state, source, owner):
    record, root = state / 'sessions' / owner, state / 'worktrees' / owner
    fds = []
    try:
        state_fd = _directory(state); fds.append(state_fd)
        sessions = _directory('sessions',state_fd); fds.append(sessions)
        worktrees = _directory('worktrees',state_fd); fds.append(worktrees)
        record_fd = _directory(owner,sessions); fds.append(record_fd)
        root_fd = _directory(owner,worktrees); fds.append(root_fd)
        # POSIX locks can disappear when any descriptor for their inode closes.
        # Open the lease inode exactly once and retain it through the archive.
        lock = _file(record_fd,'runtime.lock',True); fds.append(lock)
        fcntl.lockf(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        before = {name:_metadata(record_fd,name) for name in ('source-root','session-root','journal')}
        if before['source-root'][0].strip() != str(source.resolve()):
            raise RestoreError('live source binding is invalid')
        if before['session-root'][0].strip() != str(root):
            raise RestoreError('live root binding is invalid')
        state_name = before['journal'][0].splitlines()[0]
        if state_name not in ('state=CLOSED','state=DELIVERED','state=DISCARDED') or any(name.startswith('resume-hold-') and name.endswith('.json') for name in os.listdir(record_fd)):
            raise RestoreError('live session is not safely terminal')
        archive(root=root, state=state, owner_id=owner, source_root=source)
        if any(_metadata(record_fd,name) != expected for name,expected in before.items()):
            raise RestoreError('live session metadata changed during archive')
        for name,parent,bound in ((state,None,state_fd),('worktrees',state_fd,worktrees),('sessions',state_fd,sessions),(owner,worktrees,root_fd),(owner,sessions,record_fd)):
            current = _directory(name,parent)
            try:
                left,right = os.fstat(current),os.fstat(bound)
                if (left.st_dev,left.st_ino)!=(right.st_dev,right.st_ino):raise RestoreError('live session binding changed')
            finally:os.close(current)
    except (ArchiveError,OSError,ValueError,IndexError,UnicodeError) as exc:
        raise RestoreError('live archive source is unavailable') from exc
    finally:
        for fd in reversed(fds): os.close(fd)


def _remove_tree(parent, name, identity):
    try:
        fd = _directory(name,parent)
    except OSError: return
    try:
        info = os.fstat(fd)
        if (info.st_dev,info.st_ino)!=identity:return
        for entry in os.listdir(fd):
            child = os.stat(entry,dir_fd=fd,follow_symlinks=False)
            if stat.S_ISDIR(child.st_mode):_remove_tree(fd,entry,(child.st_dev,child.st_ino))
            else:os.unlink(entry,dir_fd=fd)
    finally:os.close(fd)
    os.rmdir(name,dir_fd=parent)


def _remove_import(record, identity):
    try:
        info = os.stat('restored-native-sessions',dir_fd=record,follow_symlinks=False)
        if (info.st_dev,info.st_ino)==identity:os.unlink('restored-native-sessions',dir_fd=record);os.fsync(record)
    except OSError:pass


def _assert_directory(parent, name, identity):
    fd = _directory(name,parent)
    try:
        info = os.fstat(fd)
        if (info.st_dev,info.st_ino)!=identity:raise RestoreError('restore publication directory changed')
    finally:os.close(fd)


def _publish(staging, harness):
    # macOS's SDK declares renameatx_np(..., RENAME_EXCL=4). Linux exposes
    # renameat2(..., RENAME_NOREPLACE=1). Both reject an existing destination
    # atomically, including an empty directory installed after our last check.
    library = ctypes.CDLL(None,use_errno=True)
    name, flags = ('renameatx_np',4) if sys.platform=='darwin' else ('renameat2',1)
    operation = getattr(library,name,None)
    if operation is None:raise RestoreError('exclusive restore publication is unavailable')
    operation.argtypes = [ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
    operation.restype = ctypes.c_int
    if operation(staging,b'codex',harness,b'codex',flags)!=0:
        error=ctypes.get_errno();raise OSError(error,os.strerror(error))


def rehydrate(*, session, target_root: Path, state: Path, source_root: Path, owner_id: str) -> dict:
    target, state, source = Path(target_root), Path(state), Path(source_root)
    requested_target = target
    if not isinstance(session,dict) or session.get('runtime') != 'codex':
        raise RestoreError('only Codex sessions can be rehydrated')
    old, native = session.get('launcher_session_id'), session.get('native_id')
    if not isinstance(old, str) or not UUID.fullmatch(old) or not isinstance(native, str) or not UUID.fullmatch(native):
        raise RestoreError('session identity is invalid')
    binding = None; fds = []; staging_name = None; staging_identity = None; ledger_identity = None; published = False; codex_identity = None
    try:
        binding = _Target(target,state,source,owner_id); target,state,source = binding.path,binding.state,binding.source
        if old.lower()==owner_id.lower() or type(session.get('archived')) is not bool or session.get('source_root') != str(source):
            raise RestoreError('invalid restore source binding')
        if '.harness' in os.listdir(binding.target):
            harness_fd = _directory('.harness',binding.target); fds.append(harness_fd)
            if 'codex' in os.listdir(harness_fd):raise RestoreError('target native home already exists')
        else:
            os.mkdir('.harness',0o700,dir_fd=binding.target); harness_fd = _directory('.harness',binding.target);fds.append(harness_fd)
        harness_identity = os.fstat(harness_fd).st_dev,os.fstat(harness_fd).st_ino
        if not session['archived']:_archive_closed_live(state,source,old)
        archive_path = state/'archives'/old
        manifest = verify(archive=archive_path,owner_id=old,source_root=source)
        archives_fd = _directory('archives',binding.state_fd);fds.append(archives_fd)
        archive_fd = _directory(old,archives_fd);fds.append(archive_fd)
        selected = [entry for entry in manifest['files'] if entry['path'].endswith('.jsonl') and native in Path(entry['path']).name]
        if len(selected)!=1 or _native_id(archive_fd,selected[0]['path'])!=native:raise RestoreError('invalid native transcript binding')
        staging_name = '.restore-'+uuid.uuid4().hex;os.mkdir(staging_name,0o700,dir_fd=harness_fd)
        staging_fd = _directory(staging_name,harness_fd);fds.append(staging_fd)
        staging_identity = os.fstat(staging_fd).st_dev,os.fstat(staging_fd).st_ino
        os.mkdir('codex',0o700,dir_fd=staging_fd);codex_fd = _directory('codex',staging_fd);fds.append(codex_fd)
        codex_identity = os.fstat(codex_fd).st_dev,os.fstat(codex_fd).st_ino
        entry = selected[0]
        _copy_verified(archive_path/entry['path'],target/'.harness'/staging_name/'codex'/Path(entry['path']).relative_to('codex'),entry,archive_fd=archive_fd,staging_fd=codex_fd)
        _fsync(codex_fd);binding.assert_current()
        check = _directory('.harness',binding.target)
        try:
            info = os.fstat(check)
            if (info.st_dev,info.st_ino)!=harness_identity or 'codex' in os.listdir(check):raise RestoreError('restore home binding changed')
        finally:os.close(check)
        ledger_identity = _write_import(binding.record,owner_id,source,old,native)
        binding.assert_current();_assert_directory(binding.target,'.harness',harness_identity)
        _publish(staging_fd,harness_fd);published=True
        os.fsync(harness_fd);binding.assert_current()
        _assert_directory(binding.target,'.harness',harness_identity);_assert_directory(harness_fd,'codex',codex_identity)
        return {'native_id':native,'native_home':str(requested_target/'.harness/codex'),'owner_id':owner_id,
                'transcript_path':str(requested_target/'.harness'/entry['path']),'grant_provenance':manifest['grant_provenance']}
    except (ArchiveError,OSError,ValueError,TypeError,UnicodeError) as exc:
        raise RestoreError('restore source or target is unavailable') from exc
    finally:
        failed = sys.exc_info()[0] is not None
        try:
            if published and failed:_remove_tree(harness_fd,'codex',codex_identity)
            if ledger_identity is not None and failed:_remove_import(binding.record,ledger_identity)
            if staging_name is not None:_remove_tree(harness_fd,staging_name,staging_identity)
        except (OSError,RestoreError):
            if not failed:raise
        finally:
            for fd in reversed(fds):os.close(fd)
            if binding is not None:binding.close()

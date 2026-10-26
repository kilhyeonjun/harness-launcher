#!/usr/bin/env python3
"""Explicit, inventory-bound custody of terminal work; GC never creates it."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_session_work_proof as work

LIMIT = 128 * 1024 * 1024
TOTAL_LIMIT = 512 * 1024 * 1024
SCHEMA = 'terminal-work-recovery/v1'
NODE_LIMIT = 100000


def fail(message):
    raise work.WorkError(message)


def checksum(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def identity(value):
    return checksum(encoded(value))


def safe_path(value):
    if not isinstance(value, str) or not value or value.startswith('/') or any(
            part in ('', '.', '..') for part in value.split('/')) or '\x00' in value:
        fail('unsafe recovery path')
    return value


def read_file(path, private=False):
    path=Path(path);before=path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
            or before.st_size > LIMIT or (private and (
                stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1))):
        fail('unsafe recovery file')
    fd=os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as handle:
        if work.stamp(os.fstat(handle.fileno())) != work.stamp(before):fail('recovery input changed')
        raw=handle.read(LIMIT+1)
        if len(raw) != before.st_size or work.stamp(os.fstat(handle.fileno())) != work.stamp(before):
            fail('recovery input changed')
    if work.stamp(path.lstat()) != work.stamp(before):fail('recovery path changed')
    return raw


def private_dir(path):
    info=Path(path).lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):fail('unsafe recovery directory')
    return info


def put(path, raw):
    fd=os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(raw);handle.flush();os.fsync(handle.fileno())


def sync_dir(path):
    fd=os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)


def work_inventory(root, capture=None):
    result={};directories={};total=0;device=root.lstat().st_dev
    def walk_error(error):raise work.WorkError('recovery inventory inaccessible') from error
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        directory=Path(directory)
        if directory.lstat().st_dev != device:fail('recovery inventory crosses mount')
        for name in list(dirs):
            path=directory/name;relative=str(path.relative_to(root))
            if work.excluded(relative):dirs.remove(name);continue
            if path.is_symlink():dirs.remove(name);files.append(name)
            else:
                info=path.lstat()
                if info.st_mode & 0o7000:fail('unsupported recovery directory mode')
                directories[safe_path(relative)]=stat.S_IMODE(info.st_mode)
                if len(result)+len(directories)>NODE_LIMIT:fail('recovery inventory limit')
        for name in files:
            path=directory/name;relative=str(path.relative_to(root))
            if work.excluded(relative):continue
            safe_path(relative);before=path.lstat()
            if before.st_uid != os.getuid():fail('foreign recovery input')
            if stat.S_ISLNK(before.st_mode):
                raw=os.fsencode(os.readlink(path));kind='symlink'
            else:
                raw=read_file(path);kind='file'
                if before.st_mode & 0o7000:fail('unsupported recovery file mode')
            if work.stamp(path.lstat()) != work.stamp(before):fail('recovery work changed')
            total+=len(raw)
            if total>TOTAL_LIMIT or len(result)+len(directories)>=NODE_LIMIT:fail('recovery inventory limit')
            sha=checksum(raw)
            result[relative]={'kind':kind,'mode':stat.S_IMODE(before.st_mode),'bytes':len(raw),'sha256':sha}
            if capture is not None:capture[sha]=raw
    return {'files':result,'directories':directories}


def index_inventory(root, capture=None):
    index=root/'.git/index';raw=read_file(index);entries=[];oids=set()
    for entry in work.git(root,'ls-files','--stage','-z').split(b'\0'):
        if not entry:continue
        fields,name=entry.split(b'\t',1);mode,oid,stage=fields.decode().split()
        path=safe_path(os.fsdecode(name))
        if mode not in ('100644','100755','120000') or not work.OID.fullmatch(oid) or stage!='0':
            fail('unsupported recovery index entry')
        entries.append({'path':path,'mode':mode,'oid':oid,'stage':stage});oids.add(oid)
    objects={};data=work.git(root,'cat-file','--batch',input_data=('\n'.join(sorted(oids))+'\n').encode()) if oids else b''
    position=0
    for oid in sorted(oids):
        end=data.find(b'\n',position)
        if end<0:fail('missing recovery index object')
        header=data[position:end].split()
        if len(header)!=3 or header[0].decode()!=oid or header[1]!=b'blob':fail('invalid recovery index object')
        size=int(header[2]);position=end+1
        if size>LIMIT:fail('recovery index object limit')
        blob=data[position:position+size];position+=size
        algorithm='sha1' if len(oid)==40 else 'sha256'
        if (len(blob)!=size or data[position:position+1]!=b'\n'
                or hashlib.new(algorithm,b'blob '+str(size).encode()+b'\0'+blob).hexdigest()!=oid):
            fail('recovery index object mismatch')
        position+=1;sha=checksum(blob);objects[oid]={'sha256':sha,'bytes':size}
        if capture is not None:capture[sha]=blob
    if position!=len(data) or read_file(index)!=raw:fail('recovery index changed')
    sha=checksum(raw)
    if capture is not None:capture[sha]=raw
    return {'raw_sha256':sha,'raw_bytes':len(raw),'entries':entries,'objects':objects}


def inventory(state, owner, retained_root=None, capture=None):
    state=Path(state).resolve(strict=True)
    if not work.UUID.fullmatch(owner):fail('invalid recovery owner')
    record=state/'sessions'/owner;recorded=Path(work.scalar(record/'session-root'))
    if recorded!=state/'worktrees'/owner:fail('recovery owner root mismatch')
    root=Path(retained_root) if retained_root else recorded
    if root!=recorded and (root.parent!=recorded.parent or not re.fullmatch(
            r'\.(?:archiving|retired)-'+re.escape(owner)+r'-[0-9]+',root.name)):
        fail('unexpected recovery retained root')
    info=root.lstat()
    if not stat.S_ISDIR(info.st_mode) or not work.root_identity_matches(work.scalar(record/'root-inode'),info,root):
        fail('recovery root incarnation mismatch')
    if (root/'.git').is_symlink() or not (root/'.git').is_dir():fail('unsafe recovery git directory')
    if os.path.lexists(record/'headless'):fail('headless recovery is not characterized')
    source=work.scalar(record/'source-root');base=work.scalar(record/'base-sha')
    if not work.OID.fullmatch(base) or work.scalar(root/'.git/HEAD')!=base:fail('recovery base mismatch')
    journal=dict(line.split('=',1) for line in work.metadata(record/'journal').decode().splitlines())
    if journal.get('state') not in ('CLOSED','DELIVERED','DISCARDED'):fail('nonterminal recovery is refused')
    names=['source-root','session-root','root-inode','base-sha','journal']
    if journal['state']=='DELIVERED':names+=['delivered-sha','delivered-manifest']
    if journal['state']=='DISCARDED':names+=['discarded.patch']
    binding={'owner':owner,'source_root':source,'recorded_root':str(recorded),'base':base,
        'lifecycle':journal['state'],'root_inode':info.st_ino,'root_device':info.st_dev,
        'metadata':{name:checksum(work.metadata(record/name)) for name in names}}
    result={'schema':SCHEMA,'binding':binding,'work':work_inventory(root,capture),
            'index':index_inventory(root,capture)}
    if root.lstat().st_ino!=info.st_ino:fail('recovery root changed')
    return {**result,'inventory_sha256':identity(result)}


def load_archive(archive):
    archive=Path(archive);before=private_dir(archive);objects=archive/'objects';object_info=private_dir(objects)
    if set(os.listdir(archive))!={'objects','manifest.json','restore-receipt.json'}:fail('unknown recovery archive entry')
    raw=read_file(archive/'manifest.json',True);manifest=json.loads(raw)
    expected_sha=manifest.get('inventory_sha256');body={k:v for k,v in manifest.items() if k!='inventory_sha256'}
    if manifest.get('schema')!=SCHEMA or identity(body)!=expected_sha:fail('recovery manifest changed')
    expected={v['sha256']:v['bytes'] for v in manifest['work']['files'].values()}
    expected.update({v['sha256']:v['bytes'] for v in manifest['index']['objects'].values()})
    expected[manifest['index']['raw_sha256']]=manifest['index']['raw_bytes']
    if set(os.listdir(objects))!=set(expected):fail('recovery object inventory changed')
    for sha,size in expected.items():
        if not re.fullmatch(r'[0-9a-f]{64}',sha):fail('invalid recovery object name')
        value=read_file(objects/sha,True)
        if checksum(value)!=sha or len(value)!=size:fail('recovery object changed')
    receipt=json.loads(read_file(archive/'restore-receipt.json',True))
    wanted={'schema':SCHEMA,'inventory_sha256':expected_sha,'work_sha256':identity(manifest['work']),
            'index_sha256':identity(manifest['index']),'restored':True}
    if receipt!=wanted:fail('missing independent recovery restore proof')
    if (private_dir(archive).st_ino!=before.st_ino or private_dir(objects).st_ino!=object_info.st_ino
            or read_file(archive/'manifest.json',True)!=raw):fail('recovery archive replaced')
    return manifest


def restore_content(archive, manifest, destination):
    destination=Path(destination)
    if os.path.lexists(destination):fail('recovery destination exists')
    destination.mkdir(mode=0o700)
    for relative in sorted(manifest['work']['directories'],key=lambda p:(len(Path(p).parts),p)):
        safe_path(relative)
        if work.excluded(relative):fail('excluded recovery directory')
        (destination/relative).mkdir(mode=0o700)
    for relative,entry in manifest['work']['files'].items():
        safe_path(relative)
        if work.excluded(relative):fail('excluded recovery file')
        path=destination/relative;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        raw=read_file(Path(archive)/'objects'/entry['sha256'],True)
        if entry['kind']=='symlink':
            path.symlink_to(os.fsdecode(raw))
            try:os.chmod(path,entry['mode'],follow_symlinks=False)
            except (NotImplementedError,OSError) as error:
                raise work.WorkError('symlink recovery mode cannot be restored') from error
        elif entry['kind']=='file':put(path,raw);path.chmod(entry['mode'])
        else:fail('unsupported recovery kind')
    algorithm='sha1' if len(manifest['binding']['base'])==40 else 'sha256'
    work.git(destination,'init','-q','--template=','--object-format='+algorithm)
    index=manifest['index'];object_ids=sorted(index['objects'])
    paths=''.join(str(Path(archive)/'objects'/index['objects'][oid]['sha256'])+'\n' for oid in object_ids)
    if '\n' in str(archive) or '\r' in str(archive):fail('unsupported recovery archive path')
    produced=work.git(destination,'hash-object','-w','--no-filters','--stdin-paths',input_data=os.fsencode(paths)).decode().splitlines()
    if produced!=object_ids:fail('restored recovery objects differ')
    put(destination/'.git/index',read_file(Path(archive)/'objects'/index['raw_sha256'],True))
    for relative,mode in sorted(manifest['work']['directories'].items(),reverse=True):
        (destination/relative).chmod(mode)
    if work_inventory(destination)!=manifest['work'] or index_inventory(destination)!=index:
        fail('independent recovery restore differs')


def preserve(state, owner, expected):
    if not work.UUID.fullmatch(owner):fail('invalid recovery owner')
    state=Path(state).resolve(strict=True);record=state/'sessions'/owner
    lock=record/'runtime.lock';before=lock.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid():fail('unsafe recovery lease')
    fd=os.open(lock,os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        fcntl.lockf(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if work.stamp(os.fstat(fd))!=work.stamp(before):fail('recovery lease changed')
        capture={};observed=inventory(state,owner,capture=capture)
        if observed['inventory_sha256']!=expected:fail('approved recovery inventory changed')
        archive=record/'work-recovery'
        if os.path.lexists(archive):fail('recovery archive already exists')
        staging=Path(tempfile.mkdtemp(prefix='.work-recovery-',dir=record))
        try:
            (staging/'objects').mkdir(mode=0o700)
            if sum(len(raw) for raw in capture.values())>TOTAL_LIMIT:fail('recovery archive limit')
            for sha,raw in capture.items():put(staging/'objects'/sha,raw)
            put(staging/'manifest.json',encoded(observed))
            with tempfile.TemporaryDirectory(prefix='work-recovery-restore-') as temporary:
                restore_content(staging,observed,Path(temporary).resolve()/'work')
            receipt={'schema':SCHEMA,'inventory_sha256':expected,'work_sha256':identity(observed['work']),
                     'index_sha256':identity(observed['index']),'restored':True}
            put(staging/'restore-receipt.json',encoded(receipt))
            load_archive(staging)
            if inventory(state,owner)!=observed:fail('source changed during recovery preservation')
            sync_dir(staging/'objects');sync_dir(staging);sync_dir(record)
            if os.path.lexists(archive):fail('recovery archive appeared')
            # A durable pending marker survives even if publishing and rollback
            # both fail. Never expose an admissible receipt before parent fsync.
            put(staging/'publication-pending',b'parent directory sync pending\n')
            sync_dir(staging)
            staging.rename(archive)
            sync_dir(record)
            # All custody bytes and the final parent entry are now durable.
            # A crash may resurrect this removal and conservatively HOLD; it
            # cannot admit an incompletely published archive.
            (archive/'publication-pending').unlink()
            return {'status':'preserved','owner':owner,'archive':str(archive),'inventory_sha256':expected}
        finally:
            if staging.exists():shutil.rmtree(staging)
    finally:os.close(fd)


def verify(state, owner, root):
    archive=Path(state)/'sessions'/owner/'work-recovery';manifest=load_archive(archive)
    if inventory(state,owner,root)!=manifest:fail('preserved recovery inventory no longer matches source')
    return {'kind':'preserved_work_and_index','archive':str(archive),
            'inventory_sha256':manifest['inventory_sha256']}


def main():
    parser=argparse.ArgumentParser();sub=parser.add_subparsers(dest='command',required=True)
    for command in ('inventory','preserve'):
        p=sub.add_parser(command);p.add_argument('--state',type=Path,required=True);p.add_argument('--owner',required=True)
        if command=='preserve':p.add_argument('--expected',required=True)
    p=sub.add_parser('restore');p.add_argument('--archive',type=Path,required=True);p.add_argument('--destination',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.command=='inventory':result=inventory(args.state,args.owner)
        elif args.command=='preserve':result=preserve(args.state,args.owner,args.expected)
        else:
            manifest=load_archive(args.archive);restore_content(args.archive,manifest,args.destination)
            result={'status':'restored','inventory_sha256':manifest['inventory_sha256']}
        print(json.dumps(result,sort_keys=True))
    except (OSError,ValueError,KeyError,TypeError) as error:
        print(json.dumps({'status':'retained','reason':str(error)}));return 2
    return 0


if __name__=='__main__':raise SystemExit(main())

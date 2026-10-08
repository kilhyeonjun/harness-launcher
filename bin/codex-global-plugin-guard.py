#!/usr/bin/env python3
"""Read-only proof that a snapshot's Chrome assets fit the existing bridge."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def signature(root):
    root=Path(root)
    if not root.is_dir():raise ValueError()
    found={}
    for path in root.rglob('*'):
        if path.name=='extension-host-config.json':continue
        meta=path.lstat();name=str(path.relative_to(root))
        if meta.st_uid!=os.getuid():raise ValueError()
        if stat.S_ISLNK(meta.st_mode):
            path.resolve(strict=True).relative_to(root.resolve())
            found[name]=('link',os.readlink(path))
        elif stat.S_ISREG(meta.st_mode):
            found[name]=('file',bool(meta.st_mode&0o111),hashlib.sha256(path.read_bytes()).hexdigest())
        elif not stat.S_ISDIR(meta.st_mode):raise ValueError()
    return found


def compatible(local,global_):
    local=Path(local);global_=Path(global_)
    if signature(local)!=signature(global_):raise ValueError()
    manifest=json.loads((local/'.codex-plugin/plugin.json').read_text())
    if not manifest.get('version'):raise ValueError()
    extension='hehggadaopoacecdllhhajmbjkdcmajg'
    path=local/'scripts/extension-id.json'
    if path.exists():extension=json.loads(path.read_text()).get('extensionId') or extension
    expected={'schemaVersion':1,'channel':'prod',
        'browserClientPath':str(global_/'scripts/browser-client.mjs'),
        'codexCliPath':'/Applications/Codex.app/Contents/Resources/codex',
        'extensionId':extension,'nodePath':'/Applications/Codex.app/Contents/Resources/cua_node/bin/node',
        'nodeReplPath':'/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl',
        'proxyHost':'127.0.0.1','proxyPort':0}
    configs=list(global_.glob('extension-host/*/*/extension-host-config.json'))
    if not configs:raise ValueError()
    for config in configs:
        if config.is_symlink() or config.stat().st_uid!=os.getuid() or json.loads(config.read_text())!=expected:
            raise ValueError()


if __name__=='__main__':
    try:
        if len(sys.argv)!=3:raise ValueError()
        compatible(*sys.argv[1:])
    except (OSError,ValueError,TypeError,KeyError):
        print('global_plugin_incompatible: preserve policy requires the existing matching Chrome bridge',file=sys.stderr)
        raise SystemExit(2)

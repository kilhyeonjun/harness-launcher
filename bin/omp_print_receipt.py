"""Private launcher print receipt protocol; never accepts a caller receipt path."""
import json
import os
from pathlib import Path
import re
import stat
import sys

KEYS = ('HARNESS_SESSION_ID', 'HARNESS_SOURCE_ROOT', 'HARNESS_SESSION_ROOT', 'HARNESS_RUN_DIR')
UUID = re.compile(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')


def tuple_from(env):
    values = {key: env.get(key, '') for key in KEYS}
    if not UUID.fullmatch(values[KEYS[0]]) or not all(values[key].startswith('/') for key in KEYS[1:]):
        return dict.fromkeys(KEYS, '')
    return values


def state_home(value):
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_dir() or str(path.resolve()) != value:
        raise ValueError('invalid session state directory')
    return value


def receipt(path, nonce, action, env, native_pid=None):
    target = Path(path)
    parent = target.parent
    info = parent.lstat()
    if (parent.is_symlink() or str(parent.resolve()) != str(parent) or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError('invalid private directory')
    if not UUID.fullmatch(nonce):
        raise ValueError('invalid nonce')
    if action == 'create':
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    else:
        flags = os.O_RDONLY | os.O_NOFOLLOW
    fd = os.open(target, flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError('invalid receipt metadata')
        expected = {'schema': 1, 'nonce': nonce, 'tuple': tuple_from(env),
                    'native_session': None, 'native_pid': None, 'denied': False, 'started': False}
        if action == 'create':
            os.write(fd, json.dumps(expected).encode())
            return 0
        if info.st_size > 8192:
            raise ValueError('receipt too large')
        row = json.loads(os.read(fd, 8193))
        if (not isinstance(row, dict) or row.keys() != expected.keys()
                or type(row['schema']) is not int or row['schema'] != 1
                or row['nonce'] != nonce or row['tuple'] != expected['tuple']
                or type(row['denied']) is not bool or type(row['started']) is not bool
                or type(row['native_pid']) is not int or row['native_pid'] != native_pid
                or not row['started'] or not isinstance(row['native_session'], str)
                or not UUID.fullmatch(row['native_session'])):
            raise ValueError('invalid receipt binding')
        identity_fd = os.open(parent / 'identity.json', os.O_RDONLY | os.O_NOFOLLOW)
        try:
            identity_info = os.fstat(identity_fd)
            if (not stat.S_ISREG(identity_info.st_mode) or identity_info.st_nlink != 1
                    or identity_info.st_uid != os.getuid() or stat.S_IMODE(identity_info.st_mode) != 0o600
                    or identity_info.st_size > 1024):
                raise ValueError('invalid native identity metadata')
            identity = json.loads(os.read(identity_fd, 1025))
            if identity != {'nonce': nonce, 'native_session': row['native_session'], 'native_pid': native_pid}:
                raise ValueError('native session identity changed')
        finally:
            os.close(identity_fd)
        return 2 if row['denied'] else 0
    finally:
        os.close(fd)


def main(argv):
    try:
        if argv[0] == 'state':
            state_home(argv[1])
            return 0
        return receipt(argv[1], argv[2], argv[0], os.environ, int(argv[3]) if len(argv) > 3 else None)
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        print('harness-launcher: OMP_PRINT_RECEIPT_INVALID', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Run a command with a hard time limit, with or without a terminal.

usage: run-bounded.py (tty|notty) SECONDS OUTPUT-FILE COMMAND [ARG...]

notty  stdin is /dev/null; stdout and stderr go to OUTPUT-FILE.
tty    stdin, stdout and stderr are one pty; its transcript goes to OUTPUT-FILE
       with CRLF turned into LF. Nothing is ever sent to the command's stdin.

The command runs in its own session, so a timeout kills every process it
started. Exit status: the command's own (128+N when killed by signal N), or 124
after a timeout, in which case a "TIMEOUT" line ends OUTPUT-FILE.
"""
import os
import pty
import select
import signal
import subprocess
import sys
import time


def exit_code(status):
    try:
        return os.waitstatus_to_exitcode(status)
    except AttributeError:  # Python < 3.9
        return os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def run_notty(argv, limit, out_path):
    with open(out_path, "wb") as out:
        proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
            start_new_session=True)
        try:
            code = proc.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            kill_group(proc.pid)
            proc.wait()
            out.write(b"TIMEOUT after %g s\n" % limit)
            return 124
    return code if code >= 0 else 128 - code


def run_tty(argv, limit, out_path):
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)
    deadline = time.monotonic() + limit
    chunks = []
    status = None
    timed_out = False

    def drain(wait):
        while True:
            ready, _, _ = select.select([fd], [], [], wait)
            if not ready:
                return
            try:
                data = os.read(fd, 65536)
            except OSError:  # EIO: the last slave descriptor closed
                return
            if not data:
                return
            chunks.append(data)
            wait = 0

    while status is None:
        if time.monotonic() >= deadline:
            timed_out = True
            break
        drain(0.2)
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
    if timed_out:
        kill_group(pid)
        _, status = os.waitpid(pid, 0)
    else:
        drain(0.2)  # whatever the command wrote just before it exited
    os.close(fd)
    text = b"".join(chunks).replace(b"\r\n", b"\n")
    if timed_out:
        text += b"TIMEOUT after %g s\n" % limit
    with open(out_path, "wb") as out:
        out.write(text)
    return 124 if timed_out else exit_code(status)


def main():
    if len(sys.argv) < 5 or sys.argv[1] not in ("tty", "notty"):
        sys.stderr.write(__doc__)
        return 2
    mode, limit, out_path, argv = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4:]
    return (run_tty if mode == "tty" else run_notty)(argv, limit, out_path)


if __name__ == "__main__":
    sys.exit(main())

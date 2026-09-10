#!/usr/bin/env python3
"""Symlink-safe, argv-free read/write/remove of the Scripture plugin's esv.key.

The API key never appears in a process argument list: `save` reads the key
from stdin (single line), and `get`/`remove` take no secret at all. The
plugin dir can sit under user- or attacker-influenceable directory state, so
every path is reached through a verified parent traversal:

- `open_key_dir()` walks the plugin folder component-by-component from `/`
  with `O_NOFOLLOW|O_DIRECTORY`, so a symlinked path component anywhere is a
  hard refusal.
- Reads open `esv.key` once via an `O_NOFOLLOW|O_NONBLOCK` descriptor and,
  from fstat, refuse anything that is not a regular file owned by the current
  user with a single hard link (a planted hard link cannot be truncated) and a
  size at or below MAX_KEY_BYTES; the read itself is bounded to MAX+1 bytes.
- Writes go to a randomized same-directory temporary file created with
  `O_CREAT|O_EXCL|O_NOFOLLOW` (mode 0600), are fsynced and validated from a
  no-follow descriptor, then atomically replace the key entry — the existing
  `esv.key` inode is never opened for writing, so neither a symlink nor a hard
  link at that name can redirect or truncate another file.

Usage:
    printf %s "<key>" | python3 keyctl.py save   # write key, mode 0600
    python3 keyctl.py get                        # print key, whitespace stripped
    python3 keyctl.py remove                     # remove the file (never a symlink)
"""

import os
import stat
import sys

KEY_NAME = "esv.key"
KEY_DIR = os.path.dirname(os.path.abspath(__file__))
MAX_KEY_BYTES = 4096  # real ESV keys are ~35 chars


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def open_key_dir() -> int:
    """Open KEY_DIR from / without following any symlink component."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    for part in KEY_DIR.split(os.sep):
        if not part:
            continue
        try:
            nxt = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=fd,
            )
        except OSError:
            os.close(fd)
            fail("refusing to traverse %s (symlinked or unreadable path)" % KEY_DIR)
        os.close(fd)
        fd = nxt
    return fd


def read_key(dirfd: int) -> str:
    """Read the stored key via one bounded no-follow descriptor, or '' if absent."""
    fd = None
    try:
        try:
            fd = os.open(
                KEY_NAME,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                dir_fd=dirfd,
            )
        except FileNotFoundError:
            return ""
        except OSError:
            fail("esv.key refused open (symlink or unreadable)")
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            fail("esv.key is not a regular file; refusing")
        if st.st_uid != os.geteuid():
            fail("esv.key is not owned by the current user; refusing")
        if st.st_nlink != 1:
            fail("esv.key has unexpected hard links; refusing")
        if st.st_size > MAX_KEY_BYTES:
            fail("esv.key exceeds the %d-byte limit; refusing" % MAX_KEY_BYTES)
        with os.fdopen(fd, "rb") as raw:
            data = raw.read(MAX_KEY_BYTES + 1)
        fd = None
    finally:
        if fd is not None:
            os.close(fd)
    if len(data) > MAX_KEY_BYTES:
        fail("esv.key exceeds the %d-byte limit; refusing" % MAX_KEY_BYTES)
    return "".join(ch for ch in data.decode("utf-8", "replace") if not ch.isspace())


def validate_regular_file(fd: int, label: str, max_size: int) -> None:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        fail("%s is not a regular file; refusing" % label)
    if st.st_uid != os.geteuid():
        fail("%s is not owned by the current user; refusing" % label)
    if st.st_nlink != 1:
        fail("%s has unexpected hard links; refusing" % label)
    if st.st_size > max_size:
        fail("%s exceeds the %d-byte limit; refusing" % (label, max_size))


def read_bounded_line(fd: int, limit: int) -> bytes:
    """Read a single line from a pipe without ever buffering past limit bytes."""
    buf = bytearray()
    while len(buf) <= limit:
        chunk = os.read(fd, min(4096, limit + 2 - len(buf)))
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            break
    return bytes(buf)


def parse_key_line() -> str:
    """Read exactly one ASCII token from stdin, bounded and without leaking."""
    raw = read_bounded_line(sys.stdin.fileno(), MAX_KEY_BYTES + 1)
    if len(raw) > MAX_KEY_BYTES:
        fail("key exceeds the %d-byte limit; refusing" % MAX_KEY_BYTES)
    pieces = raw.split(b"\n", 1)
    if len(pieces) > 1 and pieces[1].strip():
        fail("key must be a single line")
    line = pieces[0].strip()
    if not line:
        fail("no key provided on stdin")
    try:
        key = line.decode("ascii")
    except UnicodeDecodeError:
        fail("key must contain only ASCII characters")
    if any(char.isspace() for char in key):
        fail("key must be a single ASCII token")
    return key


def cmd_save() -> None:
    key = parse_key_line()
    payload = (key + "\n").encode("ascii")

    dirfd = open_key_dir()
    tmp_fd = None
    tmp_name = None
    try:
        for _ in range(100):
            candidate = ".%s.%s.tmp" % (KEY_NAME, os.urandom(8).hex())
            try:
                tmp_fd = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600,
                    dir_fd=dirfd,
                )
                tmp_name = candidate
                break
            except FileExistsError:
                continue
        if tmp_fd is None:
            fail("could not create a temporary key file in %s; refusing" % KEY_DIR)
        with os.fdopen(tmp_fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        tmp_fd = None
        vfd = None
        try:
            try:
                vfd = os.open(
                    tmp_name,
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=dirfd,
                )
            except OSError:
                fail("temporary key file refused open; refusing")
            validate_regular_file(vfd, tmp_name, MAX_KEY_BYTES)
            if os.fstat(vfd).st_size != len(payload):
                fail("temporary key file size mismatch; refusing")
        finally:
            if vfd is not None:
                os.close(vfd)
        os.replace(tmp_name, KEY_NAME, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
        tmp_name = None
    finally:
        if tmp_fd is not None:
            os.close(tmp_fd)
        if tmp_name is not None:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except FileNotFoundError:
                pass
        os.close(dirfd)
    print("ok")


def cmd_get() -> None:
    dirfd = open_key_dir()
    try:
        value = read_key(dirfd)
    finally:
        os.close(dirfd)
    sys.stdout.write(value)


def cmd_remove() -> None:
    dirfd = open_key_dir()
    try:
        try:
            st = os.lstat(KEY_NAME, dir_fd=dirfd)
        except FileNotFoundError:
            print("ok")
            return
        if stat.S_ISLNK(st.st_mode):
            fail("esv.key is a symlink; refusing to remove")
        os.unlink(KEY_NAME, dir_fd=dirfd)
    finally:
        os.close(dirfd)
    print("ok")


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: keyctl.py {save|get|remove}")
    op = sys.argv[1]
    if op == "save":
        cmd_save()
    elif op == "get":
        cmd_get()
    elif op == "remove":
        cmd_remove()
    else:
        fail("unknown op: %s" % op)


if __name__ == "__main__":
    main()
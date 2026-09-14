#!/usr/bin/env python3
"""Symlink-safe, atomic list/add/remove/clear of the Scripture plugin's
favorite verse references, stored in favorites.json (a plain JSON array of
anchor strings like "John 3:16").

Favorites are not secrets, but the plugin dir can sit under user- or
attacker-influenceable directory state, so the same hardened discipline as
keyctl.py applies:

- Every path is reached through a verified parent traversal
  (`open_plugin_dir()` walks the plugin folder component-by-component from `/`
  with `O_NOFOLLOW|O_DIRECTORY`; a symlinked component anywhere is a refusal).
- Reads open favorites.json once via `O_NOFOLLOW|O_NONBLOCK` and, from
  fstat, refuse anything that is not a regular file owned by the current user
  with a single hard link and a file size at or below MAX_JSON_BYTES; the read
  itself is bounded to MAX_JSON_BYTES + 1.
- Writes go to a randomized same-directory temporary file created with
  `O_CREAT|O_EXCL|O_NOFOLLOW` (mode 0600), are fsynced, then atomically
  replace the favorites.json entry — a symlink or hard link at that name can
  never redirect or truncate another file.

References travel in argv (non-secret): anchors are validated (non-empty, at
most MAX_ANCHOR_BYTES, no control characters) and the list is capped at
MAX_ENTRIES.

Usage:
    python3 favorites.py list
    python3 favorites.py add "John 3:16"
    python3 favorites.py remove "John 3:16"
    python3 favorites.py clear
"""

import json
import os
import stat
import sys

FILE_NAME = "favorites.json"
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
MAX_ANCHOR_BYTES = 120
MAX_ENTRIES = 200
MAX_JSON_BYTES = 65536


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def open_plugin_dir() -> int:
    """Open PLUGIN_DIR from / without following any symlink component."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    for part in PLUGIN_DIR.split(os.sep):
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
            fail("refusing to traverse %s (symlinked or unreadable path)" % PLUGIN_DIR)
        os.close(fd)
        fd = nxt
    return fd


def read_favorites(dirfd: int) -> list:
    """Read the stored list via one bounded no-follow descriptor, or []."""
    fd = None
    data = b""
    try:
        try:
            fd = os.open(
                FILE_NAME,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                dir_fd=dirfd,
            )
        except FileNotFoundError:
            return []
        except OSError:
            fail("favorites.json refused open (symlink or unreadable)")
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            fail("favorites.json is not a regular file; refusing")
        if st.st_uid != os.geteuid():
            fail("favorites.json is not owned by the current user; refusing")
        if st.st_nlink != 1:
            fail("favorites.json has unexpected hard links; refusing")
        if st.st_size > MAX_JSON_BYTES:
            fail("favorites.json exceeds the %d-byte limit; refusing" % MAX_JSON_BYTES)
        with os.fdopen(fd, "rb") as raw:
            data = raw.read(MAX_JSON_BYTES + 1)
        fd = None
    finally:
        if fd is not None:
            os.close(fd)
    if len(data) > MAX_JSON_BYTES:
        fail("favorites.json exceeds the %d-byte limit; refusing" % MAX_JSON_BYTES)
    try:
        value = json.loads(data.decode("utf-8"))
    except Exception:
        fail("favorites.json is not valid JSON; refusing")
    if not isinstance(value, list):
        fail("favorites.json is not a JSON list; refusing")
    return [anchor for anchor in value if isinstance(anchor, str)]


def write_favorites(dirfd: int, anchors: list) -> None:
    """Atomically replace favorites.json with `anchors` (never follows links)."""
    for anchor in anchors:
        if (
            not isinstance(anchor, str)
            or len(anchor) > MAX_ANCHOR_BYTES
            or any(ord(c) < 32 for c in anchor)
        ):
            fail("invalid favorite entry; refusing to write")
    anchors = anchors[:MAX_ENTRIES]
    payload = (json.dumps(anchors, ensure_ascii=True) + "\n").encode("utf-8")
    if len(payload) > MAX_JSON_BYTES:
        fail("favorites list exceeds the %d-byte limit; refusing" % MAX_JSON_BYTES)

    tmp_fd = None
    tmp_name = None
    try:
        for _ in range(100):
            candidate = ".%s.%s.tmp" % (FILE_NAME, os.urandom(8).hex())
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
            fail("could not create a temporary favorites file in %s; refusing" % PLUGIN_DIR)
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
                fail("temporary favorites file refused open; refusing")
            st = os.fstat(vfd)
            if not stat.S_ISREG(st.st_mode):
                fail("temporary favorites file is not a regular file; refusing")
            if st.st_uid != os.geteuid():
                fail("temporary favorites file ownership; refusing")
            if st.st_nlink != 1:
                fail("temporary favorites file hard links; refusing")
            if st.st_size != len(payload):
                fail("temporary favorites file size mismatch; refusing")
        finally:
            if vfd is not None:
                os.close(vfd)
        os.replace(tmp_name, FILE_NAME, src_dir_fd=dirfd, dst_dir_fd=dirfd)
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


def clean_anchor(raw: str) -> str:
    anchor = str(raw or "").strip()
    if not anchor:
        fail("no reference provided on the command line")
    if len(anchor) > MAX_ANCHOR_BYTES:
        fail("reference exceeds the %d-byte limit" % MAX_ANCHOR_BYTES)
    if any(ord(c) < 32 for c in anchor):
        fail("reference contains control characters; refusing")
    return anchor


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: favorites.py {list|add|remove|clear} [reference]")
    op = sys.argv[1]
    dirfd = open_plugin_dir()
    try:
        if op == "list":
            print(json.dumps(read_favorites(dirfd), ensure_ascii=True))
            return
        if op == "add":
            ref = clean_anchor(sys.argv[2] if len(sys.argv) > 2 else "")
            anchors = [ref] + [a for a in read_favorites(dirfd) if a != ref]
            write_favorites(dirfd, anchors[:MAX_ENTRIES])
            print("ok")
            return
        if op == "remove":
            ref = clean_anchor(sys.argv[2] if len(sys.argv) > 2 else "")
            anchors = [a for a in read_favorites(dirfd) if a != ref]
            write_favorites(dirfd, anchors)
            print("ok")
            return
        if op == "clear":
            write_favorites(dirfd, [])
            print("ok")
            return
        fail("unknown op: %s" % op)
    finally:
        os.close(dirfd)


if __name__ == "__main__":
    main()
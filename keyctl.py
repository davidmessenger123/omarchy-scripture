#!/usr/bin/env python3
"""Symlink-safe read/write/remove of the Scripture plugin's esv.key file.

The plugin dir can be under user control, so the API key is never touched
through a path that a pre-positioned symlink could redirect: writes open with
O_NOFOLLOW and then re-verify the descriptor is a regular file owned by the
current user before a single byte is written; reads and unlinks also refuse
symlinks. Replaces the former shell-redirection write (`printf ... > esv.key`)
and `sh -c` read/remove entirely.

Usage:
    python3 keyctl.py save <key>     # write key + newline, mode 0600
    python3 keyctl.py get            # print key with all whitespace stripped
    python3 keyctl.py remove         # remove the file (never a symlink)
"""

import os
import stat
import sys

KEY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "esv.key")


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def open_key_no_follow(flags, mode=0o600):
    """Open esv.key without following symlinks and confirm file type+owner."""
    try:
        fd = os.open(KEY_PATH, flags | os.O_NOFOLLOW, mode)
    except OSError as exc:
        fail("cannot open esv.key: %s" % exc)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
        os.close(fd)
        fail("esv.key is not a regular file owned by the current user; refusing")
    return fd


def cmd_save():
    if len(sys.argv) < 3:
        fail("usage: keyctl.py save <key>")
    key = sys.argv[2]
    if key == "" or "\n" in key or key != key.strip():
        fail("key must be a single, non-empty line")
    os.makedirs(os.path.dirname(KEY_PATH), exist_ok=True)
    fd = open_key_no_follow(os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, (key + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    print("ok")


def cmd_get():
    fd = open_key_no_follow(os.O_RDONLY)
    try:
        data = os.fdopen(os.dup(fd), "r", encoding="utf-8").read()
    finally:
        os.close(fd)
    sys.stdout.write("".join(ch for ch in data if not ch.isspace()))


def cmd_remove():
    if os.path.islink(KEY_PATH):
        fail("esv.key is a symlink; refusing to remove")
    try:
        os.remove(KEY_PATH)
    except FileNotFoundError:
        pass
    except OSError as exc:
        fail("cannot remove esv.key: %s" % exc)
    print("ok")


def main():
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
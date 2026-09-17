#!/usr/bin/env python3
"""Fetch one ESV passage without ever putting the API key in argv.

The key is read from the first line of this process's stdin (the shell sends
it after the process starts), and the passage reference arrives percent-
encoded through argv (never secret). The response is bounded: at most
MAX_RESPONSE_BYTES are read, so a misbehaving or compromised endpoint cannot
balloon the shared shell's StdioCollector. Non-zero exits (1 error, 2 size
cap) tell the caller the request failed.

Usage:
    printf '%s\n' '<key>' | python3 esv_fetch.py '<urlencoded reference>'
"""

import http.client
import os
import ssl
import sys

HOST = "api.esv.org"
PATH = "/v3/passage/text/"
MAX_RESPONSE_BYTES = 262144
COMMON_QUERY = (
    "&include-headings=false"
    "&include-footnotes=false"
    "&include-verse-numbers=true"
    "&include-short-copyright=false"
    "&include-passage-references=false"
)


def read_bounded_line(fd: int, limit: int) -> bytes:
    """Read one line from the key pipe without ever buffering past limit bytes."""
    buf = bytearray()
    while len(buf) <= limit:
        chunk = os.read(fd, min(4096, limit + 2 - len(buf)))
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            break
    return bytes(buf)


def main() -> None:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("reference missing", file=sys.stderr)
        sys.exit(1)
    query = sys.argv[1].strip().lstrip("?")
    raw = read_bounded_line(sys.stdin.fileno(), 4097)
    if len(raw) > 4096:
        print("key exceeds the 4096-byte limit", file=sys.stderr)
        sys.exit(1)
    pieces = raw.split(b"\n", 1)
    if len(pieces) > 1 and pieces[1].strip():
        print("key must be a single line", file=sys.stderr)
        sys.exit(1)
    line = pieces[0].strip()
    if not line:
        print("no key provided on stdin", file=sys.stderr)
        sys.exit(1)
    try:
        key = line.decode("ascii")
    except UnicodeDecodeError:
        print("key must contain only ASCII characters", file=sys.stderr)
        sys.exit(1)
    if any(char.isspace() for char in key):
        print("key must be a single ASCII token", file=sys.stderr)
        sys.exit(1)

    conn = http.client.HTTPSConnection(
        HOST,
        timeout=15,
        context=ssl.create_default_context(),
    )
    try:
        conn.request(
            "GET",
            PATH + "?q=" + query + COMMON_QUERY,
            headers={
                "Authorization": "Token " + key,
                "Accept": "application/json",
                "User-Agent": "omarchy-scripture/1.0",
            },
        )
        resp = conn.getresponse()
        status = resp.status
        body = resp.read(MAX_RESPONSE_BYTES + 1)
    except Exception as exc:
        print("esv fetch failed: %s" % exc, file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()

    if status == 429 or 500 <= status < 600:
        # Rate-limit or server-side error: retrying immediately doubles the
        # request (and burns quota), so signal the caller not to auto-retry.
        print("esv returned HTTP %d, not retrying" % status, file=sys.stderr)
        sys.exit(3)
    if status != 200:
        # Still bounded: only the (already read) status body made it in.
        print("esv returned HTTP %d" % status, file=sys.stderr)
        sys.exit(1)
    if len(body) > MAX_RESPONSE_BYTES:
        print("esv response exceeds the %d-byte limit" % MAX_RESPONSE_BYTES, file=sys.stderr)
        sys.exit(2)
    sys.stdout.buffer.write(body)


if __name__ == "__main__":
    main()
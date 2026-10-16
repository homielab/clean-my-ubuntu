#!/usr/bin/env python3
"""TUI smoke test: drive clean-my-ubuntu.sh in a virtual terminal (dry-run).

Walks through the main screens and checks that each one renders and that bash
never prints an error. Run by tests/run.sh with HOME pointing to a throwaway
folder. Needs the `pyte` module (pip install pyte).
"""
import fcntl, os, pty, re, select, struct, sys, termios, time

import pyte

SCRIPT = sys.argv[1]
ROWS, COLS = 34, 110
ERRORS = re.compile(r"command not found|syntax error|unbound variable|bad array subscript|line \d+: ")

screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
raw = bytearray()

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", CMU_NO_UPDATE_CHECK="1")
    os.execvp("bash", ["bash", SCRIPT, "--dry-run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            raw.extend(data)
            stream.feed(data)


def text():
    return "\n".join(screen.display)


def step(keys, expect, wait=1.0, timeout=20.0):
    """Send keys, then wait until `expect` (regex) is on screen."""
    if keys:
        os.write(fd, keys.encode())
    pump(wait)
    end = time.time() + timeout
    while not re.search(expect, text()) and time.time() < end:
        pump(0.3)
    found = re.search(expect, text()) is not None
    print(f"{'ok  ' if found else 'FAIL'} {keys!r:12} → /{expect}/")
    if not found:
        print(text())
    return found


checks = [
    ("", r"Smart Scan.*\n(.*\n)*.*CLEANUP"),        # home menu with sections
    ("?", r"Moving around"),                        # help overlay
    ("q", r"CLEANUP"),
    ("1", r"Scan system folders with sudo"),        # smart scan asks about sudo first
    ("n", r"of junk found|Your system is clean"),   # … then shows the review
    ("h", r"hide clean|show clean"),                # toggle clean rows
    ("q", r"CLEANUP"),
    ("7", r"history list|Nothing to clear"),        # privacy
    ("q", r"CLEANUP"),
    ("s", r"Settings[\s\S]*ABOUT"),                 # settings with sections
    ("q", r"CLEANUP"),
    ("i", r"Largest folders"),                      # system overview
    ("q", r"CLEANUP"),
    ("t", r"start at login"),                       # startup items
    ("q", r"CLEANUP"),
    ("u", r"Uninstaller[\s\S]*apps? · all apps · by size"),  # app list, no search needed
    ("s", r"· by used"),                            # sort by last used
    ("f", r"not used for 90\+ days"),               # filter
    ("q", r"CLEANUP"),
    ("m", r"Keep fewer snap versions[\s\S]*Limit journal size"),
    ("q", r"CLEANUP"),
    ("/", r"Find:"),                                # find a menu row by name
    ("dupl\n", r"▸ 0\s+Duplicates"),
]
ok = all(step(k, e) for k, e in checks)
os.write(fd, b"q")
pump(1.0)

errors = ERRORS.findall(raw.decode(errors="replace"))
if errors:
    print("FAIL bash errors in output:", sorted(set(errors)))
    ok = False
sys.exit(0 if ok else 1)

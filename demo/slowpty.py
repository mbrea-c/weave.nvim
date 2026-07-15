#!/usr/bin/env python3
# A pty relay with a byte-rate cap on the child-to-terminal direction, the
# engine behind `make demo-constrained` / `nix run .#demo-constrained`.
#
# The obvious pipeline (`script -c nvim | pv -qL RATE`) simulates the wrong
# thing: pv keeps a 400 KiB transfer buffer and the pipe adds another 64 KiB,
# so the child never feels backpressure. It paints into an invisible queue and
# the terminal replays frames that are tens of seconds stale; the link
# sustains its cap, but everything on screen is ancient. This relay instead
# only READS from the pty master when the token bucket allows it, so once the
# small kernel pty buffer fills the child's own writes block, exactly like a
# real 9600-baud serial line: lag stays bounded at a few KB and the screen
# always shows the newest state the link could carry.
#
# Usage: slowpty.py BYTES_PER_SEC CMD [ARG...]
# Keystrokes (terminal to child) are never throttled; the slow direction of a
# remote session is the downlink.

import fcntl
import os
import pty
import select
import signal
import sys
import termios
import time
import tty


def writeall(fd, data):
    while data:
        data = data[os.write(fd, data):]


def apply_winsize(master):
    try:
        size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(master, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: slowpty.py BYTES_PER_SEC CMD [ARG...]\n")
        return 2
    rate = float(sys.argv[1])
    cmd = sys.argv[2:]

    pid, master = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)

    stdin_tty = os.isatty(0)
    saved = None
    winch = [False]
    if stdin_tty:
        apply_winsize(master)
        signal.signal(signal.SIGWINCH, lambda *_: winch.__setitem__(0, True))
        saved = termios.tcgetattr(0)
        tty.setraw(0)

    # Bucket capacity trades throughput smoothness against latency; an eighth
    # of a second of budget keeps small row-local updates instant at any rate.
    cap = max(512.0, rate / 8.0)
    tokens = cap
    last = time.monotonic()
    stdin_open = True

    try:
        while True:
            if winch[0]:
                winch[0] = False
                apply_winsize(master)

            now = time.monotonic()
            tokens = min(cap, tokens + (now - last) * rate)
            last = now

            # Out of budget: leave the master unread (that is the throttle;
            # the kernel buffer behind it is what blocks the child) and wake
            # when roughly a chunk's worth of tokens has accrued.
            rfds = [0] if stdin_open else []
            if tokens >= 1.0:
                rfds.append(master)
                timeout = 0.25
            else:
                timeout = min(0.25, (256.0 - tokens) / rate)

            r, _, _ = select.select(rfds, [], [], timeout)

            if 0 in r:
                try:
                    data = os.read(0, 4096)
                except OSError:
                    data = b""
                if data:
                    writeall(master, data)
                else:
                    stdin_open = False

            if master in r:
                try:
                    data = os.read(master, int(min(tokens, 2048)))
                except OSError:  # EIO: child gone, buffer drained
                    break
                if not data:
                    break
                tokens -= len(data)
                writeall(1, data)
    finally:
        if saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)

    _, st = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(st)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())

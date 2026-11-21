"""Run the capped panel and viewport prototype in fresh, fixed-size Linux PTYs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


def run(mode, size, repeat, *, history_resize=False, reveal_pages=None):
    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / "result.json"
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        env = dict(os.environ, TERM="xterm-256color", BENCH_RESULT=str(output),
                   BENCH_MODE=mode, BENCH_N=str(size), BENCH_TTY=os.ttyname(slave))
        env["BENCH_HISTORY_RESIZE"] = "1" if history_resize else "0"
        if reveal_pages is not None:
            env["BENCH_REVEAL_PAGES"] = str(reveal_pages)
        env.setdefault("FIBROUS_PATH", str(ROOT.parent / "fibrous.nvim"))
        args = [env.get("NVIM_BIN", "nvim"), "-u", "NONE", "-i", "NONE", "-n",
                "-c", "set shortmess+=I noswapfile", "-c", "luafile bench/visibility_case.lua"]
        with subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, env=env, cwd=ROOT) as proc:
            os.close(slave)
            deadline = time.monotonic() + 90
            log = bytearray()
            try:
                while proc.poll() is None:
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"timeout {mode}: {log[-1500:]!r}")
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            log.extend(os.read(master, 65536))
                        except OSError:
                            break
            finally:
                os.close(master)
                if proc.poll() is None and not output.exists():
                    proc.kill()
            proc.wait(timeout=5)
            if not output.exists():
                raise RuntimeError(f"Neovim failed: {log[-1500:]!r}")
            record = json.loads(output.read_text())
            if proc.returncode or "error" in record:
                raise RuntimeError(f"{mode} at {size}: {record}")
        pattern = rb"\x1b\]777;weavebench;([a-z0-9_]+);begin\x07(.*?)\x1b\]777;weavebench;\1;end\x07"
        frames = {}
        for name, payload in re.findall(pattern, bytes(log), flags=re.S):
            frames.setdefault(name.decode(), []).append(len(payload))
        for name, samples in record["samples"].items():
            if len(frames.get(name, [])) != len(samples):
                raise RuntimeError(f"incomplete PTY trace for {name}")
        return dict(record, repeat=repeat, terminal_bytes=frames)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[20000, 50000, 100000])
    parser.add_argument("--repeats", type=int, default=8)
    parser.add_argument("--history-resize", action="store_true", help="resize the panel on an old entry")
    parser.add_argument("--reveal-pages", type=int, help="materialize the window left by this many older reveals from the tail")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.reveal_pages is not None and (not args.history_resize or args.reveal_pages < 1):
        parser.error("--reveal-pages requires --history-resize and a positive number of pages")
    with args.output.open("w") as out:
        for repeat in range(args.repeats):
            for size in args.sizes:
                modes = ["button", "auto"] if repeat % 2 == 0 else ["auto", "button"]
                pair = [run(mode, size, repeat, history_resize=args.history_resize,
                            reveal_pages=args.reveal_pages) for mode in modes]
                if args.history_resize:
                    phases = ("bounded_text_digests", "expanded_text_digests")
                else:
                    phases = ("tail_digest", "stream_digest", "resize_digest")
                for phase in phases:
                    assert pair[0]["checks"][phase] == pair[1]["checks"][phase], f"{phase} differs"
                for case in pair:
                    out.write(json.dumps(case) + "\n")
                out.flush()
                print(f"{size:,} entries, pair {repeat+1} complete", flush=True)

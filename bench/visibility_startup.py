"""Profile the first large native-buffer allocation in the real panel benchmark."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from visibility_compare import ROOT, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--size", type=int, default=100000)
    parser.add_argument("--repeats", type=int, default=8)
    args = parser.parse_args()
    source = Path(os.environ.get("FIBROUS_PATH", ROOT.parent / "fibrous.nvim"))
    target = "vim.api.nvim_buf_set_lines(buf, current, current, false, blanks(total - current))"
    with tempfile.TemporaryDirectory() as work, args.output.open("w") as results:
        base = Path(work)
        for chunk in (0, 4096):
            checkout = base / str(chunk)
            shutil.copytree(source / "lua", checkout / "lua")
            path = checkout / "lua/fibrous/inline/visibility.lua"
            code = path.read_text()
            assert code.count(target) == 1
            replacement = f"""
    if total-current > 10000 then
      local start = vim.uv.hrtime()
      local step = {chunk} == 0 and total-current or {chunk}
      local block = blanks(step)
      for row = current, total-1, step do
        local count = math.min(step,total-row)
        vim.api.nvim_buf_set_lines(buf,row,row,false,count==step and block or blanks(count))
      end
      local ms = (vim.uv.hrtime()-start)/1e6
      vim.fn.writefile({{tostring(ms)}},vim.env.RESERVE_LOG,"a")
    else
      {target}
    end"""
            path.write_text(code.replace(target,replacement))
        for repeat in range(args.repeats):
            for chunk in ((0, 4096) if repeat % 2 == 0 else (4096, 0)):
                log = base / f"{repeat}-{chunk}.log"
                os.environ.update(FIBROUS_PATH=str(base / str(chunk)), RESERVE_LOG=str(log))
                result = run("auto", args.size, repeat)
                measurements = log.read_text().splitlines()
                assert len(measurements) == 1
                result.update(chunk=chunk, reserve_ms=float(measurements[0]))
                results.write(json.dumps(result) + "\n")
                results.flush()


if __name__ == "__main__":
    main()

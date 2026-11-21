# Viewport rendering in large Weave transcripts

> Archived prototype report from the supplied changeset. Timings, test counts
> and reproduction instructions below describe that prototype, not the current
> integration. Use `nix run .#bench-visibility -- --help` for the pinned entry
> point. New local measurements under `validation/2026-11-20/` are provisional;
> performance validation is paused until the user requests it.

Auto mode visited the same 300 older entries faster in all 24 process pairs. At 100,000 entries, median browsing time fell from 281 ms to 109 ms, and appending a new message fell from 13.8 ms to 7.8 ms. Opening the seeded panel rose from 33 ms to 74 ms. Streaming was slower at 20,000 and 50,000 entries and close at 100,000. These results support an opt-in for people who read long histories. The existing button is a better default for a tail-first workflow.

## Latency

Each cell gives median / p95 milliseconds. With eight opening samples per mode at each size, the nearest-rank p95 for opening is the largest observation.

| Operation | 20k button | 20k auto | 50k button | 50k auto | 100k button | 100k auto |
|---|---:|---:|---:|---:|---:|---:|
| Open seeded panel | 28.9 / 36.1 | 34.3 / 44.1 | 32.4 / 50.0 | 49.0 / 83.0 | 33.2 / 39.6 | 73.8 / 127.4 |
| Stream one chunk | 2.7 / 4.9 | 4.6 / 10.5 | 3.6 / 7.2 | 4.6 / 9.5 | 4.9 / 9.8 | 5.1 / 9.9 |
| Append one message while following | 7.8 / 24.6 | 4.8 / 24.1 | 8.2 / 16.7 | 4.7 / 10.2 | 13.8 / 20.7 | 7.8 / 12.8 |
| Resize panel | 4.9 / 8.6 | 6.2 / 10.1 | 8.1 / 12.0 | 7.7 / 10.8 | 7.5 / 11.3 | 6.8 / 12.0 |
| Half-page within recent history | 0.5 / 0.7 | 0.5 / 8.4 | 0.6 / 1.3 | 0.6 / 11.5 | 0.6 / 0.7 | 0.5 / 10.1 |
| Browse 300 older entries | 205.9 / 239.4 | 101.1 / 158.8 | 246.3 / 295.3 | 160.5 / 182.9 | 280.7 / 329.2 | 109.4 / 152.0 |
| Jump to canonical entry | 10.8 / 14.8 | 13.7 / 36.6 | 10.7 / 15.4 | 11.3 / 16.6 | 18.6 / 32.2 | 23.8 / 35.8 |
| Native Ctrl-B into older history | — | 3.0 / 12.4 | — | 3.2 / 9.2 | — | 4.0 / 29.2 |

A direct jump could already use Weave’s bounded 30-entry source navigation. The clear win came from reading successively older entries, where each button press retains another 30 components. Auto also avoids sliding the store’s 30-entry window on every followed append. A stream chunk updates the existing tail in both modes.

## Terminal traffic and memory

| Metric, median | 20k button | 20k auto | 50k button | 50k auto | 100k button | 100k auto |
|---|---:|---:|---:|---:|---:|---:|
| Terminal bytes per stream chunk | 29 | 29 | 29 | 29 | 29 | 29 |
| Terminal KiB to browse 300 older entries | 45.1 | 55.1 | 45.4 | 55.2 | 45.4 | 55.0 |
| Process RSS immediately after opening, MiB | 30.7 | 31.5 | 53.4 | 55.9 | 93.3 | 99.4 |
| Peak process RSS through matched operations, MiB | 65.4 | 64.5 | 102.7 | 102.7 | 182.9 | 176.7 |
| Native buffer rows on opening | 125 | 80,005 | 125 | 200,005 | 125 | 400,005 |

The native buffer still reserves about four physical lines per unseen entry in this fixture. That makes opening cost and initial memory grow with history size even though the rendered component count follows the viewport. During browsing, auto sent more terminal bytes for the 300-entry traversal. Overall peak RSS depends on the canonical history, Lua collections and allocator behavior as well as rendering.

All 24 pairs produced identical text and highlights on the last 12 rows after opening, streaming and resizing. On the final version, all 960 native Ctrl-B page turns settled with complete content and zero observed redraws containing placeholder rows. The 100k native-page p95 was 29.2 ms. This observation covers the scripted paging workload.

## What the comparison measures

Each mode ran in a fresh Neovim 0.12.3 TUI on Linux x86-64, attached to a 120 × 40 pseudoterminal. Weave opened its real panel with a 64 × 32 transcript viewport. Each size has eight process pairs. The order of the two modes alternated between pairs. The table pools individual operation samples within a size and mode. The 300-entry browsing result sums ten successive steps within each process before taking the median. The JSONL includes every timing, terminal byte count, render digest and memory reading.

The synthetic history repeats an eight-entry mix of two user prompts, four agent replies, a thought and a completed collapsed tool call. It includes variable-length paragraphs, links, inline code and fenced code. Thoughts and Markdown formatting were enabled. Each message has a unique marker. The fixture constructs the canonical entries, tool records and history index before the timer starts. Both panels open at the followed tail. The measurements exclude agent I/O, transcript ingestion from disk and Neovim startup.

- **Open** includes panel creation, initial layout, drawing and moving to the tail.
- **Stream** appends 20 short chunks to the generating agent at the tail. **Append** adds eight new settled messages with follow enabled. Both use normal store mutations. Weave copies its entries array on both paths.
- **Resize** toggles the pane width six times between 82 and 69 columns and checks the transcript's resulting width.
- **Half-page** moves within the initially available 30 entries. **Browse 300** visits ten successive targets, 30 entries further back each time. Button mode uses the store action invoked by the actual button, then scrolls to its first newly exposed entry. Auto mode moves the native window to the estimated row of that same entry. The benchmark verifies that the target is visible. This compares rendering costs and excludes the time a person spends finding or clicking a button.
- **Jump to entry** uses Weave's existing bounded source-navigation action for the middle, beginning and near-tail of the history. Both implementations render the target marker. The expander mode already has an efficient path for this operation.
- **Native history paging** sends 40 successive Ctrl-B inputs to the auto panel through Neovim's input queue. A decoration provider observes intermediate redraws for empty placeholder lines. Each settled viewport must be fully materialized. The button mode requires an expander action outside its tail range, so this specific operation has no direct button measurement.

Timings include the action and three event-loop/redraw turns. The driver measures terminal output between per-operation markers, including ANSI control sequences. This is a local PTY measurement. Network latency and terminal-emulator painting time are outside it. Peak memory is Linux process high-water RSS through the last matched operation, before the auto-only paging check. The last 12 buffer rows must match byte-for-byte across modes in all three snapshots, including normalized highlight ranges.

## Prototype scope

The Fibrous scroll-column owner supplies a height estimate, an ordered item count and a builder for the requested index range. The prototype keeps two viewport heights of overscan on either side and refreshes once a one-viewport margin is used up. A sparse prefix-sum index corrects estimates with measured item heights. Only mounted entries get component instances, layouts, cell grids and extmarks. Offscreen entries reserve empty native buffer lines so normal scrolling and the scrollbar work.

Native buffer search and multi-page yanks can miss text outside the mounted range. Cross-document operations should use canonical history and source IDs. Heights for unseen entries are estimates, and a single exceptionally tall message is still laid out and painted in full. Filtering huge contiguous runs of thoughts, fast mouse-wheel bursts, expanded tool output, live permission prompts and remote links were outside the performance fixture.

## Verification

The full native Neovim suites passed 817 Fibrous tests and 22 documentation tests. Weave passed 1,386 tests, including the three new viewport tests. The same 20 tests failed on the clean pinned revisions and on the prototype. They cover MCP envelopes and proxies, sandbox/tool wiring, recorded tool output, and a filesystem fixture that writes to `/tmp/w.lua`. These runs used the repository test runners directly. Nix was unavailable.

Fibrous's existing 200-entry transcript microbenchmark also ran with viewport rendering disabled against the clean revision and the prototype. These medians use twelve fresh processes per revision. The drawn cell counts matched for all operations.

| Default Fibrous path | Clean, ms | Prototype, ms |
|---|---:|---:|
| Full layout and paint | 5.580 | 5.774 |
| Mount and teardown | 12.879 | 12.389 |
| Append one entry | 0.456 | 0.497 |
| Grow streaming tail | 0.294 | 0.282 |
| Replace middle entry | 0.224 | 0.213 |

The largest default-path append difference was 0.041 ms in the twelve-run comparison. An earlier five-run comparison measured 0.497 ms clean and 0.486 ms on the prototype for the same append. Small timing differences on this microbenchmark varied across runs.

## Reproduce

Use adjacent checkouts of the prototype. Weave is based on `c20b59d` and Fibrous on `7b8a71b`. From the Weave checkout on Linux with Python 3 and Neovim available, run

```sh
FIBROUS_PATH="$PWD/../fibrous.nvim" NVIM_BIN="$(command -v nvim)" \
  python3 bench/visibility_compare.py --sizes 20000 50000 100000 --repeats 8 --output /tmp/visibility.jsonl
python3 bench/visibility_summary.py /tmp/visibility.jsonl
```

Enable the experiment in the matching Weave checkout with `require("weave").setup({ view = { content_visibility = "auto" } })`. The default remains `"button"`.

## Resize while reading an old entry

In both modes the cursor and top of the viewport started inside entry 1,006,
a long Markdown reply. Follow mode was off. We resized the actual Weave split
through a fixed sequence that changed the transcript width between 40 and 82
columns in a real Neovim TUI. At each transcript size, eight fresh processes per
mode performed ten width changes with a bounded 30-entry jump and ten more
after browsing ten earlier pages. In button mode those reveals retained 330
entries. Auto visited the equivalent older pages and then returned to the
target entry.

Each cell reports median / p95 milliseconds from requesting the width change
through redraw and event-loop settling. There were 80 resize samples per cell.

| Transcript entries | History opened | Button | Auto |
|---:|---|---:|---:|
| 20,000 | 30-entry window | 6.5 / 9.6 | 7.7 / 17.2 |
| 20,000 | After ten reveals | 35.3 / 71.5 | 7.1 / 15.1 |
| 100,000 | 30-entry window | 6.6 / 10.2 | 6.6 / 10.5 |
| 100,000 | After ten reveals | 41.3 / 120.2 | 8.9 / 14.0 |

All 640 width changes preserved the target entry under the cursor and at the
top of the viewport. The wrapped target text matched across modes after every
resize. No observed redraw exposed placeholder rows. The benchmark checked
the entry anchor and did not track the same word within rewrapped text.
It measured horizontal resizing.

Add `--history-resize` to the benchmark command and use
`--sizes 20000 100000` to reproduce this workload.

## Resize 20,034 entries behind the tail

In a 100,000-entry transcript the target was entry 79,966. The bounded case
used the normal direct jump to that entry. The expanded case set the same
store window that 667 successive “Show older” presses from the tail would
leave. This prepared the mounted tree in one commit before timing the resizes.
The benchmark measures resizing after the history was revealed. Setup and
scrolling time are outside the measurements.

Each mode ran in four fresh Neovim processes and performed four width changes
per case. Times below are median milliseconds with the observed range.

| Metric | Button | Auto |
|---|---:|---:|
| Resize after direct jump | 8.7 (6.1–14.5) | 9.3 (7.7–25.3) |
| Resize after expanding history | 2,257.7 (1,666.0–3,700.0) | 7.4 (5.7–15.6) |
| Entries in the realized range before expanded resizing | 20,040 | 40 |
| Process RSS before expanded resizing, MiB | 1,113 | 107 |
| Process peak RSS through expanded resizing, MiB | 2,048 | 115 |

All 64 width changes preserved the target entry at the cursor and at the top
of the viewport. Wrapped text matched across modes and no observed redraw
exposed placeholder rows.

Run the same benchmark with
`--history-resize --reveal-pages 667 --sizes 100000 --repeats 4`.

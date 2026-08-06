# CPU occlusion harness

`tests_v2/test_cpu_occlusion_throttle.py` measures how much CPU the app burns
with N busy terminal panes the user cannot see, versus the same panes when
they are visible. It is the first CPU measurement tool for the "lean and
speedy" workstream, and exists to establish a baseline for the occluded-render
throttle (renderer frame generation for occluded surfaces capped to ~4Hz
instead of redrawing on every PTY output burst; ghostty fork commit
`08bac45e9`, PR #265).

It is a measurement tool, not a regression gate: it never fails because CPU
was high, only on a harness/socket error. It is **not** part of the curated
CI subset (`tests_v2/ci_subset.txt`) that gates every PR — run it manually or
via `workflow_dispatch`.

## Running it

Point it at a tagged dev instance's socket (never the main/untagged socket —
the harness refuses):

```bash
./scripts/reload.sh --tag cpu-harness --launch
PROGRAMA_SOCKET_PATH=/tmp/programa-debug-cpu-harness.sock \
  python3 tests_v2/test_cpu_occlusion_throttle.py
```

Useful flags:

- `--scenario {all,hidden-busy,visible-busy,idle}` — default `all`
- `-n/--panes N` — number of busy panes (default 4)
- `--duration S` — sample window in seconds (default 30)
- `--busy-sleep-s S` — delay between busy-loop output lines, i.e. the
  simulated output rate (default 0.015s, roughly an agent's cadence)
- `--pid PID` — skip app-pid discovery and use this pid directly

## Scenarios

- **hidden-busy**: creates N workspaces, each with one pane running a
  continuous output loop, then selects a different workspace so all N are
  occluded. This is the scenario the throttle targets — agents running in
  panes nobody is looking at.
- **visible-busy**: the same N busy panes, but arranged as splits in one
  visible workspace (capped at 6 panes — a real window can't usefully show
  more). The control: this should read materially higher than hidden-busy if
  the throttle is doing its job.
- **idle**: N hidden, non-busy panes. Baseline.

## Methodology

Do not read this as "CPU %" from `ps -o %cpu` or Activity Monitor — that
figure is a decayed average since process start on macOS and will mislead
over a short sample window. Instead the harness samples **cumulative CPU
time** (`ps -o time=`, parsed as `HH:MM:SS.ss`) once at the start and once at
the end of the sample window and computes:

```
cpu_percent = (cpu_time_delta / wall_time_delta) * 100
```

That is exact and comparable across runs and scenarios. It reports the app
process's own figure (`app_cpu_pct`) and the total across the app plus its
PTY/shell descendant processes captured at the start of the window
(`total_cpu_pct`). Very short-lived processes spawned mid-window (e.g. each
loop iteration's `sleep`) are not individually tracked — their own CPU cost
is real but tiny, and does not land on a parent's `ps` TIME field. The
renderer/PTY-processing cost this harness targets is charged to the app's
own pid, which is captured in full.

**A single run is noisy.** Compare medians of 3+ runs before drawing a
conclusion, the same way `docs/testing-layout.md`'s perf harnesses do.

## Output

A small table (scenario, effective pane count, duration, `app_cpu_pct`,
`total_cpu_pct`) followed by one machine-readable JSON line so CI can diff
results across runs:

```json
{"app_pid":1234,"scenarios":[{"scenario":"hidden-busy","requested_panes":4,"effective_panes":4,"duration_s":30.0,"wall_s":30.02,"app_cpu_pct":3.1,"total_cpu_pct":4.0,"tracked_pids":5,"notes":[]}, ...]}
```

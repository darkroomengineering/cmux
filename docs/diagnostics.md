# Diagnostics log

Programa keeps a small, always-on, local-only diagnostics log so real bug reports (e.g.
"sockets keep disconnecting") come with evidence, even from a Release build where the
Debug-only event log (`DebugEventLog` / `dlog`, see `CLAUDE.md` "Debug event log") isn't
compiled in.

**Nothing in this log ever leaves the machine.** It is a plain local file append — no
network calls, no telemetry service, no analytics SDK. There is no settings toggle for it;
it is always on at error/warning level by design (narrow surface area, nothing to configure).

## Log path

Default location:

```
~/Library/Logs/Programa/diagnostics.log
```

Override with the `PROGRAMA_DIAGNOSTICS_LOG` environment variable (useful for tagged dev
builds that want a per-tag path, same convention as `PROGRAMA_DEBUG_LOG`):

```bash
PROGRAMA_DIAGNOSTICS_LOG=/tmp/programa-diagnostics-my-tag.log ./scripts/reload.sh --tag my-tag --launch
```

## Rotation

The file is capped at 2 MB. When a write would push it over the cap, the current file is
rotated to `diagnostics.log.1` (overwriting any previous `.1`) and a fresh file is started.
At most 4 MB of diagnostics data is ever kept on disk.

## Tailing

```bash
tail -f ~/Library/Logs/Programa/diagnostics.log
```

## What gets logged

Currently: the Unix socket/control-protocol subsystem (`Sources/TerminalController.swift`,
`Sources/TerminalController+Subscriptions.swift`) — listener start/stop, accept-loop errors
and rearm/resume events, per-connection open/close (with a close reason: `eof`, `read_error`,
`access_denied`, `listener_stopped`, ...), and event-subscription teardown. Log lines look
like:

```
2026-08-04T18:22:10.123Z socket.conn open pid=41213
2026-08-04T18:22:11.402Z socket.conn close pid=41213 reason=eof durationMs=1279
```

The facility itself (`DiagnosticsLog` / `dilog(_:_:)` in
`vendor/bonsplit/Sources/Bonsplit/Public/DiagnosticsLog.swift`) is generic — any subsystem
can call `dilog("category", "message")` from any thread without blocking. It intentionally
has no log-level enum or category registry; category is just a free-form string prefix.

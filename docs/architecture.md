# Architecture

## Overview

Jane is a single binary with three main jobs:

1. **Info**: print a snapshot of the host (OS, kernel, CPU, memory, uptime).
2. **Status**: load the config, run every configured check once, and print the results as a table.
3. **Daemon**: run the checks in a loop every `cycle` seconds. Each cycle's results go either to a Jane HQ server or to the local email alerter.


## Source layout

| File | Responsibility |
|---|---|
| `src/jane.cr` | Entry point. Parses `ARGV`, dispatches to a mode, and handles the `monitor`/`unmonitor` subcommands. Any uncaught exception is printed as `Error running Jane: <message>`. |
| `src/config.cr` | The typed config objects (`Config`, `CheckConfig`, `CPUCheck`, `Threshold`, rules, …) and `Config.load`. |
| `src/conf/` | The control file parser: `lexer.cr` (tokens), `parser.cr` (syntax tree, includes) and `builder.cr` (syntax tree → config objects, warnings). |
| `src/rules/` | The rule engine (`engine.cr`: cycle windows, actions), `scheduler.cr` (`every N cycles`), `policy.cr` and `shell.cr` (commands with a timeout). |
| `src/monitor.cr` | Defines `Monitor::Check` (one result row). `perform_checks` runs every configured check, and `display_status` renders the status table. |
| `src/utils/cpu.cr` | CPU usage, IO wait, load average (`/proc/stat`, `/proc/loadavg`, `/proc/cpuinfo`). |
| `src/utils/memory.cr` | Memory and swap usage (`/proc/meminfo`). |
| `src/utils/filesystem.cr` | Filesystem space, inodes and mount flags, using `stat -f` (with a timeout) and `/proc/self/mounts`. |
| `src/utils/network.cr` | Interface state (`/sys/class/net`), TCP connection checks, and `iperf3` bandwidth checks. |
| `src/utils/process.cr` | Checks whether a process is running, by `/proc/*/cmdline` match or by pidfile, and its resource tests (via `proctable.cr`). |
| `src/utils/file.cr` | File, directory and fifo checks: existence, owner, group, mode, timestamps, size, checksum; content via `content.cr`. |
| `src/utils/generate.cr` | Prints a starter control file for the host (`jane -g`). |
| `src/info.cr` | Host info table (`jane -i`) and the `Metrics` struct sent to HQ. |
| `src/daemon.cr` | The daemon loops (HQ and standalone alert) and serialization for HQ. |
| `src/alert.cr` | `Alerter`, which sends an email on ok → alert transitions (and when a multi-level check climbs a level) using a minimal built-in SMTP client. |
| `src/state.cr` | Reads and writes `state.json` (the list of unmonitored tags). |
| `src/logger.cr` | Wraps Crystal's `Log` with a configurable level and destination. |

## The check cycle

Every mode that evaluates checks runs the same path:

1. **Load config.** `Config.from_file(path)` lexes and parses the control file, following `include` statements, and builds the config objects. Warnings are printed with their file and line. On an error, Jane aborts with `Error parsing config file: …`.
2. **Run checks.** `Monitor.perform_checks(config)` walks the check types in a fixed order: CPU → memory → filesystems → network interfaces → network connections → bandwidth → processes → files. Each util module returns an `Array(Monitor::Check)`. The tags from the check's config block are appended to every result it produces.
3. **Filter unmonitored.** The list of unmonitored tags is read from `state.json`. Any result that carries one of those tags is dropped. The status table lists those results separately.
4. **Output.** The results are rendered as a table (`-s`), sent to HQ, or passed to the alerter (`-d`).

Checks run **sequentially in a single fiber**. A slow check delays the ones after it, for example a connection timing out or a long `iperf3` run. In daemon mode the actual interval is therefore `cycle` seconds of sleep *plus* the time the checks took.

## The `Monitor::Check` result

Every check produces one or more of these (it is also the JSON shape sent to HQ):

| Field | Meaning |
|---|---|
| `name` | Display name, e.g. `CPU Usage`, `Filesystem root`, `Process sshd` |
| `status` | `"ok"` or `"alert"` |
| `current` | The measured value, formatted as a string |
| `threshold` | The configured limit or expected value, formatted as a string |
| `message` | A human-readable explanation |
| `tags` | Tags from the check's config block |
| `description` | Optional free-text `name` from the config (network and process checks) |

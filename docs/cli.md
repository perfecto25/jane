# Command line

```
jane [options]
jane monitor   [tags] [-c FILE]
jane unmonitor [tags] [-c FILE]
```

## Options

| Flag | Mode |
|---|---|
| *(none)*, `-i`, `--info` | Print host information: hostname, OS, kernel, uptime, CPU, memory, swap and Jane version. Does not read the config. |
| `-s`, `--status` | Load the config, run every check once, and print a status table. |
| `-d`, `--daemon` | Run the checks in a loop. See [Daemon and alerting](daemon.md). |
| `-g`, `--generate` | Print a starter control file for this host to stdout: system limits, a filesystem check for every mounted disk, and sshd. Redirect it to a file: `jane -g > jane.conf`. |
| `-t`, `--test` | Load the config, print any warnings, and report `Control file syntax OK` (exit 0) or the error with its file and line (exit 1). Like `monit -t`. |
| `-c FILE`, `--config=FILE` | [Control file](control-file.md) path. Default: `jane.conf` in the current directory. `.toml` files are rejected: TOML configs are no longer supported. |
| `-h`, `--help` | Show usage. |
| `-v`, `--version` | Print the version (read from `shard.yml` at build time) and exit. |

If more than one mode flag is given, the last one wins.

## Status output

`jane -s` prints one table row per check result:

```
Check | Status | Current | Threshold | Message | Tags
```

- Rows in `alert` state are sorted to the top and printed in red.
- The table fits the terminal width (or `$COLUMNS` when output is piped; no limit if neither is known). When it's too wide, the Tags column shrinks first, then Message and Check, and their text wraps onto continuation lines. Current and Threshold shrink only as a last resort, and Status never does. Below about 80 columns the columns stop shrinking and the table is wider than the terminal.
- When nothing wraps, rows are printed without separator lines. When something wraps, a separator follows each check so its continuation lines stay grouped.
- A summary line follows: `⚠  N alert(s) detected` or `✔  All checks passed`.
- If any tags are unmonitored, an **Unmonitored Services** table lists the checks being skipped.

## `monitor` / `unmonitor` subcommands

These subcommands temporarily silence checks by tag without editing the config. A tag is anything set with `group <name>[, <name>]` on a check. See [Configuration › Tags](configuration.md#tags).

| Command | Effect |
|---|---|
| `jane unmonitor` | Unmonitor **every** tag found in the config. |
| `jane unmonitor cpu,memory` | Unmonitor only the listed tags (comma-separated). |
| `jane monitor` | Re-monitor everything that is currently unmonitored. |
| `jane monitor cpu,memory` | Re-monitor only the listed tags. |

Notes:

- The subcommand must come first. `-c FILE` can appear after it, e.g. `jane unmonitor -c /etc/jane/jane.conf`. If the argument after the subcommand starts with `-`, it is treated as a flag rather than a tag list.
- Unmonitored tags are stored in `state.json`, in the **same directory as the config file**. They persist across restarts. A running daemon re-reads this file every cycle, so changes take effect without a restart.
- `unmonitor` with a tag that no check uses prints `No checks found with tag '<tag>'` and does not change the state.
- `monitor` with a tag that isn't unmonitored prints `Tag '<tag>' is already monitored`.
- A check with several tags is skipped if *any* of its tags is unmonitored.
- Checks without a tag can't be unmonitored.

Example:

```sh
$ jane unmonitor process
These services will be unmonitored:
  - Process sshd

To monitor them again, run: jane monitor process
```

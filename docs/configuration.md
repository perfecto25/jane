# Configuration

Jane is configured with one Monit-style control file. The default is `jane.conf` in the current directory; use `-c FILE` for another path. Run `jane -g > jane.conf` to get a starter file for the host, `jane -t` to check it, and `jane -l` to lint its layout (`jane -l --fix` repairs it).

This page covers the global settings, tags and include files. [Control file](control-file.md) covers the syntax and rules, and [Checks](checks.md) has an example of every check type.

```
set cycle 10
set log /var/log/jane.log level info
set hq hq.example.com port 25900
set mailserver smtp.example.com port 25
set alert ops@example.com cc oncall@example.com
include /etc/jane/conf.d/*.conf

check system myhost
    if memory usage > 85, 90, 95 % then alert
    group sys
```

> TOML configs (`config.toml`) are no longer supported. Loading a `.toml` file fails with a message saying so.

## Settings

All settings are optional.

| Statement | Default | Meaning |
|---|---|---|
| `set cycle <seconds>` | `10` | Seconds between daemon cycles (minimum 2). Also the default timeout for network checks and programs. Monit's `set daemon <seconds>` still works, with a deprecation warning. |
| `set log syslog [level <level>]` | syslog, `info` | Log to stdout (see note) |
| `set log <file> [level <level>]` | | Log to a file. Levels: `debug`, `info`, `warn`, `error`, `fatal`. |
| `set hq <host> [port <n>]` | off; port `80` | Send results to a Jane HQ server. With HQ set, the agent sends no email. See [Daemon and alerting](daemon.md). |
| `set mailserver <host> [port <n>]` | port `25` | SMTP server for alert emails (used when HQ is not set) |
| `set alert <email> [cc <email>]` | | Who gets alert emails. A second `set alert` line becomes the cc. One recipient plus one cc are supported. |
| `include <glob>` | | Parse the matching files (see [Include files](#include-files)) |

The daemon needs either `set hq` or both `set mailserver` and `set alert`. It exits at startup otherwise.

> `set log syslog` currently writes to **stdout**, not to the system syslog. Under systemd, stdout ends up in the journal.

Other monitrc settings (`set httpd`, `set eventqueue`, `set idfile`, `set mail-format`, …) are skipped with a warning. The sender address is always `jane@<hostname>`.

## Tags

`group <name>[, <name>]` (or `tag ...`) on a check attaches tags to every result the check produces:

```
check process sshd matching "/usr/sbin/sshd"
    group process

check bandwidth atlas with address atlas
    if bandwidth < 20 Mbps then alert
    group trading, network
```

Tags are used for:

- the **Tags** column in `jane -s`,
- `jane monitor` / `jane unmonitor` (see [CLI](cli.md#monitor--unmonitor-subcommands)),
- the `tags` field sent to HQ.

All results of `check system` share its tags, so `jane unmonitor sys` silences CPU, load, memory and swap together.

## Include files

`include <glob>` parses every matching file in sorted order, as if its text were pasted at that point. Relative patterns are relative to the including file. Included files can hold checks and settings, and can include other files.

```
# /etc/jane/jane.conf
set cycle 10
include /etc/jane/conf.d/*.conf

# /etc/jane/conf.d/web.conf
check process nginx with pidfile /var/run/nginx.pid
    group web
```

- **Unique names:** a check name defined twice, in the same file or across includes, is an error.
- **Errors:** a parse error in an included file is reported with that file's name and line, and loading fails.
- **No match:** a pattern that matches nothing is not an error.

## Thresholds

Limits take a unit: `%`, or a size in `b`, `kb`, `mb`, `gb`, `tb`, `pb` (1024-based). Units are case-insensitive, and can be attached (`5GB`) or separate (`5 GB`). A list such as `> 80, 90, 95 %` gives several levels of one check. It is shown as **one row**: the highest level in alert, or the lowest level when none alerts. An email is sent when the check enters alert and again each time it climbs a level. See [Control file › Threshold lists](control-file.md#threshold-lists).

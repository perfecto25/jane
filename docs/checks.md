# Checks

Each check type below has a [control file](control-file.md) example. [Configuration](configuration.md) covers the global settings (`set cycle`, `set hq`, …), tags and include files.

| Type | Control file | Result name(s) |
|---|---|---|
| [System](#system-cpu-load-memory-swap) | `check system <name>` | `CPU Usage`, `CPU IO Wait`, `Load Avg (1min/5min/15min)`, `Load Avg (…) per core`, `Memory Usage`, `Swap Usage` |
| [Filesystem](#filesystem) | `check filesystem <name> with path <mount>` | `Filesystem <name>`, plus one row per extra test |
| [Network interface](#network-interface) | `check network <name> with interface <iface>` | `Network Interface <name> (<iface>)` |
| [Host / port](#host-and-port) | `check host <name> with address <host>` | `Network Connection <name>`, or `<name>:<port>` for several ports |
| [Bandwidth](#bandwidth) | `check bandwidth <name> with address <host>` | `Bandwidth <name>` |
| [Process](#process) | `check process <name> matching "<pattern>"` / `with pidfile <path>` | `Process <name>`, plus one row per resource test |
| [Program](#program) | `check program <name> with path "<command>"` | `Program <name>` |
| [File](#file) | `check file <name> with path <path>` | `File <name>`, plus `… user`, `… group`, `… mode` and one row per test |
| [Directory](#directory-and-fifo) | `check directory <name> with path <path>` | `Directory <name>`, … |
| [Fifo](#directory-and-fifo) | `check fifo <name> with path <path>` | `Fifo <name>`, … |

Every check can carry tags, used by `jane monitor` / `jane unmonitor` and sent to HQ: `group <name>[, <name>]` (see [Configuration › Tags](configuration.md#tags)). Any rule can also use `for N cycles`, `N times within M cycles`, `then exec "<cmd>"` and `every N cycles` (see [Control file › Rules](control-file.md#rules)).

A threshold list (`> 80, 90, 95 %`) is shown as **one row**: the highest level in alert, or the lowest level when none alerts. Each level keeps its own cycles and action, and an email is sent each time the check climbs a level.

---

## System: CPU, load, memory, swap

```
check system myhost
    if cpu usage > 80, 90 % then alert
    if cpu (wait) > 20% for 3 cycles then alert
    if loadavg (1min) > 8 then alert
    if loadavg (5min) per core > 1.5 then alert
    if memory usage > 85, 90, 95 % then alert
    if memory usage > 30 GB then exec "/usr/local/bin/top-mem.sh"
    if swap usage > 25% then alert
    group sys
```

| Test | Measures | Units |
|---|---|---|
| `cpu` / `cpu usage` | Non-idle CPU %, sampled from `/proc/stat` over 100 ms | % only |
| `cpu (wait)` / `iowait` | IO wait %, sampled the same way | % only |
| `loadavg (1min\|5min\|15min)` | Load average from `/proc/loadavg` (default `1min`) | number |
| `loadavg (…) per core` | The same load divided by the number of online CPUs | number |
| `memory` / `memory usage` | `MemTotal − MemAvailable` from `/proc/meminfo` (on old kernels, `MemFree + Buffers + Cached`) | % or size |
| `swap` / `swap usage` | `SwapTotal − SwapFree` | % or size |

All tests alert when the value is **above** the limit (`>`). Only one `check system` is allowed.

- **Per-core load:** one limit fits hosts of every size. A load of 8 is saturation on 4 CPUs but light on 32. The per-core row shows the divided value, and its alert message names the CPU count.
- **No swap:** `Swap Usage` shows `n/a` and stays OK on a host without swap.

## Filesystem

```
check filesystem root with path /
    if space usage > 80, 90, 95 % then alert

check filesystem data with path /dev/sdb1          # a mount point or a mounted device
    if space usage > 500 GB then alert
    if space free < 10 GB for 2 cycles then alert
    if inode usage > 90% then alert
    if inode free < 5000 then alert
    if changed fsflags then exec "/usr/local/bin/notify-ro.sh"
    group storage
```

| Test | Meaning |
|---|---|
| `space usage > <% or size>` | Used space, as a % of the filesystem size or in bytes |
| `space free <op> <% or size>` | Space available to non-root users, like `df`'s "Avail" |
| `inode usage <op> <% or count>` | Used inodes |
| `inode free <op> <% or count>` | Free inodes |
| `changed fsflags` | Fires in the cycle the mount options change, e.g. `rw` → `ro` after disk errors |

Usage is read with `stat -f` with a timeout of one cycle minus 1 second, so a hung network mount alerts (`did not respond within Ns`) instead of freezing Jane.

- **Missing path:** alerts with `missing`.
- **Not a mount point:** alerts with `not mounted`, as in Monit, instead of quietly reporting the filesystem underneath.
- **No inode counts:** filesystems that don't count inodes (btrfs, vfat, …) show inode tests as `n/a`.

## Network interface

```
check network bond0 with interface bond0
    if link down for 2 cycles then alert
    group network
```

Reads `/sys/class/net/<interface>/operstate`. `up` is OK. Any other state (`down`, `unknown`, …), or a missing interface, is an alert. The check always runs; the optional `if link down` rule only adds cycles or an action.

## Host and port

```
check host db with address 10.0.0.5
    if failed port 5432 for 2 cycles then alert
    if failed port 22 expect "^SSH-" then alert
    group db

check host web with address www.example.com
    if failed port 443 protocol https request "/health"
       and status = 200 and content = "ok"
       and certificate valid > 30 days
       with timeout 5 seconds then alert
    if failed port 80 protocol http status < 500 then alert
```

Each `if failed port` rule opens a TCP connection; DNS and connect use a timeout of one cycle minus 1 second unless `timeout` is given. With one rule the result is `Network Connection db`. With several rules the results are `db:5432`, `db:22`, and so on.

- **`expect "<regex>"`:** the first line the server sends must match. Useful for banners such as SSH and SMTP.
- **HTTP/TLS:** `protocol http`/`https`, `request`, `hostheader`, `status`, `content`, `certificate valid > N days` and `ssl options {verify: enable}`. See [Control file › Port checks](control-file.md#port-checks) for every option.

## Bandwidth

```
check bandwidth atlas with address atlas port 5201   # port is optional, default 5201
    if bandwidth < 20 Mbps for 3 cycles then alert
    group trading, network
```

Jane-only (Monit has no equivalent). Runs `iperf3 -c <address> -p <port> -t <duration> -J` and reads `end.sum_sent.bits_per_second`. The duration is the cycle minus 2 seconds, minimum 1. Needs `iperf3` locally and `iperf3 -s` running on the remote host.

- **Alerts when below the limit,** unlike the other checks, which alert when above.
- **No limit:** the measurement is reported as OK.
- **Failed run:** an alert is also raised if `iperf3` is missing or the run fails.

## Process

```
check process sshd matching "/usr/sbin/sshd -D"
    group ssh

check process nginx with pidfile /var/run/nginx.pid
    start program = "/bin/systemctl start nginx"
    stop program  = "/bin/systemctl stop nginx"
    if not exist for 2 cycles then restart
    if failed port 80 protocol http then restart
    if total cpu > 80% for 5 cycles then alert
    if total memory > 2 GB then alert
    if children > 200 then alert
    if total disk write > 50 MB/s for 3 cycles then alert
    if uptime < 3 minutes then alert
    if changed pid then exec "/usr/local/bin/notify-restart.sh nginx"
```

| Selector | How it decides "running" |
|---|---|
| `matching "<pattern>"` | Some process's command line (`/proc/<pid>/cmdline`, NULs replaced by spaces) matches. The pattern is tried as a **substring**, a **glob** (`*`, `?`, whole line) and a **regex** (unanchored), and any hit counts. If several processes match, the oldest is used, as in Monit. |
| `with pidfile <path>` | The pidfile exists, holds an integer, and `/proc/<pid>` exists |

The process not running is an alert. `if not exist` only adds cycles or an action such as `restart`, which runs `stop program` and then `start program`.

**Resource tests**, which run while the process is running: `cpu`, `total cpu`, `memory`, `total memory`, `threads`, `children`, `uptime`, `disk read`/`write` (bytes or operations per second), `changed pid`/`ppid`, and port tests (`failed port <n>` against localhost, or `failed host <addr> port <n>`). See [Control file › Process tests](control-file.md#process-tests).

## Program

```
check program backup with path "/usr/local/bin/check-backup.sh --verbose"
    with timeout 60 seconds
    every 30 cycles
    if status != 0 then alert
    if content = "WARN|ERROR" then alert
    group backup

check program queue with path "redis-cli llen jobs"
    if content != "^[0-9]{1,3}$" for 3 cycles then alert   # more than 999 jobs queued
```

Runs the command through `/bin/sh` each time the check is evaluated. It's killed after `timeout` seconds, or after one cycle by default, and that is an alert (`timed out`).

| Test | Meaning |
|---|---|
| `status <op> <n>` | Exit status, e.g. `status != 0`, `status > 1` |
| `content = "<regex>"` / `content != "<regex>"` | stdout+stderr must not / must match |

Without rules the program just runs and the result shows its exit status and first line of output. Use `every N cycles` for slow commands.

## File

```
check file hosts with path /etc/hosts
    if failed uid root then alert
    if failed gid root then alert
    if failed permission 644 then alert
    if changed sha256 checksum then alert

check file heartbeat with path /var/run/app/heartbeat
    if modify timestamp > 5 minutes for 2 cycles then alert

check file applog with path /var/log/app.log
    if size > 2 GB then exec "/usr/sbin/logrotate -f /etc/logrotate.d/app"
    if content = "FATAL|panic:" then alert
```

- **`File <name>`** alerts if nothing exists at the path, or if it isn't a regular file. Then the other tests are skipped.
- **`failed uid <user>`:** the owner is not that user.
- **`failed gid <group>`:** the group is not that group.
- **`failed permission <octal>`:** the permission bits differ. The comparison is exact, so write `644` (or `4755` with setuid), not `0644`.

**Other tests:** the `timestamp` / `modify` / `change` / `access timestamp` age tests, `size`, `checksum` (md5, sha1, sha256), `changed …`, and `content = "<regex>"`, which follows the file like `tail -f` and only looks at new lines. See [Control file › File, directory and fifo tests](control-file.md#file-directory-and-fifo-tests) and [File content](control-file.md#file-content).

## Directory and fifo

```
check directory spool with path /var/spool/app
    if failed uid app then alert
    if failed permission 750 then alert
    if timestamp > 1 hour then alert       # nothing written for an hour

check fifo events with path /run/app/events.fifo
    if failed gid app then alert
    if changed modify timestamp then alert
```

Like `check file`, but the path must be a directory or a named pipe. Anything else at the path, or nothing, is an alert. The owner, group, permission and timestamp tests work the same. Size, checksum and content tests are only for `check file`.

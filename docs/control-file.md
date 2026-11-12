# Control file (Monit-style config)

Jane is configured with a Monit-style control file (default `jane.conf`, or `-c FILE`):

```sh
jane -t -c /etc/jane/jane.conf   # check the syntax
jane -l /etc/jane/jane.conf      # lint syntax and layout (add --fix to repair the layout)
jane -s -c /etc/jane/jane.conf   # run the checks once
```

Most existing monitrc check blocks parse unchanged. Anything Jane can't act on yet is reported as a warning with its file and line, and never silently dropped (see [Not supported yet](#not-supported-yet)).

## Example

```
set cycle 10
set log syslog level info
set hq hq.example.com port 25900
set mailserver smtp.example.com port 25
set alert ops@example.com cc oncall@example.com
include /etc/jane/conf.d/*.conf

check system phoebe
    if cpu usage > 90% then alert
    if cpu (wait) > 20% then alert
    if loadavg (5min) > 8, 16 then alert
    if loadavg (1min) per core > 2 then alert
    if memory usage > 85, 90, 95 % then alert
    if swap usage > 25 % then alert
    group sys

check filesystem phoebe-/ with path /
    if space usage > 75, 80, 85, 90, 95 % then alert

check file hosts with path /etc/hosts
    if failed uid root then alert
    if failed permission 644 then alert

check process redir matching "/usr/bin/redir"
check process nginx with pidfile /var/run/nginx.pid

check host db with address 10.0.0.5
    if failed port 5432 then alert

check network bond0 with interface bond0

check bandwidth atlas with address atlas port 5201
    if bandwidth < 20 Mbps then alert
```

## Syntax

- Line breaks don't matter. A statement starts with `check`, `set`, `include` or `if`. `;` can separate statements on one line:
  `check file kernel-error with path /var/log/messages; if content = "kernel: BUG" then alert`
- `#` starts a comment that runs to the end of the line.
- Values can be bare (`/var/log/messages`, `root-/`) or quoted (`"a value with spaces"`). Inside quotes, only `\"` (or `\'`) and `\\` are escapes. Every other backslash is kept, so regexes work as written: `matching ".*myapp\.sh"`, `content = "\[error\]"`.
- The filler words `with`, `using`, `and`, `is`, `than` and `the` are optional.
- Comparisons: `>` `>=` `<` `<=` `=` `==` `!=` `<>`, or `gt` `ge` `lt` `le` `eq` `ne`.
- Units: `%`, `b` `kb` `mb` `gb` `tb` `pb` (1024-based), `bps` `kbps` `mbps` `gbps`. Units are case-insensitive and can be attached (`5GB`) or separate (`5 GB`).

### Threshold lists

Instead of repeating a rule for each level, list the levels:

```
if space usage > 75, 80, 85 % then alert      # same as 75%, 80%, 85%
```

The levels are shown as one row per check. The row shows the highest level in alert, e.g. `if memory usage > 100, 200, 300 MB` with 150 MB used shows `Memory Usage` with threshold `100 MB`, and with 1 GB used, threshold `300 MB`. When no level alerts, the row shows the lowest level (the next one to trip). Separate rules on the same test are merged the same way, and percent and size levels on the same test are shown as two rows (`Memory Usage (%)`, `Memory Usage (size)`).

Internally each level is still evaluated on its own, with its own `for N cycles` window and action, so `if memory usage > 95% then exec "..."` runs only when the 95% level fires. An email is sent when the check enters alert and again each time it climbs to a higher level.

### Rules

```
if <test> [<op> <values>] [for N cycles | [for] N times within M cycles] then <action> [else if succeeded then <action>]
```

Actions:

| Action | What happens |
|---|---|
| `alert` | The result goes into alert (email/HQ). `warn` is the same for now. |
| `exec "<command>"` | Alerts, and runs the command through `/bin/sh`. Add `repeat every N cycles` to run it again while the rule keeps failing. |
| `restart`, `start`, `stop` | Alerts, and runs the service's `stop program` then `start program` (restart), or just one of them. The program must be defined in the check, otherwise it's a config error. |
| `else if succeeded then exec "<command>"` | Runs the command when the rule recovers. |

Commands run in the background, one after another, with a 60 second timeout, and their result is logged. The `as uid` / `as gid` options are accepted but ignored: commands run as the Jane user.

### Cycles

| Rule | Alerts when |
|---|---|
| *(none)* | the test fails once |
| `for 3 cycles` | the test failed in each of the last 3 evaluations |
| `2 times within 30 cycles` | the test failed in at least 2 of the last 30 evaluations |

Until then the result is shown as `ok` with the count in its message, e.g. `(1 of 2 failures, 2 times within 30 cycles; not alerting yet)`. A result stays in alert until fewer than the required number of failures are left in the window. For `for N cycles` that's the first passing cycle. For `2 times within 30 cycles` it can take up to 30 cycles, so a noisy log line alerts once rather than every time it repeats.

Cycles count evaluations of the check, so a check with `every 15 cycles` and `for 2 cycles` needs 2 failed runs, which is 30 daemon cycles.

`jane -s` runs every check once and shows the raw result. It ignores `every` and cycle windows, and runs no actions.

### Service options

| Option | Meaning |
|---|---|
| `group <name>[, <name>]` or `tag ...` | Tags, used by `jane monitor` / `jane unmonitor` and sent to HQ |
| `every N cycles` | Run the check on the first cycle and then every Nth cycle. In between, its last result is reused. |
| `depends on <service>` | Dependency on another service |
| `start program = "<cmd>"`, `stop program = "<cmd>"` | Commands used by the `start`, `stop` and `restart` actions |
| `with timeout N seconds` | `check program` only: kill the program after N seconds (default: the daemon cycle) |

## Check types and supported tests

[Checks](checks.md) has a worked example of every check type.

| Check | Source | Tests Jane runs today |
|---|---|---|
| `check system <name>` | — | `cpu` / `cpu usage` > %, `cpu (wait)` / `iowait` > %, `loadavg (1min\|5min\|15min)` > n, `loadavg (…) per core` > n (load ÷ online CPUs), `memory` / `memory usage` > % or size, `swap` / `swap usage` > % or size (`n/a` without swap) |
| `check filesystem <name>` | `with path <mount point or device>` | `space usage` > % or size; `space free`, `inode usage`, `inode free`, `changed fsflags` (see below) |
| `check file <name>` | `with path <path>` | always checks that a regular file exists at the path; `failed uid <user>`, `failed gid <group>`, `failed permission <octal>`; timestamp, size and checksum tests; `content = "<regex>"` / `content != "<regex>"` (see below) |
| `check directory <name>` | `with path <path>` | always checks that a directory exists; owner, group, permission and timestamp tests |
| `check fifo <name>` | `with path <path>` | always checks that a named pipe exists; owner, group, permission and timestamp tests |
| `check process <name>` | `matching "<pattern>"` or `with pidfile <path>` | always checks that the process is running (`matching` works as described in [Checks › Process](checks.md#process)); resource tests below |
| `check program <name>` | `with path "<command>"` | `status <op> <n>` on the exit code; `content = "<regex>"` / `content != "<regex>"` on stdout+stderr. Without rules it just runs. |
| `check host <name>` | `with address <host>` | `failed port <n> [type tcp] [expect "<regex>"]`, one TCP connection check per port (named `<name>:<port>` when there are several) |
| `check network <name>` | `with interface <iface>` | always checks that the link is up |
| `check bandwidth <name>` (Jane only) | `with address <host> [port <n>]` | `bandwidth < <n> Mbps` via iperf3 (default port 5201) |

Only one `check system` is allowed. Service names must be unique.

### Filesystem tests

```
check filesystem data with path /data              # a mount point, or a device such as /dev/sdb1
    if space usage > 80, 90, 95 % then alert
    if space free < 10 GB then alert
    if inode usage > 90% then alert
    if inode free < 5000 then alert
    if changed fsflags then alert                  # e.g. remounted read-only after disk errors
```

| Test | Meaning |
|---|---|
| `space usage <op> <% or size>` | Used space (`> ` only), as a % of the filesystem size or in bytes |
| `space free <op> <% or size>` | Space available to non-root users, like `df`'s "Avail" |
| `inode usage <op> <% or count>` | Used inodes |
| `inode free <op> <% or count>` | Free inodes |
| `changed fsflags` | Fires in the cycle the mount options change, e.g. `rw` → `ro` |

As in Monit, the path must be a mount point (or a mounted device). If it isn't, the check alerts with `not mounted` instead of quietly reporting the filesystem underneath it, and a missing path alerts with `missing`. Then no other results are produced for that cycle. Filesystems that don't count inodes (btrfs, vfat, …) show inode tests as `n/a`.

Usage is read with `stat -f` with a timeout of one cycle minus 1 second, so a hung network mount alerts (`did not respond within Ns`) instead of freezing Jane.

### Process tests

These run only while the process is running. If several processes match `matching`, Jane uses the oldest one, as Monit does.

```
check process app matching "/usr/bin/app"
    start program = "/bin/systemctl start app"
    stop program  = "/bin/systemctl stop app"
    if not exist for 2 cycles then restart
    if cpu > 80% for 5 cycles then alert
    if total memory > 2 GB then alert
    if threads > 500 then alert
    if children > 20 then alert
    if uptime < 3 minutes then alert
    if total disk write > 50 MB/s for 3 cycles then alert
    if disk read > 500 operations/s then alert
    if changed pid then alert
    if failed port 8080 then restart
    if failed host 10.0.0.5 port 22 expect "^SSH-" then alert
```

| Test | Measures |
|---|---|
| `cpu` | CPU used by the process since the previous cycle, as a % of the whole machine (100% = every core busy). The first measurement (and `jane -s`) samples over 100 ms. |
| `total cpu` | The same, for the process plus all of its descendants |
| `memory` | Resident memory (RSS), as a size or a % of RAM |
| `total memory` | RSS of the process plus all of its descendants |
| `threads` | Number of threads |
| `children` | Number of descendants (children, grandchildren, …) |
| `uptime` | Time since the process started; units `s`, `min`/`m`, `hours`/`h`, `days`/`d` |
| `disk read`, `disk write` | Disk I/O rate since the previous cycle, as bytes (`10 MB/s`) or read/write calls (`500 operations/s`, also `ops`). The period can be `/s`, `/min`, `/h` or `/day`; it's converted to per second. `rate` is optional (`disk read rate`). |
| `total disk read`, `total disk write` | The same, for the process plus all of its descendants |
| `changed pid`, `changed ppid` | Fires in the cycle the PID (a restart) or the parent PID changes. The next cycle is ok again. |
| `failed port <n>` | TCP connection to `localhost:<n>`; `failed host <addr> port <n>` for another address |

Disk bytes are what actually reached storage (`read_bytes` / `write_bytes` in `/proc/<pid>/io`). Reads served from the page cache and writes to tmpfs don't count. Operations count every read/write call, including on pipes and sockets. Reading another user's `/proc/<pid>/io` needs root, so when Jane runs as a normal user, disk tests on other users' processes alert with a "permission denied" message instead of reporting zero. Like `cpu`, the first measurement (and `jane -s`) samples over 100 ms.

Note that `matching` often finds a wrapper shell whose work happens in child processes. Use `total disk …` / `total cpu` to include them.

The comparisons `>`, `>=`, `<`, `<=`, `=`, `!=` all work here. Each test is its own result, named e.g. `Process app cpu > 80%`.

### Port checks

`if failed port <n> ...` (in `check host`, or in `check process` for `localhost` / `failed host <addr> port <n>`) passes when the TCP connection succeeds and every option below holds:

```
check host web with address www.example.com
    if failed port 443 protocol https request "/health" with hostheader "api.example.com"
       and status = 200 and content = "ok" and certificate valid > 30 days
       with timeout 5 seconds and ssl options {verify: enable}
       for 2 cycles then alert
    if failed port 80 protocol http then alert
    if failed port 25 expect "^220" then alert
```

| Option | Meaning |
|---|---|
| `type tcp` / `type tcpssl` | Plain TCP (default) or TLS |
| `protocol http` / `protocol https` | Send `GET <request>` and check the response. https implies TLS. Other protocols are accepted with a warning and only the connection is checked. |
| `request "/path"` | Path (and query) to request; default `/` |
| `hostheader "name"` | `Host` header, also used for TLS SNI and hostname verification. Default: the address (plus `:port` if it isn't 80/443). |
| `status <op> <code>` | Required status, e.g. `status = 200`, `status < 500`. Default: any status below 400. Redirects aren't followed. |
| `content = "<regex>"` / `content != "<regex>"` | The response body (first 1 MB) must / must not match |
| `expect "<regex>"` | Non-HTTP: the first line the server sends must match, e.g. `expect "^SSH-"` |
| `certificate valid <op> <n> days` | TLS: days until the server certificate expires, e.g. `certificate valid > 30 days` |
| `ssl options {verify: enable}` | Verify the certificate chain and hostname. Off by default, as in Monit, so self-signed and internal certificates work. With a bare IP address, only the chain is verified unless `hostheader` gives a name. |
| `timeout <n> seconds` | Connect/read timeout; default one daemon cycle minus 1 second |

`with`, `and` and `using` are optional filler. The result shows the status and days left (e.g. `200 OK, cert 45d`), and the message says which condition failed. Each rule is one result: `Network Connection web` for a single rule, or `web:443`, `web:80`, `web:80 (2)` when there are several. UDP, `retry` (use `for N cycles`) and protocol tests other than http/https aren't supported.

### File, directory and fifo tests

```
check file heartbeat with path /var/run/app/heartbeat
    if modify timestamp > 5 minutes then alert
    if size > 2 GB then alert
    if size = 0 then alert
    if changed size then alert
    if failed checksum expect "d41d8cd98f00b204e9800998ecf8427e" then alert
    if changed sha256 checksum then exec "/usr/local/bin/notify-config-change"

check directory spool with path /var/spool/app
    if timestamp > 1 hour then alert
    if failed uid app then alert
```

| Test | Meaning |
|---|---|
| `timestamp > <duration>` | Age of the newer of the modify and change time (as in Monit). Durations: `s`, `min`/`m`, `hours`/`h`, `days`/`d`. |
| `modify timestamp`, `change timestamp`, `access timestamp` | Age of that one time (mtime, ctime, atime). Use `modify timestamp` for "has this file been written recently": the change time also moves on `chmod`, `chown` and `touch -d`. |
| `changed timestamp` (any of the four) | Fires in the cycle the time changes |
| `size <op> <size>` | File size; a plain number is bytes (`if size = 0`) |
| `changed size` | Fires in the cycle the size changes |
| `failed [md5\|sha1\|sha256] checksum expect "<hash>"` | Alerts while the file's hash differs from `<hash>`. The algorithm can be left out; it's taken from the hash length (32 = md5, 40 = sha1, 64 = sha256). Monit's `and expect the sum <hash>` form also works. |
| `failed [md5\|sha1\|sha256] checksum` | Without a hash: alerts while the file differs from what it was when Jane started |
| `changed [md5\|sha1\|sha256] checksum` | Fires in the cycle the content changes (default md5) |

`changed` tests compare with the previous evaluation, so they never fire on the first cycle, and with `every N cycles` they compare with N cycles ago. Checksums are only recomputed when the file's inode, size, modify or change time changed, so large files aren't re-read every cycle. Size, checksum and content tests only work on `check file`.

With `check file`, a directory or fifo at the path is an alert (`'…' is a directory, not a regular file`).

### File content

`if content = "<regex>"` reads the file like `tail -f`. Each cycle it looks only at the complete lines added since the previous cycle. `=` fires when a new line matches, `!=` when a new line doesn't match. As in Monit, Jane starts at the end of the file when it first sees it, so lines written before Jane started are ignored (and `jane -s` never matches). If the file is rotated or truncated, Jane starts again from the beginning of the new file. At most 1 MB is read per check per cycle; the rest is read on the next cycle.

The result shows how many lines matched, with the last matching line as the message.

## Settings

| Statement | Meaning |
|---|---|
| `set cycle <seconds>` | Seconds between cycles (default 10). Monit's `set daemon <seconds>` is still accepted, with a warning to use `set cycle`. |
| `set log syslog [level <level>]` / `set log <file> [level <level>]` | Log destination and level |
| `set hq <host> [port <n>]` | Send results to Jane HQ (default port 80) |
| `set mailserver <host> [port <n>]` | SMTP server for alert emails (default port 25) |
| `set alert <email> [cc <email>]` | Alert email recipient and cc (a second `set alert` line becomes the cc) |
| `include <glob>` | Parses the matching files in sorted order, as if their text were pasted at this point. Relative paths are relative to the including file. |

Other monitrc settings (`set httpd`, `set eventqueue`, `set idfile`, …) are skipped with a warning. See [Configuration](configuration.md) for defaults and details.

## Not supported yet

These parse, but the check engine can't act on them yet. Each one produces a warning:

| Feature | What happens today |
|---|---|
| `then unmonitor` | The rule only alerts |
| `every "<cron spec>"` | The check runs every cycle |
| `depends on` | Ignored |
| filesystem `read rate` / `write rate` / `service time`, ping, protocol tests other than http/https, … | The rule is skipped (`protocol` falls back to a plain connection check) |
| `>` only | Other comparisons on cpu, memory, loadavg and filesystem rules are skipped |

The full list of missing tests is tracked in [issue #2](https://github.com/perfecto25/jane/issues/2).

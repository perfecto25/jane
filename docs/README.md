# Jane Agent Documentation

Jane is a lightweight system and process monitoring agent written in Crystal. It runs on a host and checks CPU, memory, filesystems, network, processes and files against the rules in a Monit-style control file. It then reports the results to a terminal table, to a central Jane HQ server, or as alert emails.

## Contents

| Document | What it covers |
|---|---|
| [Architecture](architecture.md) | How the pieces fit together, source layout, and the data flow of a check cycle |
| [Command line](cli.md) | Every command and flag, including `monitor` / `unmonitor` |
| [Configuration](configuration.md) | Global settings (`set cycle`, `set hq`, …), tags, include files |
| [Control file](control-file.md) | The Monit-style config format (`check filesystem root with path / ...`) |
| [Checks](checks.md) | Each check type with an example: what it measures and how it decides ok vs alert |
| [Daemon and alerting](daemon.md) | Daemon mode, HQ mode, email alerting, logging, the state file |

## Quick start

```sh
# install build prerequisites (Fedora/RHEL)
sudo dnf install pcre2-devel

# build
shards build            # produces ./bin/jane

# show host info
./bin/jane

# write a control file (or generate one for this host: ./bin/jane -g > jane.conf)
cat > jane.conf <<'CONF'
set cycle 10
check system myhost
    if cpu usage > 90% for 3 cycles then alert
    if memory usage > 85, 95 % then alert
check filesystem root with path /
    if space usage > 80, 90 % then alert
check process sshd matching "/usr/sbin/sshd"
CONF

# check the syntax
./bin/jane -t -c jane.conf

# evaluate all checks once and print a table
./bin/jane -s -c jane.conf

# run continuously
./bin/jane -d -c jane.conf
```

Without `-c`, Jane reads `jane.conf` in the current directory. See [Checks](checks.md) for an example of every check type.

## Runtime requirements

Jane reads most of its data straight from `/proc` and `/sys`, so it is **Linux only**. Some checks call out to external tools:

| Tool | Used by |
|---|---|
| `stat` (coreutils) | filesystem checks (`stat -f`, run with a timeout so hung mounts can't block Jane) |
| `iperf3` | network bandwidth checks (also needs an `iperf3 -s` server on the remote host) |

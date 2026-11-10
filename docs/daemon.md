# Daemon and alerting

`jane -d -c jane.conf` runs Jane continuously. On startup it:

1. Sets up logging from `set log`.
2. Exits if `set cycle` is less than 2 seconds.
3. Picks **one** of two modes:

| Condition | Mode |
|---|---|
| `set hq <host>` present | **HQ mode**: results go to the HQ server |
| otherwise | **Standalone alert mode**: email on new alerts |

These modes are exclusive. With HQ enabled, no email is sent from the agent.

Each mode loops forever:

```
run due checks (`every`) → drop unmonitored tags (state.json) → rule engine (cycle windows, actions) → send / alert → sleep cycle
```

If a cycle raises an error, the error is logged (`Error in daemon loop` / `Error in alert loop`) and the loop continues with the next cycle.

## HQ mode

Uses the host and port from `set hq <host> [port <n>]` (default port 80).

Every cycle Jane builds this payload:

```json
{
  "checks":      [ /* Monitor::Check objects, see architecture.md */ ],
  "metrics":     { "hostname": "...", "os": "...", "kernel": "...", "uptime": "...",
                   "cpu_model": "...", "cpu_cores": 6, "cpu_usage": "...", "load_avg": "...",
                   "total_memory": "...", "used_memory": "...", "free_memory": "...",
                   "memory_usage": "...", "jane_version": "0.1.0" },
  "unmonitored": [ "tag1", "tag2" ],
  "config":      { "format": "control", "source": "<text of the main control file>" }
}
```

**Wire format:** the payload is serialized to a JSON string. That string is then encoded as a single **msgpack string** and written to a fresh TCP connection to `host:port`, which is then closed. Each cycle uses one connection and one message, with no length prefix. The connect timeout is `cycle` seconds. HQ should read until EOF, msgpack-decode the string, and JSON-parse it.

Notes:

- `checks` already excludes unmonitored checks.
- `config` is re-read from disk each cycle and only covers the main file, not the include files.
- If the send fails (for example HQ is down), the failure is logged and the payload is dropped. Nothing is buffered or retried.

## Standalone alert mode

Requires `[alert.email]` with `smtp.server` and `send.to`. Otherwise Jane exits with an error.

The `Alerter` remembers the last status of each check by name, in memory. After every cycle it collects the checks that are **now `alert` and were not `alert` last cycle**. If there are any, it sends **one** email listing them all.

- Alerts are edge-triggered. A check that stays in alert does not send repeated emails, unless it has several threshold levels and climbs to a higher one (e.g. memory > 80% → > 90%). Falling back to a lower level sends nothing.
- No recovery ("back to ok") email is sent.
- State is not persisted. After a restart, every check that is currently in alert sends an email again.
- Unmonitored checks are removed before the alerter sees them. If you unmonitor a failing check and later re-monitor it while it is still failing, it alerts again.

### Email details

- **From:** `jane@<hostname>`
- **To / Cc:** `send.to`, `send.cc`
- **Subject:** `Jane Alert: N check(s) entered alert state on <hostname>`
- **Body:** name, status, current value, threshold and message for each check.

Jane uses a minimal built-in SMTP client: `EHLO`, `MAIL FROM`, `RCPT TO`, `DATA`, `QUIT`, over plain TCP with a 10 s connect timeout. There is **no TLS and no authentication**, so point it at a local MTA or a relay that accepts unauthenticated mail from the host. Send failures are logged and the alert is not retried.

## Logging

Log lines look like:

```
[2026-11-05 14:02:11]  INFO -- Jane Agent starting...
```

They go to stdout, or to the file given with `set log <file>`. See [Configuration › Settings](configuration.md#settings).

## State file

`state.json` sits next to the config file and holds the unmonitored tags:

```json
{"unmonitored_tags":["process"]}
```

`jane monitor` / `jane unmonitor` write it, and the daemon reads it every cycle. If it is missing or unreadable, Jane treats it as "nothing unmonitored". The file is safe to edit by hand.

## Running under systemd (example)

```ini
[Unit]
Description=Jane monitoring agent
After=network-online.target

[Service]
ExecStart=/usr/local/bin/jane -d -c /etc/jane/jane.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

The process must be able to write `/etc/jane/state.json` if you use `monitor`/`unmonitor` as that user. It must also be able to read anything the checks inspect, such as `/proc/<pid>/cmdline` for other users' processes and the paths given to file checks.

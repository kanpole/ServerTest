# Game Server Bench Design

## Goal

Build a small Ubuntu server benchmarking tool for evaluating whether the current machine is suitable for hosting a game server. The tool must run unattended for multiple days, continue after SSH disconnects, allow target limits when needed, and produce logs plus a final summary.

## Scope

The first version will benchmark:

- CPU capacity and sustained CPU stability.
- Download-side network throughput using public large model files or other large public files.
- Network quality using latency, packet loss, and jitter probes.
- System health signals such as load, memory, disk usage, and network interface counters.

The first version will not benchmark true player traffic patterns or server upload capacity. A proper upload or bidirectional throughput test needs a second machine controlled by the user, for example an `iperf3` server. The design leaves room to add that later.

## User Interface

The tool will be a single script named `game-server-bench.sh`.

Common commands:

```bash
sudo ./game-server-bench.sh install
sudo ./game-server-bench.sh start
sudo ./game-server-bench.sh start --hours 72
sudo ./game-server-bench.sh start --hours 72 --cpu 80 --download-mbps 300 --streams 4
./game-server-bench.sh status
./game-server-bench.sh logs
sudo ./game-server-bench.sh stop
./game-server-bench.sh report
```

Defaults:

- Duration: 72 hours.
- CPU mode: general sustained capacity test.
- Download target: no fixed Mbps target unless provided.
- Download streams: a conservative default such as 2 streams.
- Log directory: `./bench-runs/<timestamp>/`.

## Architecture

The script will have these responsibilities:

- Dependency installation through `apt` for required tools.
- Run directory creation with a per-run config file.
- Background process supervision through `tmux` or `systemd-run`.
- CPU worker startup and shutdown.
- Download worker startup and shutdown.
- Latency probe startup and shutdown.
- System metrics collection.
- Status, log tailing, stopping, and report generation.

The implementation should prefer common Ubuntu packages:

- `stress-ng` for CPU pressure.
- `curl` and optionally `aria2` for download tests.
- `mtr-tiny`, `ping`, and `iproute2` for network checks.
- `sysstat` for `sar` metrics.
- `tmux` for keeping the benchmark alive after SSH disconnects.
- `bc`, `awk`, and `coreutils` for shell calculations and summaries.

## CPU Test

CPU testing will use `stress-ng`.

If the user supplies `--cpu <percent>`, the script should use stress-ng CPU load controls where available to target that load. If no target is supplied, the script should run a sustained general stress test that exercises all CPU cores.

The script should log:

- CPU load averages.
- CPU utilization from `sar`.
- CPU frequency and throttling clues when available from `/proc` and `/sys`.
- Stress worker start and stop times.

## Download Network Test

The download test can use public large model files, such as files hosted through Hugging Face, as a practical substitute when no second server exists. This measures public CDN download throughput from the server, not real game traffic quality.

The script should support:

- A default list of public large file URLs.
- User override through `--url <url>`, repeatable if possible.
- `--download-mbps <target>` as an observation target, not a hard guarantee.
- `--streams <n>` for parallel download workers.
- A temporary download directory under the run directory.

Safety and politeness constraints:

- Avoid unbounded aggressive loops against one host.
- Rotate URLs when multiple URLs are configured.
- Delete downloaded files after measuring, unless a future option asks to keep them.
- Record HTTP failures, rate limits, DNS failures, and timeouts.

The report should state clearly that this test only reflects reachable public download throughput during the test window.

## Network Quality Test

Latency probes will run for the full duration. Default targets should include stable public IPs and relevant hostnames:

- `1.1.1.1`
- `8.8.8.8`
- `huggingface.co`

Metrics:

- Average latency.
- Maximum latency.
- Packet loss.
- Basic jitter estimate.
- Outage windows.

This matters for game hosting because stable latency and low packet loss are often more important than peak download bandwidth.

## Background Execution

The benchmark must continue after SSH disconnects.

Preferred approach:

- Use a named `tmux` session for portability and easy log inspection.

Behavior:

- `start` creates a run directory, writes config, starts the background session, and prints the run path.
- `status` reports whether the session is running and shows recent metrics.
- `logs` tails the main log.
- `stop` terminates the session and child workers cleanly.
- `report` summarizes the latest or specified run directory.

## Data Layout

Each run will create:

```text
bench-runs/
  2026-05-18-120000/
    config.env
    main.log
    cpu.log
    download.log
    ping-1.1.1.1.log
    ping-8.8.8.8.log
    ping-huggingface.co.log
    sar.log
    report.txt
    tmp-downloads/
```

The final report should include:

- Start and end time.
- Config used.
- CPU summary.
- Download throughput summary.
- Network latency and packet loss summary.
- Notable failures.
- Practical recommendation for game server suitability.

## Error Handling

The script should fail early when:

- It is not running on Linux.
- Required tools are missing and `install` has not been run.
- It cannot create the run directory.
- Another benchmark session is already running.

It should degrade gracefully when:

- A public download URL fails.
- A ping target is blocked.
- `sar` is unavailable before install.
- CPU frequency information is unavailable on the platform.

## Testing

Implementation should include lightweight verification:

- Shell syntax check with `bash -n`.
- Help output check.
- Short dry run or short live run, for example 1-2 minutes.
- Report generation check from the short run.

Long multi-day verification is not required before delivering the script, but the script must support it.

## Open Extension Points

Future versions can add:

- `iperf3` bidirectional tests when the user has a second server.
- UDP packet tests closer to game-server behavior.
- Region-specific latency targets.
- Discord, Telegram, or email completion notifications.
- JSON or CSV output for graphing.

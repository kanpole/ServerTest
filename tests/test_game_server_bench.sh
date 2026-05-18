#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/game-server-bench.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

run_expect_success() {
  local output
  output="$("$@" 2>&1)" || fail "expected success running: $*; output: $output"
  printf '%s' "$output"
}

run_expect_failure() {
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected failure running: $*; output: $output"
  fi
  printf '%s' "$output"
}

make_fake_command_path() {
  local tmpdir bin command_name
  tmpdir="$(mktemp -d)"
  bin="$tmpdir/bin"
  mkdir -p "$bin"
  for command_name in stress-ng curl ping sar tmux awk bc ip; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/$command_name"
    chmod +x "$bin/$command_name"
  done
  printf '%s\n' "$bin"
}

test_help_output_lists_commands() {
  local output
  output="$(run_expect_success "$SCRIPT" --help)"
  assert_contains "$output" "Usage:"
  assert_contains "$output" "install"
  assert_contains "$output" "start"
  assert_contains "$output" "status"
  assert_contains "$output" "report"
  assert_contains "$output" "--iperf-host"
  assert_contains "$output" "--iperf-mode"
}

test_invalid_command_fails() {
  local output
  output="$(run_expect_failure "$SCRIPT" nope)"
  assert_contains "$output" "Unknown command"
}

test_invalid_start_arguments_fail() {
  local output
  output="$(run_expect_failure "$SCRIPT" start --hours 0)"
  assert_contains "$output" "--hours must be >= 1"

  output="$(run_expect_failure "$SCRIPT" start --cpu 101)"
  assert_contains "$output" "--cpu must be between 1 and 100"

  output="$(run_expect_failure "$SCRIPT" start --streams 0)"
  assert_contains "$output" "--streams must be >= 1"
}

test_install_dry_run_lists_packages() {
  local output
  output="$(run_expect_success "$SCRIPT" install --dry-run)"
  assert_contains "$output" "Would install packages:"
  assert_contains "$output" "stress-ng"
  assert_contains "$output" "tmux"
  assert_contains "$output" "sysstat"
  assert_contains "$output" "iperf3"
}

test_start_dry_run_creates_run_config() {
  local tmpdir output run_dir config config_body
  tmpdir="$(mktemp -d)"
  output="$(BENCH_BASE_DIR="$tmpdir" run_expect_success "$SCRIPT" start --dry-run --hours 3 --cpu 75 --download-mbps 200 --streams 3 --url https://example.com/file.bin)"
  assert_contains "$output" "Dry run created:"
  run_dir="$(printf '%s\n' "$output" | awk -F': ' '/Dry run created:/ {print $2}' | tail -n 1)"
  [[ -d "$run_dir" ]] || fail "expected run directory to exist: $run_dir"
  config="$run_dir/config.env"
  [[ -f "$config" ]] || fail "expected config file: $config"
  config_body="$(cat "$config")"
  assert_contains "$config_body" "HOURS=3"
  assert_contains "$config_body" "CPU_TARGET=75"
  assert_contains "$config_body" "DOWNLOAD_TARGET_MBPS=200"
  assert_contains "$config_body" "STREAMS=3"
  assert_contains "$config_body" "https://example.com/file.bin"
}

test_start_dry_run_creates_iperf_config() {
  local tmpdir output run_dir config_body
  tmpdir="$(mktemp -d)"
  output="$(BENCH_BASE_DIR="$tmpdir" run_expect_success "$SCRIPT" start --dry-run --hours 2 --iperf-host 203.0.113.10 --iperf-port 5202 --iperf-mode udp --iperf-mbps 75 --iperf-duration 15 --iperf-interval 60)"
  assert_contains "$output" "Dry run created:"
  run_dir="$(printf '%s\n' "$output" | awk -F': ' '/Dry run created:/ {print $2}' | tail -n 1)"
  config_body="$(cat "$run_dir/config.env")"
  assert_contains "$config_body" "IPERF_HOST=203.0.113.10"
  assert_contains "$config_body" "IPERF_PORT=5202"
  assert_contains "$config_body" "IPERF_MODE=udp"
  assert_contains "$config_body" "IPERF_MBPS=75"
  assert_contains "$config_body" "IPERF_DURATION=15"
  assert_contains "$config_body" "IPERF_INTERVAL=60"
}

test_invalid_iperf_arguments_fail() {
  local output
  output="$(run_expect_failure "$SCRIPT" start --iperf-host 203.0.113.10 --iperf-port 0)"
  assert_contains "$output" "--iperf-port must be between 1 and 65535"

  output="$(run_expect_failure "$SCRIPT" start --iperf-host 203.0.113.10 --iperf-mode bogus)"
  assert_contains "$output" "--iperf-mode must be one of"

  output="$(run_expect_failure "$SCRIPT" start --iperf-host 203.0.113.10 --iperf-duration 0)"
  assert_contains "$output" "--iperf-duration must be >= 1"
}

test_start_requires_dependencies_without_dry_run() {
  local tmpdir output
  tmpdir="$(mktemp -d)"
  output="$(BENCH_BASE_DIR="$tmpdir" BENCH_SKIP_REQUIRE_ROOT=1 BENCH_PATH_OVERRIDE="/nonexistent" run_expect_failure "$SCRIPT" start --hours 1)"
  assert_contains "$output" "Missing required command"
}

test_iperf_start_requires_iperf3_when_enabled() {
  local tmpdir fake_path output
  tmpdir="$(mktemp -d)"
  fake_path="$(make_fake_command_path)"
  output="$(BENCH_BASE_DIR="$tmpdir" BENCH_SKIP_REQUIRE_ROOT=1 BENCH_PATH_OVERRIDE="$fake_path" run_expect_failure "$SCRIPT" start --hours 1 --iperf-host 203.0.113.10)"
  assert_contains "$output" "Missing required command: iperf3"
}

test_internal_run_requires_config() {
  local output
  output="$(run_expect_failure "$SCRIPT" __run /tmp/does-not-exist/config.env)"
  assert_contains "$output" "Config file not found"
}

test_logs_reads_latest_run_main_log() {
  local tmpdir run_dir output
  tmpdir="$(mktemp -d)"
  run_dir="$tmpdir/2026-05-18-120000"
  mkdir -p "$run_dir"
  echo "hello log" > "$run_dir/main.log"
  output="$(BENCH_BASE_DIR="$tmpdir" run_expect_success "$SCRIPT" logs --no-follow)"
  assert_contains "$output" "hello log"
}

test_status_reports_not_running() {
  local output
  output="$(run_expect_success "$SCRIPT" status)"
  assert_contains "$output" "Session:"
}

test_status_succeeds_when_latest_run_has_no_main_log() {
  local tmpdir run_dir output
  tmpdir="$(mktemp -d)"
  run_dir="$tmpdir/2026-05-18-120000"
  mkdir -p "$run_dir"
  output="$(BENCH_BASE_DIR="$tmpdir" run_expect_success "$SCRIPT" status)"
  assert_contains "$output" "Session:"
  assert_contains "$output" "Latest run: $run_dir"
}

test_report_summarizes_fixture_run() {
  local tmpdir run_dir output
  tmpdir="$(mktemp -d)"
  run_dir="$tmpdir/2026-05-18-120000"
  mkdir -p "$run_dir"
  cat > "$run_dir/config.env" <<'CONFIG'
RUN_DIR=/tmp/sample
HOURS=1
CPU_TARGET=80
DOWNLOAD_TARGET_MBPS=100
STREAMS=2
URLS=(https://example.com/a.bin)
PING_TARGETS=(1.1.1.1)
CONFIG
  cat > "$run_dir/main.log" <<'LOG'
[2026-05-18T12:00:00Z] Benchmark started for 1 hour(s)
[2026-05-18T13:00:00Z] Benchmark finished
LOG
  cat > "$run_dir/download.log" <<'LOG'
[2026-05-18T12:01:00Z] worker=1 code=0 bytes=100000000 seconds=10 mbps=80.00 url=https://example.com/a.bin
[2026-05-18T12:02:00Z] worker=2 code=7 bytes=0 seconds=10 mbps=0.00 url=https://example.com/a.bin
LOG
  cat > "$run_dir/iperf.log" <<'LOG'
[2026-05-18T12:10:00Z] mode=tcp-up code=0 bandwidth_mbps=900.00 jitter_ms= loss_percent= host=203.0.113.10
[2026-05-18T12:11:00Z] mode=tcp-down code=0 bandwidth_mbps=800.00 jitter_ms= loss_percent= host=203.0.113.10
[2026-05-18T12:12:00Z] mode=udp-up code=0 bandwidth_mbps=98.00 jitter_ms=0.12 loss_percent=0.5 host=203.0.113.10
[2026-05-18T12:13:00Z] mode=udp-down code=1 bandwidth_mbps=70.00 jitter_ms=1.20 loss_percent=2.0 host=203.0.113.10
LOG
  cat > "$run_dir/ping-1.1.1.1.log" <<'LOG'
PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=20.2 ms

--- 1.1.1.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 10.100/15.150/20.200/5.050 ms
LOG
  output="$(run_expect_success "$SCRIPT" report "$run_dir")"
  assert_contains "$output" "Game Server Benchmark Report"
  assert_contains "$output" "Average download Mbps: 40.00"
  assert_contains "$output" "Download failures: 1"
  assert_contains "$output" "iperf average Mbps: 467.00"
  assert_contains "$output" "iperf failures: 1"
  assert_contains "$output" "udp-down packet loss: 2.0%"
  assert_contains "$output" "1.1.1.1 packet loss: 0%"
  [[ -f "$run_dir/report.txt" ]] || fail "expected report file to be written"
}

main() {
  test_help_output_lists_commands
  test_invalid_command_fails
  test_invalid_start_arguments_fail
  test_install_dry_run_lists_packages
  test_start_dry_run_creates_run_config
  test_start_dry_run_creates_iperf_config
  test_invalid_iperf_arguments_fail
  test_start_requires_dependencies_without_dry_run
  test_iperf_start_requires_iperf3_when_enabled
  test_internal_run_requires_config
  test_logs_reads_latest_run_main_log
  test_status_reports_not_running
  test_status_succeeds_when_latest_run_has_no_main_log
  test_report_summarizes_fixture_run
  echo "All tests passed"
}

main "$@"

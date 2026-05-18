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

test_help_output_lists_commands() {
  local output
  output="$(run_expect_success "$SCRIPT" --help)"
  assert_contains "$output" "Usage:"
  assert_contains "$output" "install"
  assert_contains "$output" "start"
  assert_contains "$output" "status"
  assert_contains "$output" "report"
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

test_start_requires_dependencies_without_dry_run() {
  local tmpdir output
  tmpdir="$(mktemp -d)"
  output="$(BENCH_BASE_DIR="$tmpdir" BENCH_SKIP_REQUIRE_ROOT=1 BENCH_PATH_OVERRIDE="/nonexistent" run_expect_failure "$SCRIPT" start --hours 1)"
  assert_contains "$output" "Missing required command"
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
  assert_contains "$output" "1.1.1.1 packet loss: 0%"
  [[ -f "$run_dir/report.txt" ]] || fail "expected report file to be written"
}

main() {
  test_help_output_lists_commands
  test_invalid_command_fails
  test_invalid_start_arguments_fail
  test_install_dry_run_lists_packages
  test_start_dry_run_creates_run_config
  test_start_requires_dependencies_without_dry_run
  test_internal_run_requires_config
  test_logs_reads_latest_run_main_log
  test_status_reports_not_running
  test_report_summarizes_fixture_run
  echo "All tests passed"
}

main "$@"

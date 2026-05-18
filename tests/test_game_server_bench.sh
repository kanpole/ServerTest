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

main() {
  test_help_output_lists_commands
  test_invalid_command_fails
  test_invalid_start_arguments_fail
  test_install_dry_run_lists_packages
  test_start_dry_run_creates_run_config
  echo "All tests passed"
}

main "$@"

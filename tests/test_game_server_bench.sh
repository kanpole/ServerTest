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

main() {
  test_help_output_lists_commands
  test_invalid_command_fails
  test_invalid_start_arguments_fail
  echo "All tests passed"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="$SCRIPT_DIR/bench-runs"
SESSION_NAME="game-server-bench"
DEFAULT_HOURS=72
DEFAULT_STREAMS=2
DEFAULT_PING_TARGETS=("1.1.1.1" "8.8.8.8" "huggingface.co")
DEFAULT_URLS=(
  "https://huggingface.co/gpt2/resolve/main/pytorch_model.bin"
  "https://huggingface.co/bert-base-uncased/resolve/main/pytorch_model.bin"
)

usage() {
  cat <<'USAGE'
Usage:
  sudo ./game-server-bench.sh install
  sudo ./game-server-bench.sh start [--hours N] [--cpu PERCENT] [--download-mbps MBPS] [--streams N] [--url URL]
  ./game-server-bench.sh status
  ./game-server-bench.sh logs [RUN_DIR]
  sudo ./game-server-bench.sh stop
  ./game-server-bench.sh report [RUN_DIR]

Commands:
  install  Install Ubuntu packages required by the benchmark.
  start    Start a background benchmark that survives SSH disconnects.
  status   Show whether the benchmark session is running and recent logs.
  logs     Tail the latest or selected benchmark main log.
  stop     Stop the background benchmark session.
  report   Generate a summary report for the latest or selected run.

Options for start:
  --hours N           Duration in hours. Default: 72.
  --cpu PERCENT      Target CPU load from 1 to 100. Omit for all-core stress.
  --download-mbps N  Observation target for download throughput.
  --streams N        Parallel download workers. Default: 2.
  --url URL          Add a download URL. Can be repeated.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_start_args() {
  HOURS="$DEFAULT_HOURS"
  CPU_TARGET=""
  DOWNLOAD_TARGET_MBPS=""
  STREAMS="$DEFAULT_STREAMS"
  URLS=()

  while (($#)); do
    case "$1" in
      --hours)
        [[ $# -ge 2 ]] || die "--hours requires a value"
        HOURS="$2"
        shift 2
        ;;
      --cpu)
        [[ $# -ge 2 ]] || die "--cpu requires a value"
        CPU_TARGET="$2"
        shift 2
        ;;
      --download-mbps)
        [[ $# -ge 2 ]] || die "--download-mbps requires a value"
        DOWNLOAD_TARGET_MBPS="$2"
        shift 2
        ;;
      --streams)
        [[ $# -ge 2 ]] || die "--streams requires a value"
        STREAMS="$2"
        shift 2
        ;;
      --url)
        [[ $# -ge 2 ]] || die "--url requires a value"
        URLS+=("$2")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown start option: $1"
        ;;
    esac
  done

  is_positive_int "$HOURS" || die "--hours must be >= 1"
  if [[ -n "$CPU_TARGET" ]]; then
    is_positive_int "$CPU_TARGET" || die "--cpu must be between 1 and 100"
    ((CPU_TARGET >= 1 && CPU_TARGET <= 100)) || die "--cpu must be between 1 and 100"
  fi
  if [[ -n "$DOWNLOAD_TARGET_MBPS" ]]; then
    is_positive_int "$DOWNLOAD_TARGET_MBPS" || die "--download-mbps must be >= 1"
  fi
  is_positive_int "$STREAMS" || die "--streams must be >= 1"
}

cmd_install() {
  die "install command is unavailable in the CLI skeleton"
}

cmd_start() {
  parse_start_args "$@"
  die "start command is unavailable in the CLI skeleton"
}

cmd_status() {
  die "status command is unavailable in the CLI skeleton"
}

cmd_logs() {
  die "logs command is unavailable in the CLI skeleton"
}

cmd_stop() {
  die "stop command is unavailable in the CLI skeleton"
}

cmd_report() {
  die "report command is unavailable in the CLI skeleton"
}

main() {
  local command_name="${1:-}"
  case "$command_name" in
    ""|-h|--help)
      usage
      ;;
    install)
      shift
      cmd_install "$@"
      ;;
    start)
      shift
      cmd_start "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    logs)
      shift
      cmd_logs "$@"
      ;;
    stop)
      shift
      cmd_stop "$@"
      ;;
    report)
      shift
      cmd_report "$@"
      ;;
    *)
      die "Unknown command: $command_name"
      ;;
  esac
}

main "$@"

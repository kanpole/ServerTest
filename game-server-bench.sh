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
REQUIRED_PACKAGES=(stress-ng curl iputils-ping sysstat mtr-tiny tmux bc coreutils gawk iproute2)
required_commands=(stress-ng curl ping sar tmux awk bc ip)

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

check_required_commands() {
  local path_prefix="${BENCH_PATH_OVERRIDE:-}"
  local command_name
  for command_name in "${required_commands[@]}"; do
    if [[ -n "$path_prefix" ]]; then
      PATH="$path_prefix" command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name. Run: sudo ./game-server-bench.sh install"
    else
      command_exists "$command_name" || die "Missing required command: $command_name. Run: sudo ./game-server-bench.sh install"
    fi
  done
}

session_running() {
  command_exists tmux && tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1
}

make_run_dir() {
  local base_dir timestamp run_dir
  base_dir="${BENCH_BASE_DIR:-$RUNS_DIR}"
  timestamp="$(date -u +%Y-%m-%d-%H%M%S)"
  run_dir="$base_dir/$timestamp"
  mkdir -p "$run_dir/tmp-downloads"
  printf '%s\n' "$run_dir"
}

write_config() {
  local run_dir="$1"
  local config="$run_dir/config.env"
  {
    printf 'RUN_DIR=%q\n' "$run_dir"
    printf 'HOURS=%q\n' "$HOURS"
    printf 'CPU_TARGET=%q\n' "$CPU_TARGET"
    printf 'DOWNLOAD_TARGET_MBPS=%q\n' "$DOWNLOAD_TARGET_MBPS"
    printf 'STREAMS=%q\n' "$STREAMS"
    printf 'URLS=('
    local url
    for url in "${URLS[@]}"; do
      printf '%q ' "$url"
    done
    printf ')\n'
    printf 'PING_TARGETS=('
    local target
    for target in "${DEFAULT_PING_TARGETS[@]}"; do
      printf '%q ' "$target"
    done
    printf ')\n'
  } > "$config"
}

latest_run_dir() {
  local base_dir="${BENCH_BASE_DIR:-$RUNS_DIR}"
  [[ -d "$base_dir" ]] || return 1
  find "$base_dir" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

resolve_run_dir() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  latest_run_dir || die "No benchmark runs found"
}

parse_start_args() {
  HOURS="$DEFAULT_HOURS"
  CPU_TARGET=""
  DOWNLOAD_TARGET_MBPS=""
  STREAMS="$DEFAULT_STREAMS"
  URLS=()
  DRY_RUN=0

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
      --dry-run)
        DRY_RUN=1
        shift
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
  if ((${#URLS[@]} == 0)); then
    URLS=("${DEFAULT_URLS[@]}")
  fi
}

cmd_install() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
  (($# == 0)) || die "Unknown install option: $1"

  if ((dry_run)); then
    echo "Would install packages: ${REQUIRED_PACKAGES[*]}"
    return 0
  fi

  [[ "$(id -u)" -eq 0 ]] || die "install must be run with sudo"
  apt-get update
  apt-get install -y "${REQUIRED_PACKAGES[@]}"
}

cmd_start() {
  parse_start_args "$@"
  local run_dir
  run_dir="$(make_run_dir)"
  write_config "$run_dir"

  if ((DRY_RUN)); then
    echo "Dry run created: $run_dir"
    return 0
  fi

  [[ "$(id -u)" -eq 0 || "${BENCH_SKIP_REQUIRE_ROOT:-0}" == "1" ]] || die "start must be run with sudo"
  check_required_commands
  start_background_session "$run_dir"
}

cmd_status() {
  if session_running; then
    echo "Session: running ($SESSION_NAME)"
  else
    echo "Session: not running ($SESSION_NAME)"
  fi
  local run_dir
  if run_dir="$(latest_run_dir 2>/dev/null)"; then
    echo "Latest run: $run_dir"
    [[ -f "$run_dir/main.log" ]] && tail -n 10 "$run_dir/main.log"
  else
    echo "Latest run: none"
  fi
}

cmd_logs() {
  local follow=1
  if [[ "${1:-}" == "--no-follow" ]]; then
    follow=0
    shift
  fi
  local run_dir
  run_dir="$(resolve_run_dir "${1:-}")"
  [[ -f "$run_dir/main.log" ]] || die "Main log not found: $run_dir/main.log"
  if ((follow)); then
    tail -f "$run_dir/main.log"
  else
    cat "$run_dir/main.log"
  fi
}

cmd_stop() {
  if session_running; then
    tmux send-keys -t "$SESSION_NAME" C-c
    sleep 2
    tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    echo "Stopped benchmark session: $SESSION_NAME"
  else
    echo "Session not running: $SESSION_NAME"
  fi
}

cmd_report() {
  local run_dir
  run_dir="$(resolve_run_dir "${1:-}")"
  [[ -d "$run_dir" ]] || die "Run directory not found: $run_dir"
  local report="$run_dir/report.txt"
  local avg_mbps failures
  avg_mbps="$(average_download_mbps "$run_dir/download.log")"
  failures="$(download_failures "$run_dir/download.log")"

  {
    echo "Game Server Benchmark Report"
    echo "Run directory: $run_dir"
    [[ -f "$run_dir/config.env" ]] && echo "Config: $run_dir/config.env"
    echo "Average download Mbps: $avg_mbps"
    echo "Download failures: $failures"
    local ping_file target loss avg
    for ping_file in "$run_dir"/ping-*.log; do
      [[ -f "$ping_file" ]] || continue
      target="$(basename "$ping_file")"
      target="${target#ping-}"
      target="${target%.log}"
      loss="$(ping_loss "$ping_file")"
      avg="$(ping_avg "$ping_file")"
      echo "$target packet loss: ${loss:-unknown}"
      echo "$target average latency: ${avg:-unknown}"
    done
    echo "Recommendation: use low packet loss, stable latency, and sustained CPU behavior as the primary game-server signals. Public model downloads only measure reachable download throughput."
  } | tee "$report"
}

average_download_mbps() {
  local file="$1"
  [[ -f "$file" ]] || { echo "0.00"; return 0; }
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^mbps=/) {
          split($i, a, "=")
          total += a[2]
          count += 1
        }
      }
    }
    END {
      if (count == 0) printf "0.00"; else printf "%.2f", total / count
    }
  ' "$file"
}

download_failures() {
  local file="$1"
  [[ -f "$file" ]] || { echo "0"; return 0; }
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^code=/) {
          split($i, a, "=")
          if (a[2] != "0") failures += 1
        }
      }
    }
    END { printf "%d", failures }
  ' "$file"
}

ping_loss() {
  local file="$1"
  [[ -f "$file" ]] || { echo "unknown"; return 0; }
  awk -F',' '/packet loss/ {
    gsub(/^ +| +$/, "", $3)
    split($3, a, " ")
    print a[1]
  }' "$file" | tail -n 1
}

ping_avg() {
  local file="$1"
  [[ -f "$file" ]] || { echo "unknown"; return 0; }
  awk -F' = ' '/rtt min\/avg\/max/ {
    split($2, a, "/")
    print a[2] " ms"
  }' "$file" | tail -n 1
}

start_background_session() {
  local run_dir="$1"
  session_running && die "Benchmark session already running: $SESSION_NAME"
  tmux new-session -d -s "$SESSION_NAME" "bash '$SCRIPT_DIR/game-server-bench.sh' __run '$run_dir/config.env'"
  echo "Started benchmark session: $SESSION_NAME"
  echo "Run directory: $run_dir"
}

log_main() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$RUN_DIR/main.log"
}

run_cpu_worker() {
  local duration_seconds="$1"
  local args=(--timeout "${duration_seconds}s" --metrics-brief)
  if [[ -n "${CPU_TARGET:-}" ]]; then
    args+=(--cpu 0 --cpu-load "$CPU_TARGET")
  else
    args+=(--cpu 0)
  fi
  log_main "Starting CPU worker"
  stress-ng "${args[@]}" >"$RUN_DIR/cpu.log" 2>&1 &
  WORKER_PIDS+=("$!")
}

run_download_worker() {
  local worker_id="$1"
  local duration_seconds="$2"
  (
    local end_time index url output code start_ts end_ts bytes elapsed mbps
    end_time=$(($(date +%s) + duration_seconds))
    index=0
    while (($(date +%s) < end_time)); do
      url="${URLS[$((index % ${#URLS[@]}))]}"
      output="$RUN_DIR/tmp-downloads/worker-${worker_id}.bin"
      start_ts="$(date +%s)"
      code=0
      curl -L --fail --connect-timeout 20 --max-time 1800 -o "$output" "$url" >>"$RUN_DIR/download-worker-${worker_id}.curl.log" 2>&1 || code=$?
      end_ts="$(date +%s)"
      bytes=0
      [[ -f "$output" ]] && bytes="$(wc -c < "$output")"
      rm -f "$output"
      elapsed=$((end_ts - start_ts))
      ((elapsed < 1)) && elapsed=1
      mbps="$(awk -v b="$bytes" -v s="$elapsed" 'BEGIN { printf "%.2f", (b * 8) / s / 1000000 }')"
      printf '[%s] worker=%s code=%s bytes=%s seconds=%s mbps=%s url=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$worker_id" "$code" "$bytes" "$elapsed" "$mbps" "$url" >> "$RUN_DIR/download.log"
      index=$((index + 1))
      sleep 5
    done
  ) &
  WORKER_PIDS+=("$!")
}

run_ping_worker() {
  local target="$1"
  ping "$target" > "$RUN_DIR/ping-${target}.log" 2>&1 &
  WORKER_PIDS+=("$!")
}

run_sar_worker() {
  sar -u -r -n DEV 10 > "$RUN_DIR/sar.log" 2>&1 &
  WORKER_PIDS+=("$!")
}

stop_workers() {
  local pid
  for pid in "${WORKER_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}

cmd_internal_run() {
  local config="${1:-}"
  [[ -n "$config" && -f "$config" ]] || die "Config file not found: $config"
  source "$config"
  WORKER_PIDS=()
  trap stop_workers EXIT INT TERM
  local duration_seconds=$((HOURS * 3600))
  log_main "Benchmark started for ${HOURS} hour(s)"
  run_cpu_worker "$duration_seconds"
  local i
  for ((i = 1; i <= STREAMS; i++)); do
    run_download_worker "$i" "$duration_seconds"
  done
  local target
  for target in "${PING_TARGETS[@]}"; do
    run_ping_worker "$target"
  done
  run_sar_worker
  sleep "$duration_seconds"
  log_main "Benchmark finished"
  stop_workers
  "$SCRIPT_DIR/game-server-bench.sh" report "$RUN_DIR" >/dev/null 2>&1 || true
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
    __run)
      shift
      cmd_internal_run "$@"
      ;;
    *)
      die "Unknown command: $command_name"
      ;;
  esac
}

main "$@"

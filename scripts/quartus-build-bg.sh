#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$PROJECT_DIR/build_output/background-build"
PID_FILE="$STATE_DIR/pid"
STATUS_FILE="$STATE_DIR/status"
EXIT_FILE="$STATE_DIR/exit_code"
STARTED_FILE="$STATE_DIR/started_at"
FINISHED_FILE="$STATE_DIR/finished_at"
LOG_FILE="$STATE_DIR/quartus-build.log"

RBF="$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf"
RBF_R="$PROJECT_DIR/pkg/Cores/mincer_ray.GBA/bitstream.rbf_r"
STA_SUMMARY="$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary"
CLOCK_SUMMARY="$PROJECT_DIR/build_output/reports/ap_core.sta.clock_summary.rpt"

usage() {
  cat <<'EOF'
Usage: scripts/quartus-build-bg.sh <command>

Commands:
  start [--force]  Start a Quartus build in the background
  status           Show current background build status
  wait             Block until the background build finishes, then print result
  log              Print the background build log
  stop             Stop the running background build process

The build state and log are written to build_output/background-build/.
EOF
}

mkdir_state() {
  mkdir -p "$STATE_DIR"
}

is_running() {
  if [ ! -f "$PID_FILE" ]; then
    return 1
  fi

  local pid
  pid="$(tr -d '[:space:]' < "$PID_FILE")"
  if [ -z "$pid" ]; then
    return 1
  fi

  kill -0 "$pid" 2>/dev/null
}

status_value() {
  if [ -f "$STATUS_FILE" ]; then
    tr -d '[:space:]' < "$STATUS_FILE"
  else
    printf 'not-started'
  fi
}

write_status() {
  printf '%s\n' "$1" > "$STATUS_FILE"
}

print_summary() {
  local status
  status="$(status_value)"

  echo "=== Background Quartus Build ==="
  echo "Status: $status"

  if [ -f "$PID_FILE" ]; then
    echo "PID: $(tr -d '[:space:]' < "$PID_FILE")"
  fi
  if [ -f "$STARTED_FILE" ]; then
    echo "Started: $(cat "$STARTED_FILE")"
  fi
  if [ -f "$FINISHED_FILE" ]; then
    echo "Finished: $(cat "$FINISHED_FILE")"
  fi
  if [ -f "$EXIT_FILE" ]; then
    echo "Exit code: $(tr -d '[:space:]' < "$EXIT_FILE")"
  fi

  echo "Log: $LOG_FILE"
  echo "Bitstream: $RBF_R"
}

run_build() {
  mkdir_state
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STARTED_FILE"
  rm -f "$FINISHED_FILE" "$EXIT_FILE"
  write_status running

  local rc=0

  echo "=== Starting Quartus build via Docker ==="
  echo "Project: $PROJECT_DIR"
  echo "Log: $LOG_FILE"
  echo ""

  docker run --rm \
    -v "$PROJECT_DIR":/build \
    -w /build \
    raetro/quartus:21.1 \
    quartus_sh -t generate.tcl || rc=$?

  if [ "$rc" -eq 0 ]; then
    echo ""
    echo "=== Build complete, reversing bitstream ==="
    python3 "$SCRIPT_DIR/reverse_bitstream.py" "$RBF" "$RBF_R" || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    echo ""
    "$SCRIPT_DIR/print_timing.sh" "$STA_SUMMARY" "$CLOCK_SUMMARY" || rc=$?
  fi

  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$FINISHED_FILE"
  printf '%s\n' "$rc" > "$EXIT_FILE"

  if [ "$rc" -eq 0 ]; then
    write_status succeeded
    echo "=== Done! ==="
    echo "Bitstream: $RBF_R"
  else
    write_status failed
    echo "=== Build failed with exit code $rc ==="
  fi

  exit "$rc"
}

start_build() {
  local force=0
  if [ "${1:-}" = "--force" ]; then
    force=1
  fi

  mkdir_state

  if is_running; then
    if [ "$force" -eq 0 ]; then
      echo "A background Quartus build is already running."
      print_summary
      echo ""
      echo "Use '$0 status' to check it or '$0 stop' to stop it."
      exit 0
    fi

    echo "Stopping existing background build before starting a new one."
    stop_build
  fi

  rm -f "$PID_FILE" "$STATUS_FILE" "$EXIT_FILE" "$STARTED_FILE" "$FINISHED_FILE" "$LOG_FILE"
  write_status starting

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$0" _run > "$LOG_FILE" 2>&1 &
  else
    nohup "$0" _run > "$LOG_FILE" 2>&1 &
  fi
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"

  echo "Started background Quartus build."
  print_summary
  echo ""
  echo "Continue working in this OpenCode session. When you want to rejoin the build result, run:"
  echo "  $0 wait"
}

status_build() {
  mkdir_state

  if is_running; then
    print_summary
    exit 0
  fi

  if [ "$(status_value)" = "running" ] || [ "$(status_value)" = "starting" ]; then
    write_status unknown-stopped
  fi

  print_summary
}

wait_build() {
  mkdir_state

  if [ ! -f "$PID_FILE" ]; then
    echo "No background Quartus build has been started."
    exit 1
  fi

  echo "Waiting for background Quartus build to finish..."
  while is_running; do
    sleep 30
  done

  if [ "$(status_value)" = "running" ] || [ "$(status_value)" = "starting" ]; then
    write_status unknown-stopped
  fi

  print_summary
  echo ""

  if [ -f "$STA_SUMMARY" ] || [ -f "$CLOCK_SUMMARY" ]; then
    "$SCRIPT_DIR/print_timing.sh" "$STA_SUMMARY" "$CLOCK_SUMMARY"
  fi

  if [ -f "$EXIT_FILE" ]; then
    exit "$(tr -d '[:space:]' < "$EXIT_FILE")"
  fi

  exit 1
}

log_build() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "No background build log found at $LOG_FILE"
    exit 1
  fi

  cat "$LOG_FILE"
}

stop_build() {
  if ! is_running; then
    echo "No running background Quartus build found."
    return 0
  fi

  local pid
  pid="$(tr -d '[:space:]' < "$PID_FILE")"
  # Prefer killing the process group so Docker exits with the wrapper.
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  write_status stopped
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$FINISHED_FILE"
  printf '143\n' > "$EXIT_FILE"
  echo "Stopped background Quartus build PID $pid."
}

case "${1:-}" in
  start)
    shift
    start_build "${1:-}"
    ;;
  status)
    status_build
    ;;
  wait)
    wait_build
    ;;
  log)
    log_build
    ;;
  stop)
    stop_build
    ;;
  _run)
    run_build
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac

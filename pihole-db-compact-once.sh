#!/bin/bash
set -u
set -o pipefail

DB_FILE="${DB_FILE:-/etc/pihole/pihole-FTL.db}"
FTL_SERVICE="${FTL_SERVICE:-pihole-FTL}"
LOG_DIR="${LOG_DIR:-/home/pi/pihole-db-maintenance-logs}"
BACKUP_DIR="${BACKUP_DIR:-/home/pi/pihole-db-backups}"
MAX_DOWNTIME_MINUTES="${MAX_DOWNTIME_MINUTES:-10}"
START_WAIT_SECONDS="${START_WAIT_SECONDS:-90}"
VACUUM_TIMEOUT_SECONDS="${VACUUM_TIMEOUT_SECONDS:-900}"
DRY_RUN=0
NO_FAILSAFE=0

SCRIPT_NAME=$(basename "$0")
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE=""
BACKUP_PATH=""
FAILSAFE_UNIT=""
SERVICE_STOPPED=0
SERVICE_RESTARTED=0
CURRENT_STEP="initialization"

usage() {
  cat <<'EOF'
Usage:
  pihole-db-compact-once.sh [--dry-run] [--no-failsafe]
                            [--log-dir DIR] [--backup-dir DIR]
                            [--max-downtime-minutes N]
                            [--start-wait-seconds N]
                            [--vacuum-timeout-seconds N]

Environment overrides:
  DB_FILE
  FTL_SERVICE
  LOG_DIR
  BACKUP_DIR
  MAX_DOWNTIME_MINUTES
  START_WAIT_SECONDS
  VACUUM_TIMEOUT_SECONDS

This script is intended for one-time manual compaction of Pi-hole's long-term
query database. It performs:

  1. A before snapshot
  2. A timestamped backup
  3. A controlled stop of pihole-FTL
  4. A checkpoint + VACUUM
  5. A controlled restart
  6. An after snapshot

It writes a verbose timestamped log to LOG_DIR and prints the same output to
stdout.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-failsafe)
      NO_FAILSAFE=1
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift
      ;;
    --backup-dir)
      BACKUP_DIR="$2"
      shift
      ;;
    --max-downtime-minutes)
      MAX_DOWNTIME_MINUTES="$2"
      shift
      ;;
    --start-wait-seconds)
      START_WAIT_SECONDS="$2"
      shift
      ;;
    --vacuum-timeout-seconds)
      VACUUM_TIMEOUT_SECONDS="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}-${TIMESTAMP}.log"
BACKUP_PATH="${BACKUP_DIR}/pihole-FTL.db.backup-${TIMESTAMP}"

timestamp_lines() {
  while IFS= read -r line; do
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
  done
}

exec > >(timestamp_lines | tee -a "$LOG_FILE") 2>&1

log() {
  printf '%s\n' "$*"
}

format_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    out+=$(printf '%q ' "$arg")
  done
  printf '%s' "${out% }"
}

run_cmd() {
  local desc="$1"
  shift

  CURRENT_STEP="$desc"
  log ""
  log "BEGIN: $desc"
  log "CMD: $(format_cmd "$@")"
  "$@"
  local rc=$?
  log "END: $desc (rc=$rc)"
  return $rc
}

fail() {
  log ""
  log "ERROR during step: $CURRENT_STEP"
  log "DETAIL: $*"
  exit 1
}

cancel_failsafe() {
  if [ -n "$FAILSAFE_UNIT" ] && [ "$NO_FAILSAFE" -ne 1 ]; then
    sudo -n systemctl cancel "${FAILSAFE_UNIT}.timer" "${FAILSAFE_UNIT}.service" >/dev/null 2>&1 || true
    sudo -n systemctl stop "${FAILSAFE_UNIT}.timer" "${FAILSAFE_UNIT}.service" >/dev/null 2>&1 || true
  fi
}

ensure_ftl_running_for_cleanup() {
  if [ "$SERVICE_STOPPED" -eq 1 ] && [ "$SERVICE_RESTARTED" -eq 0 ]; then
    log ""
    log "Cleanup: Pi-hole FTL appears to still be stopped. Attempting emergency restart."
    sudo -n systemctl start "$FTL_SERVICE" >/dev/null 2>&1 || true
    sleep 5
    systemctl is-active "$FTL_SERVICE" || true
  fi
}

cleanup() {
  local rc=$?
  ensure_ftl_running_for_cleanup
  cancel_failsafe
  log ""
  log "Log file: $LOG_FILE"
  log "Backup path: $BACKUP_PATH"
  log "Script exit code: $rc"
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

snapshot_db() {
  local label="$1"
  local service_state="unknown"

  log ""
  log "==== ${label} SNAPSHOT ===="
  date
  service_state=$(systemctl is-active "$FTL_SERVICE" 2>/dev/null || true)
  log "FTL service state: ${service_state:-unknown}"
  ls -lh "$DB_FILE" "${DB_FILE}-wal" "${DB_FILE}-shm" 2>/dev/null || true

  sudo -n sqlite3 "file:${DB_FILE}?mode=ro" <<'SQL'
.headers on
.mode column
PRAGMA page_size;
PRAGMA page_count;
PRAGMA freelist_count;
PRAGMA auto_vacuum;
PRAGMA journal_mode;
PRAGMA quick_check;
SELECT COUNT(*) AS query_rows,
       datetime(MIN(timestamp),'unixepoch','localtime') AS min_ts,
       datetime(MAX(timestamp),'unixepoch','localtime') AS max_ts
FROM query_storage;
SELECT name, ROUND(SUM(pgsize)/1048576.0,1) AS mib, COUNT(*) AS pages
FROM dbstat
GROUP BY name
ORDER BY SUM(pgsize) DESC
LIMIT 10;
SQL
}

wait_for_ftl_active() {
  local deadline
  deadline=$(( $(date +%s) + START_WAIT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if systemctl is-active --quiet "$FTL_SERVICE"; then
      return 0
    fi
    sleep 2
  done

  systemctl is-active "$FTL_SERVICE" || true
  return 1
}

schedule_failsafe_restart() {
  if [ "$NO_FAILSAFE" -eq 1 ]; then
    log "Failsafe restart disabled by --no-failsafe"
    return 0
  fi

  FAILSAFE_UNIT="pihole-db-compact-once-${TIMESTAMP}"
  run_cmd "schedule failsafe restart timer" \
    sudo -n systemd-run \
      --quiet \
      --unit "$FAILSAFE_UNIT" \
      --on-active "${MAX_DOWNTIME_MINUTES}m" \
      /bin/systemctl start "$FTL_SERVICE" || return 1
}

main() {
  log "Starting ${SCRIPT_NAME}"
  log "DB_FILE=$DB_FILE"
  log "FTL_SERVICE=$FTL_SERVICE"
  log "LOG_DIR=$LOG_DIR"
  log "BACKUP_DIR=$BACKUP_DIR"
  log "MAX_DOWNTIME_MINUTES=$MAX_DOWNTIME_MINUTES"
  log "START_WAIT_SECONDS=$START_WAIT_SECONDS"
  log "VACUUM_TIMEOUT_SECONDS=$VACUUM_TIMEOUT_SECONDS"
  log "DRY_RUN=$DRY_RUN"
  log "NO_FAILSAFE=$NO_FAILSAFE"

  require_cmd sudo
  require_cmd sqlite3
  require_cmd systemctl
  require_cmd systemd-run
  require_cmd timeout
  require_cmd ls
  require_cmd cp

  run_cmd "verify passwordless sudo" sudo -n true || fail "passwordless sudo is required"

  snapshot_db "BEFORE"

  if [ "$DRY_RUN" -eq 1 ]; then
    log ""
    log "DRY RUN: No stop/vacuum/start actions were performed."
    return 0
  fi

  schedule_failsafe_restart || fail "failed to schedule failsafe restart"

  run_cmd "stop Pi-hole FTL" sudo -n systemctl stop "$FTL_SERVICE" || fail "could not stop ${FTL_SERVICE}"
  SERVICE_STOPPED=1
  systemctl is-active "$FTL_SERVICE" || true
  if systemctl is-active --quiet "$FTL_SERVICE"; then
    fail "${FTL_SERVICE} is still active after stop command"
  fi

  log ""
  log "Creating backup at ${BACKUP_PATH}"
  run_cmd "copy database backup" sudo -n cp -a "$DB_FILE" "$BACKUP_PATH" || fail "database backup copy failed"
  run_cmd "make backup readable by pi user" sudo -n chown pi:pi "$BACKUP_PATH" || fail "backup chown failed"
  run_cmd "set backup permissions" sudo -n chmod 600 "$BACKUP_PATH" || fail "backup chmod failed"
  run_cmd "verify backup file" ls -lh "$BACKUP_PATH" || fail "backup file missing after copy"
  run_cmd "backup checksum" sha256sum "$BACKUP_PATH" || fail "backup checksum failed"

  log ""
  log "Snapshot with FTL stopped and backup created:"
  ls -lh "$DB_FILE" "${DB_FILE}-wal" "${DB_FILE}-shm" 2>/dev/null || true
  sudo -n sqlite3 "file:${DB_FILE}?mode=ro" <<'SQL'
.headers on
.mode column
PRAGMA page_count;
PRAGMA freelist_count;
PRAGMA quick_check;
SQL

  run_cmd "checkpoint WAL before vacuum" \
    sudo -n sqlite3 "$DB_FILE" 'PRAGMA wal_checkpoint(TRUNCATE);' || fail "WAL checkpoint failed"

  log ""
  log "Running VACUUM with timeout ${VACUUM_TIMEOUT_SECONDS}s"
  CURRENT_STEP="VACUUM"
  log "CMD: sudo -n sqlite3 $DB_FILE 'VACUUM;'"
  local vacuum_start vacuum_rc
  vacuum_start=$(date +%s)
  timeout --kill-after=30s "${VACUUM_TIMEOUT_SECONDS}s" sudo -n sqlite3 "$DB_FILE" 'VACUUM;'
  vacuum_rc=$?
  log "VACUUM rc=$vacuum_rc duration=$(( $(date +%s) - vacuum_start ))s"
  if [ "$vacuum_rc" -ne 0 ]; then
    fail "VACUUM failed with rc=${vacuum_rc}"
  fi

  log ""
  log "Post-VACUUM snapshot before restart:"
  ls -lh "$DB_FILE" "${DB_FILE}-wal" "${DB_FILE}-shm" 2>/dev/null || true
  sudo -n sqlite3 "file:${DB_FILE}?mode=ro" <<'SQL'
.headers on
.mode column
PRAGMA page_count;
PRAGMA freelist_count;
PRAGMA quick_check;
SQL

  run_cmd "start Pi-hole FTL" sudo -n systemctl start "$FTL_SERVICE" || fail "could not start ${FTL_SERVICE}"
  if ! wait_for_ftl_active; then
    fail "${FTL_SERVICE} did not become active within ${START_WAIT_SECONDS}s"
  fi
  SERVICE_RESTARTED=1

  snapshot_db "AFTER"
  cancel_failsafe
  FAILSAFE_UNIT=""

  log ""
  log "One-time compaction completed successfully."
}

main "$@"

#!/bin/bash
set -u
set -o pipefail

DB_FILE="${DB_FILE:-/etc/pihole/pihole-FTL.db}"
LOG_FILE="${LOG_FILE:-/home/pi/pihole-db-size.log}"
EMAIL="${EMAIL:-mattjball@gmail.com}"
FTL_SERVICE="${FTL_SERVICE:-pihole-FTL}"
LOCK_FILE="${LOCK_FILE:-/tmp/pihole-db-monitor.lock}"
STATE_FILE="${STATE_FILE:-/home/pi/.cache/pihole-db-monitor.state}"
# Calendar days of the month on which we do the full stop/vacuum/start path.
# All other nights are stats-and-email only to avoid interfering with Pi-hole's
# own query-retention cleanup.
FULL_VACUUM_DAYS=(${FULL_VACUUM_DAYS:-1 15})
MAX_DOWNTIME_MINUTES="${MAX_DOWNTIME_MINUTES:-5}"
START_GRACE_SECONDS="${START_GRACE_SECONDS:-45}"
SUMMARY_WEEKDAY="${SUMMARY_WEEKDAY:-7}"
MAX_QUERY_AGE_DAYS="${MAX_QUERY_AGE_DAYS:-4}"
MIN_DISK_FREE_PCT="${MIN_DISK_FREE_PCT:-15}"
MIN_MEM_AVAILABLE_MIB="${MIN_MEM_AVAILABLE_MIB:-150}"
WAL_ALERT_MIB="${WAL_ALERT_MIB:-64}"
WAL_ALERT_STREAK="${WAL_ALERT_STREAK:-2}"
POST_VACUUM_MAX_FREELIST_PCT="${POST_VACUUM_MAX_FREELIST_PCT:-50}"
NO_EMAIL="${NO_EMAIL:-0}"
DRY_RUN="${DRY_RUN:-0}"
MAIL_BIN="${MAIL_BIN:-mail}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another pihole-db-monitor run is already in progress" >&2
  exit 1
fi

touch "$LOG_FILE"
load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  cat >"$STATE_FILE" <<EOF
last_warning_hash='${last_warning_hash//\'/\'\\\'\'}'
wal_large_streak='${wal_large_streak}'
EOF
}

load_state
VACUUM_OUTPUT_FILE=$(mktemp /tmp/pihole-db-monitor.XXXXXX)

before_bytes=0
before_human="unknown"
after_bytes=0
after_human="unknown"
before_total_bytes=0
before_total_human="unknown"
after_total_bytes=0
after_total_human="unknown"
reclaimed_bytes=0
reclaimed_human="0B"
vacuum_status="not-run"
vacuum_detail="VACUUM was not attempted."
restart_status="not-attempted"
restart_detail="Pi-hole FTL did not need to be restarted."
service_was_stopped=0
failsafe_unit=""
deadline_epoch=0
stop_epoch=0
start_epoch=0
date_now=$(date '+%Y-%m-%d %H:%M:%S')
mail_status="not-sent"
mail_detail="Email not attempted."

stats_query_rows="unknown"
stats_query_min_epoch="unknown"
stats_query_max_epoch="unknown"
stats_query_window="unknown"
stats_domain_total="unknown"
stats_domain_referenced="unknown"
stats_domain_unreferenced="unknown"
stats_client_total="unknown"
stats_client_referenced="unknown"
stats_client_unreferenced="unknown"
stats_per_day="unavailable"
stats_size_breakdown="unavailable"
stats_page_size="unknown"
stats_page_count="unknown"
stats_freelist_count="unknown"
stats_freelist_pct="unknown"
stats_journal_mode="unknown"
stats_ftl_state="unknown"
stats_disk_free_pct="unknown"
stats_disk_available_mib="unknown"
stats_mem_available_mib="unknown"
stats_wal_bytes=0
stats_wal_human="0B"
update_banner=""
update_summary="No overdue Pi-hole updates detected."
update_state="ok"
vacuum_day_summary=""
is_summary_day=0
should_email=1
warning_fingerprint=""
mail_subject="Pi-hole DB Maintenance Report"
report_reason_lines="  - Nightly maintenance report."
critical_alerts="  - none"
warning_alerts="  - none"
current_alerts="  - none"
last_warning_hash="${last_warning_hash:-}"
wal_large_streak="${wal_large_streak:-0}"

cleanup() {
  local exit_rc=$?

  if [ "$service_was_stopped" = "1" ] && [ "$restart_status" = "not-attempted" ]; then
    if ! ensure_ftl_running; then
      exit_rc=1
    fi
  fi

  if [ -f "$DB_FILE" ]; then
    after_bytes=$(stat -c%s "$DB_FILE" 2>/dev/null || echo 0)
    after_human=$(to_human "$after_bytes")
  fi
  after_total_bytes=$(sum_db_footprint)
  after_total_human=$(to_human "$after_total_bytes")

  if [ "$before_bytes" -gt "$after_bytes" ]; then
    reclaimed_bytes=$((before_bytes - after_bytes))
    reclaimed_human=$(to_human "$reclaimed_bytes")
  fi

  date_now=$(date '+%Y-%m-%d %H:%M:%S')
  collect_db_stats >>"$VACUUM_OUTPUT_FILE" 2>&1 || true
  collect_runtime_health >>"$VACUUM_OUTPUT_FILE" 2>&1 || true
  decide_email_policy

  echo "$date_now $after_human" >> "$LOG_FILE"

  if ! send_email; then
    exit_rc=1
  fi

  save_state || exit_rc=1
  cancel_failsafe
  rm -f "$VACUUM_OUTPUT_FILE"
  exit "$exit_rc"
}
trap cleanup EXIT

to_human() {
  numfmt --to=iec-i --suffix=B "$1"
}

sum_db_footprint() {
  local total=0
  local file size
  for file in "$DB_FILE" "${DB_FILE}-wal" "${DB_FILE}-shm"; do
    if [ -e "$file" ]; then
      size=$(stat -c%s "$file" 2>/dev/null || echo 0)
      total=$((total + size))
    fi
  done
  echo "$total"
}

sqlite_ro() {
  sudo sqlite3 "file:${DB_FILE}?mode=ro" "$@"
}

join_vacuum_days() {
  local IFS=", "
  echo "${FULL_VACUUM_DAYS[*]}"
}

format_duration() {
  local total_seconds=$1
  local days hours minutes

  if [ "$total_seconds" -lt 60 ]; then
    echo "${total_seconds}s"
    return 0
  fi

  days=$((total_seconds / 86400))
  hours=$(((total_seconds % 86400) / 3600))
  minutes=$(((total_seconds % 3600) / 60))

  if [ "$days" -gt 0 ]; then
    echo "${days}d ${hours}h"
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h ${minutes}m"
  else
    echo "${minutes}m"
  fi
}

should_run_vacuum_today() {
  local today day
  today=$(date '+%-d')
  for day in "${FULL_VACUUM_DAYS[@]}"; do
    if [ "$day" = "$today" ]; then
      return 0
    fi
  done

  return 1
}

format_epoch() {
  if [ -z "$1" ] || [ "$1" = "unknown" ]; then
    echo "unknown"
    return 0
  fi
  date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$1"
}

collect_db_stats() {
  local summary_raw
  local min_ts max_ts

  if ! summary_raw=$(sqlite_ro -separator '|' <<'SQL'
SELECT
  (SELECT COUNT(*) FROM query_storage),
  (SELECT CAST(MIN(timestamp) AS INTEGER) FROM query_storage),
  (SELECT CAST(MAX(timestamp) AS INTEGER) FROM query_storage),
  (SELECT COUNT(*) FROM domain_by_id),
  (SELECT COUNT(DISTINCT domain) FROM query_storage),
  (SELECT COUNT(*) FROM domain_by_id WHERE id NOT IN (SELECT DISTINCT domain FROM query_storage)),
  (SELECT COUNT(*) FROM client_by_id),
  (SELECT COUNT(DISTINCT client) FROM query_storage),
  (SELECT COUNT(*) FROM client_by_id WHERE id NOT IN (SELECT DISTINCT client FROM query_storage));
SQL
  ); then
    stats_per_day="failed to query"
    stats_size_breakdown="failed to query"
    return 1
  fi

  IFS='|' read -r \
    stats_query_rows \
    min_ts \
    max_ts \
    stats_domain_total \
    stats_domain_referenced \
    stats_domain_unreferenced \
    stats_client_total \
    stats_client_referenced \
    stats_client_unreferenced <<< "$summary_raw"

  stats_query_min_epoch="${min_ts:-unknown}"
  stats_query_max_epoch="${max_ts:-unknown}"
  stats_query_window="$(format_epoch "$stats_query_min_epoch") -> $(format_epoch "$stats_query_max_epoch")"

  stats_per_day=$(sqlite_ro -noheader <<'SQL'
SELECT '  - ' || date(timestamp,'unixepoch','localtime') || ': rows=' || COUNT(*) || ', unique_domains=' || COUNT(DISTINCT domain) || ', unique_clients=' || COUNT(DISTINCT client)
FROM query_storage
GROUP BY date(timestamp,'unixepoch','localtime')
ORDER BY date(timestamp,'unixepoch','localtime') DESC
LIMIT 4;
SQL
)
  if [ -z "$stats_per_day" ]; then
    stats_per_day="  - unavailable"
  fi

  stats_size_breakdown=$(sqlite_ro -noheader <<'SQL'
SELECT '  - ' || printf('%-24s', name) || ' ' || printf('%.1f MiB', SUM(pgsize)/1048576.0)
FROM dbstat
WHERE name IN ('query_storage','idx_queries_timestamp','domain_by_id','domain_by_id_domain_idx','client_by_id','client_by_id_client_idx')
GROUP BY name
ORDER BY SUM(pgsize) DESC;
SQL
)
  if [ -z "$stats_size_breakdown" ]; then
    stats_size_breakdown="  - unavailable"
  fi

  stats_page_size=$(sqlite_ro 'PRAGMA page_size;' 2>/dev/null | tr -d '[:space:]')
  stats_page_count=$(sqlite_ro 'PRAGMA page_count;' 2>/dev/null | tr -d '[:space:]')
  stats_freelist_count=$(sqlite_ro 'PRAGMA freelist_count;' 2>/dev/null | tr -d '[:space:]')
  stats_journal_mode=$(sqlite_ro 'PRAGMA journal_mode;' 2>/dev/null | tr -d '[:space:]')

  if [[ "$stats_page_count" =~ ^[0-9]+$ ]] && [ "$stats_page_count" -gt 0 ] && [[ "$stats_freelist_count" =~ ^[0-9]+$ ]]; then
    stats_freelist_pct=$((stats_freelist_count * 100 / stats_page_count))
  else
    stats_freelist_pct="unknown"
  fi
}

check_overdue_updates() {
  local version_json

  version_json=$(curl --max-time 10 -fsSL 'http://127.0.0.1/api/info/version' 2>/dev/null || true)
  if [ -z "$version_json" ]; then
    update_state="unavailable"
    update_summary="Update check unavailable: local version API did not respond."
    return 1
  fi

  local python_output
  python_output=$(LOCAL_VERSION_JSON="$version_json" python3 - <<'PY'
import datetime
import json
import os
import urllib.request

now = datetime.datetime.now(datetime.timezone.utc)
local = json.loads(os.environ["LOCAL_VERSION_JSON"])["version"]
components = [
    ("Core", "pi-hole", "core"),
    ("Web", "web", "web"),
    ("FTL", "FTL", "ftl"),
]
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "pihole-db-monitor",
}
lines = []
errors = []
for label, repo, key in components:
    local_v = local[key]["local"].get("version") or "unknown"
    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/pi-hole/{repo}/releases/latest",
            headers=headers,
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            rel = json.load(resp)
        remote_v = rel.get("tag_name") or rel.get("name") or "unknown"
        published_raw = rel.get("published_at") or rel.get("created_at")
        if not published_raw:
            raise RuntimeError("missing published_at")
        published = datetime.datetime.fromisoformat(published_raw.replace("Z", "+00:00"))
        age_days = (now - published).days
        if local_v != remote_v and age_days >= 7:
            lines.append(
                f"- {label}: local {local_v}, latest {remote_v}, released {published.date().isoformat()} ({age_days} day(s) ago)"
            )
    except Exception as exc:
        errors.append(f"- {label}: update check failed ({exc})")

if lines:
    print("STATE_START")
    print("overdue")
    print("STATE_END")
    print("BANNER_START")
    print("*** UPDATE OVERDUE ***")
    print("Pi-hole updates have been available for more than 1 week:")
    for line in lines:
        print(line)
    print("BANNER_END")
    print("SUMMARY_START")
    for line in lines:
        print(line)
    print("SUMMARY_END")
elif errors:
    print("STATE_START")
    print("incomplete")
    print("STATE_END")
    print("SUMMARY_START")
    print("Update check incomplete:")
    for line in errors:
        print(line)
    print("SUMMARY_END")
else:
    print("STATE_START")
    print("ok")
    print("STATE_END")
    print("SUMMARY_START")
    print("No overdue Pi-hole updates detected.")
    print("SUMMARY_END")
PY
)

  update_banner=$(printf '%s
' "$python_output" | sed -n '/^BANNER_START$/,/^BANNER_END$/p' | sed '1d;$d')
  update_summary=$(printf '%s
' "$python_output" | sed -n '/^SUMMARY_START$/,/^SUMMARY_END$/p' | sed '1d;$d')
  update_state=$(printf '%s
' "$python_output" | sed -n '/^STATE_START$/,/^STATE_END$/p' | sed '1d;$d' | head -n 1)

  if [ -z "$update_summary" ]; then
    update_summary="Update check completed with no additional details."
  fi

  if [ -z "$update_state" ]; then
    if [ -n "$update_banner" ]; then
      update_state="overdue"
    else
      update_state="ok"
    fi
  fi
}

collect_runtime_health() {
  local disk_raw mem_kib

  stats_ftl_state=$(systemctl is-active "$FTL_SERVICE" 2>/dev/null || echo "unknown")

  disk_raw=$(df -Pm "$DB_FILE" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); printf "%s|%s", 100-$5, $4}')
  if [ -n "$disk_raw" ]; then
    IFS='|' read -r stats_disk_free_pct stats_disk_available_mib <<< "$disk_raw"
  fi

  mem_kib=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kib" =~ ^[0-9]+$ ]]; then
    stats_mem_available_mib=$((mem_kib / 1024))
  fi

  stats_wal_bytes=$(stat -c%s "${DB_FILE}-wal" 2>/dev/null || echo 0)
  if ! [[ "$stats_wal_bytes" =~ ^[0-9]+$ ]]; then
    stats_wal_bytes=0
  fi
  stats_wal_human=$(to_human "$stats_wal_bytes")
}

decide_email_policy() {
  local today_weekday now_epoch max_query_age_seconds oldest_age_seconds oldest_age_human
  local wal_threshold_bytes critical_lines warning_lines warning_keys

  today_weekday=$(date '+%u')
  now_epoch=$(date +%s)
  max_query_age_seconds=$((MAX_QUERY_AGE_DAYS * 86400))
  wal_threshold_bytes=$((WAL_ALERT_MIB * 1024 * 1024))
  critical_lines=""
  warning_lines=""
  warning_keys=""

  should_email=0
  is_summary_day=0
  report_reason_lines="  - No alert conditions and not the weekly summary day."
  critical_alerts="  - none"
  warning_alerts="  - none"
  current_alerts="  - none"
  warning_fingerprint=""

  if [ "$today_weekday" = "$SUMMARY_WEEKDAY" ]; then
    is_summary_day=1
    should_email=1
    report_reason_lines="  - Weekly summary day."
  fi

  if [ "$restart_status" = "failed" ]; then
    critical_lines="${critical_lines}  - Pi-hole FTL did not report active within the ${MAX_DOWNTIME_MINUTES}-minute downtime budget.\n"
  fi
  if [ "$vacuum_status" = "failed" ] || [ "$vacuum_status" = "timed_out" ]; then
    critical_lines="${critical_lines}  - Scheduled VACUUM did not complete successfully: ${vacuum_detail}\n"
  fi
  if [ "$stats_ftl_state" != "active" ]; then
    critical_lines="${critical_lines}  - Pi-hole FTL service state is '${stats_ftl_state}'.\n"
  fi
  if [ "$stats_query_rows" = "unknown" ]; then
    critical_lines="${critical_lines}  - Query statistics could not be collected from ${DB_FILE}.\n"
  fi

  if [[ "$stats_query_min_epoch" =~ ^[0-9]+$ ]]; then
    oldest_age_seconds=$((now_epoch - stats_query_min_epoch))
    if [ "$oldest_age_seconds" -gt "$max_query_age_seconds" ]; then
      oldest_age_human=$(format_duration "$oldest_age_seconds")
      warning_keys="${warning_keys}retention-window\n"
      warning_lines="${warning_lines}  - Oldest retained query is ${oldest_age_human} old, beyond the ${MAX_QUERY_AGE_DAYS}-day alert threshold.\n"
    fi
  fi

  if [[ "$stats_disk_free_pct" =~ ^[0-9]+$ ]] && [ "$stats_disk_free_pct" -lt "$MIN_DISK_FREE_PCT" ]; then
    warning_keys="${warning_keys}disk-free\n"
    warning_lines="${warning_lines}  - Disk free space is ${stats_disk_free_pct}% (${stats_disk_available_mib} MiB available), below the ${MIN_DISK_FREE_PCT}% threshold.\n"
  fi

  if [[ "$stats_mem_available_mib" =~ ^[0-9]+$ ]] && [ "$stats_mem_available_mib" -lt "$MIN_MEM_AVAILABLE_MIB" ]; then
    warning_keys="${warning_keys}mem-available\n"
    warning_lines="${warning_lines}  - MemAvailable is ${stats_mem_available_mib} MiB, below the ${MIN_MEM_AVAILABLE_MIB} MiB threshold.\n"
  fi

  if [ "$stats_wal_bytes" -ge "$wal_threshold_bytes" ]; then
    wal_large_streak=$((wal_large_streak + 1))
  else
    wal_large_streak=0
  fi
  if [ "$wal_large_streak" -ge "$WAL_ALERT_STREAK" ]; then
    warning_keys="${warning_keys}wal-large\n"
    warning_lines="${warning_lines}  - WAL file is ${stats_wal_human} for ${wal_large_streak} consecutive night(s), above the ${WAL_ALERT_MIB} MiB threshold.\n"
  fi

  if [ "$update_state" = "overdue" ]; then
    warning_keys="${warning_keys}updates-overdue\n"
    warning_lines="${warning_lines}  - Pi-hole updates have been available for more than 1 week.\n"
  elif [ "$update_state" = "unavailable" ] || [ "$update_state" = "incomplete" ]; then
    warning_keys="${warning_keys}update-check\n"
    warning_lines="${warning_lines}  - ${update_summary}\n"
  fi

  if [ "$service_was_stopped" = "1" ] && [ "$vacuum_status" = "success" ] && [[ "$stats_freelist_pct" =~ ^[0-9]+$ ]] && [ "$stats_freelist_pct" -gt "$POST_VACUUM_MAX_FREELIST_PCT" ]; then
    warning_keys="${warning_keys}post-vacuum-freelist\n"
    warning_lines="${warning_lines}  - SQLite freelist is still ${stats_freelist_pct}% of pages after the scheduled vacuum (${stats_freelist_count}/${stats_page_count}), so the main DB file may not have compacted.\n"
  fi

  if [ -n "$critical_lines" ]; then
    critical_alerts=$(printf '%b' "$critical_lines")
    current_alerts=$(printf '%b' "$critical_lines")
    should_email=1
    report_reason_lines="  - Immediate alert: operational issue detected."
  fi

  if [ -n "$warning_lines" ]; then
    warning_alerts=$(printf '%b' "$warning_lines")
    if [ -n "$critical_lines" ]; then
      current_alerts=$(printf '%b' "${critical_lines}${warning_lines}")
    else
      current_alerts=$warning_alerts
    fi
    warning_fingerprint=$(printf '%b' "$warning_keys" | awk 'NF' | sort -u | sha256sum | awk '{print $1}')
    if [ "$warning_fingerprint" != "$last_warning_hash" ]; then
      should_email=1
      if [ "$report_reason_lines" = "  - Weekly summary day." ]; then
        report_reason_lines="${report_reason_lines}
  - New warning condition(s) detected."
      elif [ "$report_reason_lines" = "  - Immediate alert: operational issue detected." ]; then
        report_reason_lines="${report_reason_lines}
  - New warning condition(s) also detected."
      else
        report_reason_lines="  - New warning condition(s) detected."
      fi
    fi
  fi

  if [ -z "$warning_fingerprint" ]; then
    last_warning_hash=""
  else
    last_warning_hash="$warning_fingerprint"
  fi

  if [ "$NO_EMAIL" = "1" ]; then
    should_email=0
    mail_status="suppressed"
    mail_detail="NO_EMAIL=1"
    return 0
  fi

  if [ "$should_email" != "1" ]; then
    mail_status="suppressed"
    mail_detail="No alert conditions and not the weekly summary day."
    return 0
  fi

  if [ -n "$critical_lines" ]; then
    mail_subject="Pi-hole DB ALERT"
  elif [ "$is_summary_day" = "1" ]; then
    if [ -n "$warning_lines" ]; then
      mail_subject="Pi-hole DB Weekly Summary (Warnings Active)"
    else
      mail_subject="Pi-hole DB Weekly Summary"
    fi
  else
    mail_subject="Pi-hole DB Warning"
  fi
}

schedule_failsafe() {
  if [ "$DRY_RUN" = "1" ]; then
    failsafe_unit="dry-run-failsafe"
    return 0
  fi

  failsafe_unit="pihole-ftl-failsafe-$(date +%s)"
  sudo systemd-run \
    --quiet \
    --unit "$failsafe_unit" \
    --on-active "${MAX_DOWNTIME_MINUTES}m" \
    /bin/systemctl start "$FTL_SERVICE" >>"$VACUUM_OUTPUT_FILE" 2>&1
}

cancel_failsafe() {
  if [ -z "$failsafe_unit" ] || [ "$DRY_RUN" = "1" ]; then
    return 0
  fi

  sudo systemctl cancel "${failsafe_unit}.timer" "${failsafe_unit}.service" >/dev/null 2>&1 || true
  sudo systemctl stop "${failsafe_unit}.timer" "${failsafe_unit}.service" >/dev/null 2>&1 || true
}

ensure_ftl_running() {
  if [ "$DRY_RUN" = "1" ]; then
    restart_status="success"
    restart_detail="Dry run: Pi-hole FTL restart skipped."
    return 0
  fi

  sudo systemctl start "$FTL_SERVICE" >>"$VACUUM_OUTPUT_FILE" 2>&1 || true

  while [ "$(date +%s)" -lt "$deadline_epoch" ]; do
    if systemctl is-active --quiet "$FTL_SERVICE"; then
      start_epoch=$(date +%s)
      restart_status="success"
      restart_detail="Pi-hole FTL is active again."
      return 0
    fi

    sleep 5
    sudo systemctl start "$FTL_SERVICE" >>"$VACUUM_OUTPUT_FILE" 2>&1 || true
  done

  if systemctl is-active --quiet "$FTL_SERVICE"; then
    start_epoch=$(date +%s)
    restart_status="success"
    restart_detail="Pi-hole FTL became active right at the deadline."
    return 0
  fi

  restart_status="failed"
  restart_detail="Pi-hole FTL did not report active within ${MAX_DOWNTIME_MINUTES} minute(s)."
  return 1
}

send_email() {
  local history downtime_summary output_tail update_block

  history=$(tail -n 7 "$LOG_FILE" | tac 2>/dev/null || true)
  output_tail=$(tail -n 20 "$VACUUM_OUTPUT_FILE" 2>/dev/null || true)

  if [ "$service_was_stopped" = "1" ] && [ "$start_epoch" -gt 0 ]; then
    downtime_summary="$((start_epoch - stop_epoch)) second(s)"
  elif [ "$service_was_stopped" = "1" ]; then
    downtime_summary=">= ${MAX_DOWNTIME_MINUTES} minute(s)"
  else
    downtime_summary="0 second(s)"
  fi

  if [ "$should_email" != "1" ]; then
    return 0
  fi

  update_block=""
  if [ -n "$update_banner" ]; then
    update_block="$update_banner

"
  fi

  if "$MAIL_BIN" -s "$mail_subject" "$EMAIL" <<MAIL_EOF
Hello,

${update_block}The Pi-hole DB maintenance run completed at $date_now.

Report reason:
$report_reason_lines

Current alerts:
$current_alerts

Main DB size before VACUUM: $before_human
Main DB size after VACUUM:  $after_human
Approx. DB footprint before (db + wal + shm): $before_total_human
Approx. DB footprint after  (db + wal + shm): $after_total_human
Approx. space reclaimed from main DB file: $reclaimed_human

VACUUM status:  $vacuum_status
VACUUM details: $vacuum_detail
Configured full vacuum days: $vacuum_day_summary

FTL restart status:  $restart_status
FTL restart details: $restart_detail
Maximum allowed downtime: ${MAX_DOWNTIME_MINUTES} minute(s)
Observed downtime:        $downtime_summary

Health checks:
- FTL service state: $stats_ftl_state
- Disk free: ${stats_disk_free_pct}% (${stats_disk_available_mib} MiB available)
- MemAvailable: ${stats_mem_available_mib} MiB
- WAL size: $stats_wal_human
- SQLite freelist: ${stats_freelist_count}/${stats_page_count} pages (${stats_freelist_pct}% free)

Hypothesis check:
- Query rows retained by TTL window: $stats_query_rows
- Retained query window: $stats_query_window
- domain_by_id rows: total=$stats_domain_total, referenced_now=$stats_domain_referenced, unreferenced_now=$stats_domain_unreferenced
- client_by_id rows: total=$stats_client_total, referenced_now=$stats_client_referenced, unreferenced_now=$stats_client_unreferenced

Retained query counts by day:
$stats_per_day

Approximate DB object sizes:
$stats_size_breakdown

Update status:
$update_summary

Recent history (last 7 entries):
$history

Recent command output:
$output_tail

Best regards,
Pi-hole Monitor Script
MAIL_EOF
  then
    mail_status="sent"
    mail_detail="Email sent successfully."
    return 0
  fi

  mail_status="failed"
  mail_detail="Failed to send email via $MAIL_BIN."
  echo "$mail_detail" >&2
  return 1
}

if ! before_bytes=$(stat -c%s "$DB_FILE" 2>/dev/null); then
  vacuum_status="failed"
  vacuum_detail="Could not stat $DB_FILE."
  exit 1
fi
before_human=$(to_human "$before_bytes")
before_total_bytes=$(sum_db_footprint)
before_total_human=$(to_human "$before_total_bytes")
vacuum_day_summary="$(join_vacuum_days)"

collect_db_stats || echo "DB stats collection failed" >>"$VACUUM_OUTPUT_FILE"
collect_runtime_health || echo "Runtime health collection failed" >>"$VACUUM_OUTPUT_FILE"
check_overdue_updates || echo "Update check failed" >>"$VACUUM_OUTPUT_FILE"

total_budget_seconds=$((MAX_DOWNTIME_MINUTES * 60))
if [ "$total_budget_seconds" -lt 60 ]; then
  total_budget_seconds=60
fi
if [ "$START_GRACE_SECONDS" -ge "$total_budget_seconds" ]; then
  START_GRACE_SECONDS=15
fi
vacuum_budget_seconds=$((total_budget_seconds - START_GRACE_SECONDS))
if [ "$vacuum_budget_seconds" -lt 15 ]; then
  vacuum_budget_seconds=15
fi

deadline_epoch=$(( $(date +%s) + total_budget_seconds ))

if [ "$DRY_RUN" = "1" ]; then
  if should_run_vacuum_today; then
    vacuum_status="success"
    vacuum_detail="Dry run: today is a configured vacuum day, but Pi-hole FTL stop/start and VACUUM were skipped."
    restart_status="success"
    restart_detail="Dry run: Pi-hole FTL restart was not required."
  else
    vacuum_status="skipped"
    vacuum_detail="Dry run: today is not one of the configured full vacuum days (${vacuum_day_summary}), so no stop/vacuum/start would be attempted."
    restart_status="not-needed"
    restart_detail="Dry run: Pi-hole FTL restart was not required."
  fi
  exit 0
fi

if ! should_run_vacuum_today; then
  vacuum_status="skipped"
  vacuum_detail="Today is not one of the configured full vacuum days (${vacuum_day_summary}), so Pi-hole FTL was left running and VACUUM was not attempted."
  restart_status="not-needed"
  restart_detail="Pi-hole FTL was intentionally left running on this nightly report-only run."
  exit 0
fi

if ! schedule_failsafe; then
  vacuum_status="failed"
  vacuum_detail="Failed to schedule the failsafe restart timer, so Pi-hole FTL was not stopped."
  exit 1
fi

stop_epoch=$(date +%s)
if ! sudo systemctl stop "$FTL_SERVICE" >>"$VACUUM_OUTPUT_FILE" 2>&1; then
  vacuum_status="failed"
  vacuum_detail="Failed to stop $FTL_SERVICE, so VACUUM was not attempted."
  exit 1
fi
service_was_stopped=1

if timeout --kill-after=15s "${vacuum_budget_seconds}s" sudo sqlite3 "$DB_FILE" 'VACUUM;' >>"$VACUUM_OUTPUT_FILE" 2>&1; then
  vacuum_status="success"
  vacuum_detail="VACUUM completed within ${vacuum_budget_seconds} second(s)."
  exit 0
fi

vacuum_rc=$?
if [ "$vacuum_rc" -eq 124 ] || [ "$vacuum_rc" -eq 137 ]; then
  vacuum_status="timed_out"
  vacuum_detail="VACUUM exceeded the ${vacuum_budget_seconds}-second budget and was terminated so Pi-hole FTL could be restarted before the ${MAX_DOWNTIME_MINUTES}-minute deadline."
else
  vacuum_status="failed"
  vacuum_detail="VACUUM exited with status $vacuum_rc."
fi

exit 1

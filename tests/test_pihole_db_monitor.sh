#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/pihole-db-monitor.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pihole-db-monitor-tests.XXXXXX")"
REAL_PYTHON3="${REAL_PYTHON3:-$(command -v python3)}"

if [ -z "$REAL_PYTHON3" ]; then
  echo "python3 is required to run the test harness" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
CASE_DIR=""
MOCK_BIN="$TMP_ROOT/mock-bin"

write_mock() {
  local name="$1"
  local path="$MOCK_BIN/$name"
  mkdir -p "$MOCK_BIN"
  cat >"$path"
  chmod +x "$path"
}

write_mocks() {
  write_mock flock <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  write_mock sudo <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  if [ "$arg" = "-n" ]; then
    continue
  fi
  args+=("$arg")
done
exec "${args[@]}"
EOF

  write_mock stat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-c%s" ] && [ $# -eq 2 ]; then
  wc -c <"$2" | tr -d '[:space:]'
  exit 0
fi
echo "unsupported mock stat invocation: $*" >&2
exit 1
EOF

  write_mock numfmt <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
value="${@: -1}"
"$REAL_PYTHON3" - "$value" <<'PY'
import sys

value = int(sys.argv[1])
units = ["B", "KiB", "MiB", "GiB", "TiB"]
size = float(value)
unit = units[0]
for candidate in units:
    unit = candidate
    if size < 1024 or candidate == units[-1]:
        break
    size /= 1024.0

if unit == "B":
    print(f"{int(size)}{unit}")
elif size >= 10:
    print(f"{int(round(size))}{unit}")
else:
    print(f"{size:.1f}{unit}")
PY
EOF

  write_mock tac <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; --i) print lines[i] }' "$@"
EOF

  write_mock sha256sum <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_PYTHON3" - <<'PY'
import hashlib
import sys

data = sys.stdin.buffer.read()
print(hashlib.sha256(data).hexdigest() + "  -")
PY
EOF

  write_mock date <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

epoch="${MOCK_NOW_EPOCH:-1704067200}"
fmt="+%a %b %e %H:%M:%S UTC %Y"

if [ "${1:-}" = "-d" ]; then
  epoch="${2#@}"
  fmt="${3:-$fmt}"
elif [ $# -ge 1 ]; then
  fmt="$1"
fi

"$REAL_PYTHON3" - "$epoch" "$fmt" <<'PY'
import datetime
import sys

epoch = int(sys.argv[1])
fmt = sys.argv[2]
dt = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)

known = {
    "+%s": str(epoch),
    "+%-d": str(dt.day),
    "+%u": str(dt.isoweekday()),
    "+%Y-%m-%d %H:%M:%S": dt.strftime("%Y-%m-%d %H:%M:%S"),
    "+%Y-%m-%d %H:%M:%S %Z": dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
}

if fmt in known:
    print(known[fmt])
elif fmt.startswith("+"):
    print(dt.strftime(fmt[1:]))
else:
    print(dt.strftime(fmt))
PY
EOF

  write_mock sqlite3 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

all_args="$*"

if [[ "$all_args" == *"VACUUM;"* ]]; then
  exit "${MOCK_SQLITE_VACUUM_RC:-0}"
fi

if [[ "$all_args" == *"PRAGMA page_size;"* ]]; then
  printf '%s\n' "${MOCK_SQLITE_PAGE_SIZE:-4096}"
  exit 0
fi

if [[ "$all_args" == *"PRAGMA page_count;"* ]]; then
  printf '%s\n' "${MOCK_SQLITE_PAGE_COUNT:-1000}"
  exit 0
fi

if [[ "$all_args" == *"PRAGMA freelist_count;"* ]]; then
  printf '%s\n' "${MOCK_SQLITE_FREELIST_COUNT:-100}"
  exit 0
fi

if [[ "$all_args" == *"PRAGMA journal_mode;"* ]]; then
  printf '%s\n' "${MOCK_SQLITE_JOURNAL_MODE:-wal}"
  exit 0
fi

if [[ "$all_args" == *"-separator"* ]]; then
  printf '%s\n' "${MOCK_SQLITE_SUMMARY_RAW:-0|0|0|0|0|0|0|0|0}"
  exit 0
fi

if [[ "$all_args" == *"-noheader"* ]]; then
  query="$(cat)"
  if [[ "$query" == *"GROUP BY date(timestamp"* ]]; then
    printf '%b\n' "${MOCK_SQLITE_PER_DAY:-  - unavailable}"
  else
    printf '%b\n' "${MOCK_SQLITE_SIZE_BREAKDOWN:-  - unavailable}"
  fi
  exit 0
fi

exit 0
EOF

  write_mock systemctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${MOCK_SYSTEMCTL_STATE_FILE:?}"
state="inactive"
if [ -f "$state_file" ]; then
  state="$(cat "$state_file")"
fi

  cmd="${1:-}"
target="${2:-}"
  case "$cmd" in
  is-active)
    if [ "${2:-}" = "--quiet" ]; then
      if [ "$state" = "active" ]; then
        exit 0
      fi
      exit 3
    fi
    printf '%s\n' "$state"
    if [ "$state" = "active" ]; then
      exit 0
    fi
    exit 3
    ;;
  start)
    if [ "$target" = "pihole-FTL" ]; then
      printf 'active' >"$state_file"
    fi
    exit "${MOCK_SYSTEMCTL_START_RC:-0}"
    ;;
  stop)
    if [ "$target" = "pihole-FTL" ]; then
      printf 'inactive' >"$state_file"
    fi
    exit "${MOCK_SYSTEMCTL_STOP_RC:-0}"
    ;;
  cancel)
    exit 0
    ;;
  *)
    echo "unsupported mock systemctl invocation: $*" >&2
    exit 1
    ;;
esac
EOF

  write_mock systemd-run <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit "${MOCK_SYSTEMD_RUN_RC:-0}"
EOF

  write_mock timeout <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --kill-after=*)
      shift
      ;;
    *s|*m|*h)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

rc="${MOCK_TIMEOUT_RC:-0}"
if [ "$rc" != "0" ]; then
  exit "$rc"
fi

exec "$@"
EOF

  write_mock curl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${MOCK_LOCAL_VERSION_JSON:-{\"version\":{}}}"
EOF

  write_mock python3 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${MOCK_UPDATE_MODE:-ok}" in
  overdue)
    cat <<'OUT'
STATE_START
overdue
STATE_END
BANNER_START
*** UPDATE OVERDUE ***
Pi-hole updates have been available for more than 1 week:
- FTL: local v6.6.1, latest v6.6.2, released 2026-05-11 (19 day(s) ago)
BANNER_END
SUMMARY_START
- FTL: local v6.6.1, latest v6.6.2, released 2026-05-11 (19 day(s) ago)
SUMMARY_END
OUT
    ;;
  incomplete)
    cat <<'OUT'
STATE_START
incomplete
STATE_END
SUMMARY_START
Update check incomplete:
- FTL: update check failed (mocked failure)
SUMMARY_END
OUT
    ;;
  *)
    cat <<'OUT'
STATE_START
ok
STATE_END
SUMMARY_START
No overdue Pi-hole updates detected.
SUMMARY_END
OUT
    ;;
esac
EOF

  write_mock df <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
free_pct="${MOCK_DF_FREE_PCT:-80}"
avail="${MOCK_DF_AVAILABLE_MIB:-24000}"
used_pct=$((100 - free_pct))
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
printf 'mockfs 30000 %s %s %s%% /\n' "$((30000 - avail))" "$avail" "$used_pct"
EOF

  write_mock mail <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
subject=""
recipient=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s)
      subject="$2"
      shift 2
      ;;
    *)
      recipient="$1"
      shift
      ;;
  esac
done

body="$(cat)"
printf '%s' "$subject" >"$MOCK_MAIL_SUBJECT_FILE"
printf '%s' "$body" >"$MOCK_MAIL_BODY_FILE"
count=0
if [ -f "$MOCK_MAIL_COUNT_FILE" ]; then
  count="$(cat "$MOCK_MAIL_COUNT_FILE")"
fi
printf '%s' "$((count + 1))" >"$MOCK_MAIL_COUNT_FILE"
printf '%s\n' "$recipient" >"$MOCK_MAIL_RECIPIENT_FILE"
EOF
}

epoch_utc() {
  "$REAL_PYTHON3" - "$1" <<'PY'
import datetime
import sys

dt = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")
dt = dt.replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
PY
}

make_file_of_size() {
  "$REAL_PYTHON3" - "$1" "$2" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
size = int(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("wb") as handle:
    handle.truncate(size)
PY
}

reset_case() {
  CASE_DIR="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
  mkdir -p "$CASE_DIR/home/.cache"
  printf 'active' >"$CASE_DIR/systemctl.state"
  : >"$CASE_DIR/pihole-db-size.log"
  printf '0' >"$CASE_DIR/mail-count"
  make_file_of_size "$CASE_DIR/pihole-FTL.db" "${CASE_DB_BYTES:-37748736}"
  make_file_of_size "$CASE_DIR/pihole-FTL.db-wal" "${CASE_WAL_BYTES:-1048576}"
  make_file_of_size "$CASE_DIR/pihole-FTL.db-shm" 32768
}

clear_mail_capture() {
  rm -f "$CASE_DIR/mail-subject" "$CASE_DIR/mail-body" "$CASE_DIR/mail-recipient"
  printf '0' >"$CASE_DIR/mail-count"
}

run_monitor() {
  local run_name="${1:-run}"
  local stdout_file="$CASE_DIR/${run_name}.stdout"
  local stderr_file="$CASE_DIR/${run_name}.stderr"

  (
    export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    export REAL_PYTHON3
    export TZ=UTC

    export DB_FILE="$CASE_DIR/pihole-FTL.db"
    export LOG_FILE="$CASE_DIR/pihole-db-size.log"
    export LOCK_FILE="$CASE_DIR/lock"
    export STATE_FILE="$CASE_DIR/state"
    export EMAIL="test@example.com"
    export MAIL_BIN="mail"
    export FULL_VACUUM_DAYS="${FULL_VACUUM_DAYS:-1 15}"
    export MAX_DOWNTIME_MINUTES="${MAX_DOWNTIME_MINUTES:-5}"
    export START_GRACE_SECONDS="${START_GRACE_SECONDS:-45}"
    export SUMMARY_WEEKDAY="${SUMMARY_WEEKDAY:-7}"
    export MAX_QUERY_AGE_DAYS="${MAX_QUERY_AGE_DAYS:-4}"
    export MIN_DISK_FREE_PCT="${MIN_DISK_FREE_PCT:-15}"
    export MIN_MEM_AVAILABLE_MIB="${MIN_MEM_AVAILABLE_MIB:-150}"
    export WAL_ALERT_MIB="${WAL_ALERT_MIB:-64}"
    export WAL_ALERT_STREAK="${WAL_ALERT_STREAK:-2}"
    export POST_VACUUM_MAX_FREELIST_PCT="${POST_VACUUM_MAX_FREELIST_PCT:-50}"
    export NO_EMAIL="${NO_EMAIL:-0}"
    export DRY_RUN="${DRY_RUN:-1}"

    export MOCK_SYSTEMCTL_STATE_FILE="$CASE_DIR/systemctl.state"
    export MOCK_MAIL_SUBJECT_FILE="$CASE_DIR/mail-subject"
    export MOCK_MAIL_BODY_FILE="$CASE_DIR/mail-body"
    export MOCK_MAIL_COUNT_FILE="$CASE_DIR/mail-count"
    export MOCK_MAIL_RECIPIENT_FILE="$CASE_DIR/mail-recipient"
    export MOCK_LOCAL_VERSION_JSON='{"version":{"core":{"local":{"version":"v6.4.2"}},"web":{"local":{"version":"v6.5.1"}},"ftl":{"local":{"version":"v6.6.2"}}}}'

    bash "$SCRIPT"
  ) >"$stdout_file" 2>"$stderr_file"
}

mail_count() {
  if [ -f "$CASE_DIR/mail-count" ]; then
    cat "$CASE_DIR/mail-count"
  else
    printf '0'
  fi
}

mail_subject() {
  cat "$CASE_DIR/mail-subject"
}

mail_body() {
  cat "$CASE_DIR/mail-body"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    echo "ASSERT_EQ failed: $message" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ASSERT_CONTAINS failed: $message" >&2
    echo "  missing: $needle" >&2
    return 1
  fi
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq "$needle" "$path"; then
    echo "ASSERT_FILE_CONTAINS failed: $message" >&2
    echo "  file: $path" >&2
    echo "  missing: $needle" >&2
    return 1
  fi
}

test_weekly_summary_email_on_sunday() {
  local min_epoch max_epoch
  reset_case
  clear_mail_capture

  export DRY_RUN=1
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-21 19:34:26")"
  min_epoch="$(epoch_utc "2026-06-18 03:26:01")"
  max_epoch="$(epoch_utc "2026-06-21 19:33:29")"
  export MOCK_UPDATE_MODE=ok
  export MOCK_SQLITE_SUMMARY_RAW="114667|${min_epoch}|${max_epoch}|52662|2879|49783|247|64|183"
  export MOCK_SQLITE_PER_DAY=$'  - 2026-06-21: rows=36518, unique_domains=2003, unique_clients=52\n  - 2026-06-20: rows=10060, unique_domains=427, unique_clients=41'
  export MOCK_SQLITE_SIZE_BREAKDOWN=$'  - query_storage            4.8 MiB\n  - idx_queries_timestamp    2.3 MiB'
  export MOCK_SQLITE_PAGE_COUNT=9129
  export MOCK_SQLITE_FREELIST_COUNT=6207
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253

  run_monitor sunday

  assert_eq "1" "$(mail_count)" "weekly summary should send exactly one email" || return 1
  assert_eq "Pi-hole DB Weekly Summary" "$(mail_subject)" "weekly summary should use the summary subject" || return 1
  assert_contains "$(mail_body)" "Weekly summary day." "summary email should explain why it was sent" || return 1
  assert_contains "$(mail_body)" "Current alerts:" "summary email should include alert section" || return 1
}

test_healthy_weekday_is_suppressed() {
  local min_epoch max_epoch
  reset_case
  clear_mail_capture

  export DRY_RUN=1
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-24 09:00:00")"
  min_epoch="$(epoch_utc "2026-06-21 09:00:00")"
  max_epoch="$(epoch_utc "2026-06-24 08:59:00")"
  export MOCK_UPDATE_MODE=ok
  export MOCK_SQLITE_SUMMARY_RAW="114667|${min_epoch}|${max_epoch}|52662|2879|49783|247|64|183"
  export MOCK_SQLITE_PER_DAY='  - 2026-06-24: rows=1000, unique_domains=20, unique_clients=3'
  export MOCK_SQLITE_SIZE_BREAKDOWN='  - query_storage            4.8 MiB'
  export MOCK_SQLITE_PAGE_COUNT=5000
  export MOCK_SQLITE_FREELIST_COUNT=300
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253

  run_monitor weekday

  assert_eq "0" "$(mail_count)" "healthy weekday should not send email" || return 1
  assert_file_contains "$CASE_DIR/state" "last_warning_hash=''" "healthy weekday should keep an empty warning hash" || return 1
}

test_overdue_update_warning_only_emails_once() {
  local min_epoch max_epoch
  reset_case

  export DRY_RUN=1
  export MOCK_UPDATE_MODE=overdue
  min_epoch="$(epoch_utc "2026-06-21 09:00:00")"
  max_epoch="$(epoch_utc "2026-06-24 08:59:00")"
  export MOCK_SQLITE_SUMMARY_RAW="114667|${min_epoch}|${max_epoch}|52662|2879|49783|247|64|183"
  export MOCK_SQLITE_PER_DAY='  - 2026-06-24: rows=1000, unique_domains=20, unique_clients=3'
  export MOCK_SQLITE_SIZE_BREAKDOWN='  - query_storage            4.8 MiB'
  export MOCK_SQLITE_PAGE_COUNT=5000
  export MOCK_SQLITE_FREELIST_COUNT=300
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253

  clear_mail_capture
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-24 09:00:00")"
  run_monitor overdue-first

  assert_eq "1" "$(mail_count)" "first overdue update warning should send email" || return 1
  assert_eq "Pi-hole DB Warning" "$(mail_subject)" "new warning should use warning subject" || return 1
  assert_contains "$(mail_body)" "Pi-hole updates have been available for more than 1 week." "warning email should mention overdue updates" || return 1

  clear_mail_capture
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-25 09:00:00")"
  run_monitor overdue-second

  assert_eq "0" "$(mail_count)" "same overdue warning should not re-email on the next weekday" || return 1
}

test_vacuum_timeout_sends_alert() {
  local min_epoch max_epoch
  reset_case
  clear_mail_capture

  export DRY_RUN=0
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-07-01 02:00:01")"
  min_epoch="$(epoch_utc "2026-06-30 02:00:00")"
  max_epoch="$(epoch_utc "2026-07-01 01:59:59")"
  export MOCK_UPDATE_MODE=ok
  export MOCK_SQLITE_SUMMARY_RAW="2000|${min_epoch}|${max_epoch}|100|40|60|10|5|5"
  export MOCK_SQLITE_PER_DAY='  - 2026-07-01: rows=2000, unique_domains=40, unique_clients=5'
  export MOCK_SQLITE_SIZE_BREAKDOWN='  - query_storage            2.0 MiB'
  export MOCK_SQLITE_PAGE_COUNT=1000
  export MOCK_SQLITE_FREELIST_COUNT=100
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253
  export MOCK_TIMEOUT_RC=124

  if run_monitor vacuum-timeout; then
    echo "expected vacuum timeout run to exit non-zero" >&2
    return 1
  fi

  unset MOCK_TIMEOUT_RC

  assert_eq "1" "$(mail_count)" "vacuum timeout should send an alert email" || return 1
  assert_eq "Pi-hole DB ALERT" "$(mail_subject)" "vacuum timeout should use alert subject" || return 1
  assert_contains "$(mail_body)" "Scheduled VACUUM did not complete successfully" "alert email should explain the vacuum failure" || return 1
  assert_eq "active" "$(cat "$CASE_DIR/systemctl.state")" "cleanup should leave FTL active after alert handling" || return 1
}

test_successful_vacuum_day_does_not_email_when_healthy() {
  local min_epoch max_epoch
  reset_case
  clear_mail_capture

  export DRY_RUN=0
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-07-01 02:00:01")"
  min_epoch="$(epoch_utc "2026-06-30 02:00:00")"
  max_epoch="$(epoch_utc "2026-07-01 01:59:59")"
  export MOCK_UPDATE_MODE=ok
  export MOCK_SQLITE_SUMMARY_RAW="2000|${min_epoch}|${max_epoch}|100|40|60|10|5|5"
  export MOCK_SQLITE_PER_DAY='  - 2026-07-01: rows=2000, unique_domains=40, unique_clients=5'
  export MOCK_SQLITE_SIZE_BREAKDOWN='  - query_storage            2.0 MiB'
  export MOCK_SQLITE_PAGE_COUNT=1000
  export MOCK_SQLITE_FREELIST_COUNT=100
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253

  run_monitor vacuum-success

  assert_eq "0" "$(mail_count)" "healthy successful vacuum day should not email on a weekday" || return 1
  assert_eq "active" "$(cat "$CASE_DIR/systemctl.state")" "successful vacuum day should leave FTL active" || return 1
}

test_wal_streak_requires_two_nights() {
  local min_epoch max_epoch
  reset_case

  make_file_of_size "$CASE_DIR/pihole-FTL.db-wal" $((80 * 1024 * 1024))
  export DRY_RUN=1
  export MOCK_UPDATE_MODE=ok
  min_epoch="$(epoch_utc "2026-06-21 09:00:00")"
  max_epoch="$(epoch_utc "2026-06-24 08:59:00")"
  export MOCK_SQLITE_SUMMARY_RAW="114667|${min_epoch}|${max_epoch}|52662|2879|49783|247|64|183"
  export MOCK_SQLITE_PER_DAY='  - 2026-06-24: rows=1000, unique_domains=20, unique_clients=3'
  export MOCK_SQLITE_SIZE_BREAKDOWN='  - query_storage            4.8 MiB'
  export MOCK_SQLITE_PAGE_COUNT=5000
  export MOCK_SQLITE_FREELIST_COUNT=300
  export MOCK_DF_FREE_PCT=79
  export MOCK_DF_AVAILABLE_MIB=22253

  clear_mail_capture
  export MOCK_NOW_EPOCH
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-24 09:00:00")"
  run_monitor wal-first

  assert_eq "0" "$(mail_count)" "first large WAL night should not email before the streak threshold" || return 1
  assert_file_contains "$CASE_DIR/state" "wal_large_streak='1'" "first large WAL night should persist streak state" || return 1

  clear_mail_capture
  MOCK_NOW_EPOCH="$(epoch_utc "2026-06-25 09:00:00")"
  run_monitor wal-second

  assert_eq "1" "$(mail_count)" "second consecutive large WAL night should email" || return 1
  assert_eq "Pi-hole DB Warning" "$(mail_subject)" "WAL streak warning should use warning subject" || return 1
  assert_contains "$(mail_body)" "WAL file is" "WAL streak email should mention the WAL condition" || return 1
  assert_file_contains "$CASE_DIR/state" "wal_large_streak='2'" "second large WAL night should persist the updated streak" || return 1
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'not ok - %s\n' "$name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

write_mocks

run_test "weekly summary email on Sunday" test_weekly_summary_email_on_sunday
run_test "healthy weekday is suppressed" test_healthy_weekday_is_suppressed
run_test "overdue update warning only emails once" test_overdue_update_warning_only_emails_once
run_test "vacuum timeout sends alert" test_vacuum_timeout_sends_alert
run_test "successful vacuum day stays quiet when healthy" test_successful_vacuum_day_does_not_email_when_healthy
run_test "wal streak requires two nights" test_wal_streak_requires_two_nights

printf '\nPassed: %s\nFailed: %s\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi

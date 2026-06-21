# pihole-tools

Small utilities for running and maintaining a Pi-hole installation.

## Included

`pihole-db-monitor.sh`

- Checks the size of `/etc/pihole/pihole-FTL.db`
- Logs the current DB size to a local history file
- Sends a weekly summary plus alert-on-change emails instead of a nightly report
- Attempts a scheduled `VACUUM` only on specific calendar days
- Stops and restarts `pihole-FTL` safely for the vacuum window on those scheduled days
- Schedules a failsafe restart so FTL comes back within the configured downtime budget on vacuum days
- Emails immediately for new warning conditions or operational failures

`pihole-db-compact-once.sh`

- Standalone one-time compaction helper for manual use
- Captures before/after DB snapshots
- Creates a timestamped backup before touching the DB
- Schedules a failsafe restart before stopping `pihole-FTL`
- Runs a checkpoint + `VACUUM` with explicit step-by-step logging
- Restarts `pihole-FTL` and verifies that it comes back up
- Writes a verbose timestamped log file for postmortem debugging

## When Email Is Sent

- Every Sunday by default for a weekly summary
- Immediately when a new warning condition appears
- Immediately when an operational failure happens, such as a failed vacuum or failed FTL restart
- Not sent on normal healthy weekdays once the current warning state is unchanged

The script keeps a small state file so persistent warnings such as overdue updates do not re-email every night.

## What The Email Reports

- Main DB size before and after vacuum
- Approximate total SQLite footprint (`db + wal + shm`)
- Whether `VACUUM` succeeded, failed, or timed out
- Whether `VACUUM` was intentionally skipped on a report-only night
- Whether `pihole-FTL` came back within the configured deadline
- Why the email was sent
- Current alert conditions, if any
- FTL state, free disk, available memory, WAL size, and SQLite freelist usage
- Retained `query_storage` row count and timestamp window
- `domain_by_id` totals versus currently referenced rows
- `client_by_id` totals versus currently referenced rows
- A short per-day retained query summary
- Approximate object sizes for the biggest DB structures
- A top-of-email overdue update warning when a newer Pi-hole release has been available for more than 7 days

## Current Hypothesis

The script includes stats meant to test whether long-term DB growth is mostly caused by:

1. A larger current rolling query window
2. Accumulating unreferenced linking-table rows such as `domain_by_id`
3. Normal SQLite file-allocation behavior

In practice, the most important lines to watch over time are:

- `Query rows retained by TTL window`
- `domain_by_id rows: total=..., referenced_now=..., unreferenced_now=...`
- `client_by_id rows: total=..., referenced_now=..., unreferenced_now=...`

## Runtime Defaults

The script supports environment overrides for:

- `DB_FILE`
- `LOG_FILE`
- `EMAIL`
- `FTL_SERVICE`
- `LOCK_FILE`
- `STATE_FILE`
- `FULL_VACUUM_DAYS`
- `MAX_DOWNTIME_MINUTES`
- `START_GRACE_SECONDS`
- `SUMMARY_WEEKDAY`
- `MAX_QUERY_AGE_DAYS`
- `MIN_DISK_FREE_PCT`
- `MIN_MEM_AVAILABLE_MIB`
- `WAL_ALERT_MIB`
- `WAL_ALERT_STREAK`
- `POST_VACUUM_MAX_FREELIST_PCT`
- `NO_EMAIL`
- `DRY_RUN`
- `MAIL_BIN`

The live Pi currently uses:

- `DB_FILE=/etc/pihole/pihole-FTL.db`
- `LOG_FILE=/home/pi/pihole-db-size.log`
- `FTL_SERVICE=pihole-FTL`
- `STATE_FILE=/home/pi/.cache/pihole-db-monitor.state`
- `FULL_VACUUM_DAYS=(1 15)`
- `MAX_DOWNTIME_MINUTES=5`
- `SUMMARY_WEEKDAY=7` (Sunday)
- `MAX_QUERY_AGE_DAYS=4`
- `MIN_DISK_FREE_PCT=15`
- `MIN_MEM_AVAILABLE_MIB=150`
- `WAL_ALERT_MIB=64`
- `WAL_ALERT_STREAK=2`
- `POST_VACUUM_MAX_FREELIST_PCT=50`

The standalone one-time compaction helper supports:

- `DB_FILE`
- `FTL_SERVICE`
- `LOG_DIR`
- `BACKUP_DIR`
- `MAX_DOWNTIME_MINUTES`
- `START_WAIT_SECONDS`
- `VACUUM_TIMEOUT_SECONDS`

## Expected Scheduling

Example crontab entry:

```cron
0 2 * * * /usr/local/bin/pihole-db-monitor.sh
```

With the current defaults:

- Every night at `2:00 AM`: gather stats and evaluate alert conditions
- Every Sunday: send the weekly summary email
- On the `1st` and `15th` of each month: also do the full stop/vacuum/start maintenance path
- On healthy weekdays with no new warning state: do not send email

## Operational Notes

- `DRY_RUN=1` skips the live stop/vacuum/start path but still gathers stats and evaluates whether that run would have sent email.
- `FULL_VACUUM_DAYS` is a shell-style list of numeric day-of-month values, for example `1 15`.
- `SUMMARY_WEEKDAY` uses `date +%u` numbering, where `7` is Sunday.
- The script expects passwordless `sudo` for the required `sqlite3`, `systemctl`, and `systemd-run` operations.
- `VACUUM` is done with FTL stopped because SQLite needs exclusive access to compact the file reliably.
- The failsafe restart timer is scheduled before FTL is stopped, so there is a second path to bring DNS back if the main script stalls.
- The nightly restart was removed because restarting FTL every day appears to prevent Pi-hole's own `maxDBdays` retention cleanup from firing reliably.

## Manual Compaction Helper

Install or run:

```bash
/usr/local/bin/pihole-db-compact-once.sh
```

Useful flags:

```bash
/usr/local/bin/pihole-db-compact-once.sh --dry-run
/usr/local/bin/pihole-db-compact-once.sh --help
```

Default output locations:

- Logs: `/home/pi/pihole-db-maintenance-logs`
- Backups: `/home/pi/pihole-db-backups`

The helper is intentionally noisy. It logs:

- every step name
- the exact command being run
- command return codes
- before/after SQLite page and freelist counts
- before/after retained query windows
- whether `pihole-FTL` was stopped, restarted, or recovered by the cleanup trap

## Repository Notes

This repository is intended to be the source of truth for the Pi-hole maintenance script rather than leaving the only working copy on the Raspberry Pi itself.

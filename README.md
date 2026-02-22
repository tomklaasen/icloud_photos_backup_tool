# iCloud Photos Backup Tool

Wrapper around [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) that runs shared and personal library backups sequentially, with log rotation and [healthchecks.io](https://healthchecks.io) monitoring.

## Setup

1. Install [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) and authenticate.
2. Copy the example config and fill in your values:
   ```sh
   cp backup.conf.example backup.conf
   ```
3. Edit `backup.conf` — set your `HC_PING_URL` and adjust paths if needed.
4. Add a cron entry:
   ```
   10 18 * * * export TZ=Europe/Brussels; /path/to/backup.sh
   ```

## Configuration

All settings live in `backup.conf` (git-ignored). See `backup.conf.example` for the template.

| Variable | Required | Description |
|---|---|---|
| `ICLOUDPD_BIN` | yes | Path to the `icloudpd` binary |
| `BACKUP_DIR` | yes | Where photos are downloaded to |
| `USERNAME` | yes | iCloud username |
| `UNTIL_FOUND` | yes | Stop after N consecutive already-downloaded photos |
| `SHARED_LIBRARY` | no | iCloud shared library ID (omit to skip shared backup) |
| `COOKIE_DIRECTORY` | no | icloudpd session/cookie directory (default: `~/.pyicloud`) |
| `SESSION_MAX_AGE_DAYS` | no | Max session age in days before skipping backup (default: 14) |
| `LOG_FILE` | no | Path to log file (omit to log to stdout) |
| `LOG_MAX_SIZE_KB` | no | Log rotation threshold in KB (default: 10240) |
| `LOG_KEEP` | no | Number of rotated log files to keep (default: 5) |
| `HC_PING_URL` | no | Healthchecks.io ping URL (omit to disable monitoring) |

## What it does

1. Checks session freshness — if the icloudpd session cookie is older than `SESSION_MAX_AGE_DAYS`, the backup is skipped entirely to avoid triggering MFA push notifications on your phone. A `/fail` ping is sent with instructions to re-authenticate.
2. Pings healthchecks.io `/start`
3. Runs shared library backup (if `SHARED_LIBRARY` is set)
4. Runs personal library backup
5. Pings healthchecks.io with a summary or `/fail` on error

The summary sent to healthchecks.io includes:
- Per-library status (OK/FAILED) and count of newly downloaded photos
- Total new photos across both libraries
- Date of the most recent photo in the backup (derived from the `YYYY/MM/DD` directory structure)

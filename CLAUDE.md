# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-file bash backup script (`backup.sh`) that uses `rclone` + `7za` to back up local directories to remote destinations, then sends an HTML email report via the Brevo API. Configured entirely through a `.env` file. Intended to run as a cron job.

## Running

```sh
cp .env.sample .env   # then fill in values
./backup.sh
```

No build, lint, or test suite. Verify changes by running `backup.sh` against a non-production `.env` (e.g. a local rclone remote and a throwaway path).

## Architecture

`backup.sh` is the entire codebase. Key flow:

1. **Lock** (`/tmp/backup-bash.lock`) prevents concurrent runs; released via an EXIT trap.
2. **`.env` sourced with `set -o allexport`** so all vars become environment vars for child processes (`rclone`, `7za`, `curl`).
3. **`BACKUP_PATHS` is the config core.** It is a comma-separated list of entries; each entry is pipe-delimited: `source|destination|BACKUP_TYPE|COMPRESSION_LEVEL`. The script iterates this list with `IFS=','` then splits each entry with `IFS='|'`.
4. **`BACKUP_TYPE` dispatch** (0–4) selects the rclone/7za strategy per entry — see README "Backup Types" for the intent of each. Type 3 iterates subfolders and skips any whose `.7z` already exists on the remote (incremental-by-subfolder). Types 3/4 use `TMP_PATH` as a staging area and encrypt with `ENCRYPTION_PASSWORD`.
5. **Per-entry stdout is captured** via `tee /dev/tty` (note: type 3 has a known typo — `tee /dev/` instead of `tee /dev/tty` — when editing that branch, preserve or fix deliberately).
6. **Email report**: outputs from all entries are concatenated as HTML (`<br>`-joined via `sed`), wrapped in a Brevo API JSON payload built with `jq`, and POSTed to `api.brevo.com/v3/smtp/email`. `ADMIN_EMAIL` may be comma-separated and is split into the `to` array.

## Config reference (`.env`)

- `BACKUP_PATHS` — comma list of `source|destination|BACKUP_TYPE|COMPRESSION_LEVEL`. Pipe is the inner delimiter; do not use pipes in paths.
- `BACKUP_TYPE` — 0 copy, 1 sync, 2 move (with optional `MOVE_DELETE_FILES_THRESHOLD_DAYS` cleanup of old files on the remote), 3 encrypt+compress per subfolder, 4 encrypt+compress whole folder with date-stamped filename.
- `COMPRESSION_LEVEL` — 7-Zip level (0/1/3/5/7/9); ignored for types 0/1/2. `0` means encrypt-only.
- `ENCRYPTION_PASSWORD` — used only by types 3/4.
- `UPLOAD_THREADS` — passed to `rclone --transfers`.
- `ADMIN_EMAIL` — comma-separated recipients.
- `BREVO_API_KEY`, `FROM_EMAIL`, `TMP_PATH`, `HOSTNAME` (latter is a shell builtin, not in `.env`).

## Conventions worth preserving

- rclone is always invoked with `--size-only --ignore-checksum --no-check-certificate`. This is deliberate (size-only comparison, skip checksum, allow self-signed certs) — keep these flags when adding new rclone calls unless explicitly changing the behavior.
- All rclone calls use `--transfers $UPLOAD_THREADS`.
- Type 3's "skip if `.7z` already exists on remote" check is the only incremental-skip mechanism; other types re-upload unconditionally.
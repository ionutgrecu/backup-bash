# Repository Agent Guide

This file provides implementation guidance for coding agents working in this repository. `AGENTS.md` is a symlink to this file, so edits apply to both entry points.

## Overview

This repository contains a single Bash backup runner, `backup.sh`. It executes independently configured backup jobs with `rclone` and `7za`, aggregates their results into an HTML report, and sends that report through SMTP with `curl`. The script is intended to run manually or from cron.

Global settings live in `.env`. Backup-specific settings live in trusted Bash-style files under `jobs-available`; a job runs only when `jobs-enabled` contains a symlink to it.

## Running

```sh
cp .env.sample .env
cp jobs-available/sample.conf jobs-available/my-job.conf
ln -s ../jobs-available/my-job.conf jobs-enabled/my-job.conf
./backup.sh
```

Fill in the SMTP settings in `.env` and configure the job before enabling it.

There is no build, lint, or committed test suite. At minimum, run:

```sh
bash -n backup.sh
git diff --check
```

For behavioral changes, test a copied script in a temporary directory with stubbed `rclone`, `7za`, and `curl`. Never validate against the user's production `.env`, backup sources, or remotes.

## Architecture

The main flow in `backup.sh` is:

1. Change to the repository directory and acquire `/tmp/backup-bash.lock`; the EXIT trap removes the lock and any active staging directory.
2. Source global `.env` settings with `set -o allexport`.
3. Discover non-hidden entries in `jobs-enabled` in filename order.
4. Require each enabled entry to be a symlink resolving to a regular file inside `jobs-available`.
5. Source each job in function-local variables, validate it, and dispatch backup type 0–4.
6. Continue after invalid jobs, failed commands, or failed type-3 subfolders while recording failures and preserving a nonzero final status.
7. Build an escaped HTML report and attempt SMTP delivery even when discovery or backup operations failed.

Transfer output is captured through temporary files and `tee`, so it remains visible without depending on `/dev/tty`. Quiet rclone listings capture stdout separately from stderr so warnings cannot be interpreted as filenames.

Types 3 and 4 create isolated `backup-bash.XXXXXX` staging directories beneath `TMP_PATH`. Type 3 lists immediate subfolders, creates one encrypted `.7z` per subfolder, and can skip exact archive names already present at the destination. Type 4 creates one date-stamped archive for the whole source.

## Global configuration (`.env`)

- `ADMIN_EMAIL` — comma-separated SMTP recipients.
- `FROM_EMAIL` — SMTP envelope sender and message `From` address.
- `SMTP_URL` — `smtp://host:port` for SMTP/STARTTLS or `smtps://host:port` for implicit TLS.
- `SMTP_USERNAME`, `SMTP_PASSWORD` — optional authentication; both must be set or both empty.
- `SMTP_REQUIRE_TLS` — `true` adds curl's `--ssl-reqd`; empty defaults to `true`.
- `TMP_PATH` — existing writable staging location required by types 3 and 4.
- `MOVE_DELETE_FILES_THRESHOLD_DAYS` — global type-2 remote retention threshold; empty or `0` disables deletion.
- `HOSTNAME` — provided by the shell/environment and used in the report subject; it is not in `.env.sample`.

`BACKUP_PATHS`, global `ENCRYPTION_PASSWORD`, global `UPLOAD_THREADS`, `BREVO_API_KEY`, and jq are obsolete and must not be reintroduced without an explicit compatibility requirement.

The real `.env` is ignored and may contain user secrets or legacy values. Do not rewrite, print, or commit it unless the user explicitly requests that exact action.

## Job configuration

Every job file defines all seven keys:

- `SOURCE`
- `DESTINATION`
- `BACKUP_TYPE` — `0`, `1`, `2`, `3`, or `4`.
- `IGNORE_EXISTING` — literal `true` or `false`.
- `COMPRESSION_LEVEL` — `0`, `1`, `3`, `5`, `7`, or `9`; ignored by types 0–2.
- `ENCRYPTION_PASSWORD` — required for types 3 and 4, and may be empty for types 0–2.
- `UPLOAD_THREADS` — positive integer passed to `rclone --transfers`.

Real job files and enabled symlinks are ignored by Git because job files can contain encryption passwords. Keep `jobs-available/sample.conf` free of secrets and do not enable it automatically.

## Backup modes and existing-file behavior

- Type 0 uses `rclone copy`; extra destination files remain.
- Type 1 uses `rclone sync`; extra destination files are deleted.
- Type 2 uses `rclone move`, followed by optional `rclone delete --min-age`.
- Type 3 archives each immediate subfolder separately.
- Type 4 archives the complete source with a minute-resolution date suffix.

When `IGNORE_EXISTING=true`, destination transfers for types 0, 1, 2, and 4 receive `--ignore-existing`. Type 3 skips an exact existing `folder.7z` and protects its final move with the same flag. Its source-to-staging copy never receives `--ignore-existing`.

When `IGNORE_EXISTING=false`, omit the flag and let normal rclone `--size-only` behavior apply. Type 1 remains destructive with respect to extra destination files.

## Conventions worth preserving

- Every rclone transfer uses `--transfers "$UPLOAD_THREADS" --size-only --ignore-checksum --no-check-certificate --progress --stats-unit bytes`.
- Build command arguments with Bash arrays and quote paths, passwords, recipient addresses, and thread counts.
- Keep job variables isolated so missing keys cannot inherit obsolete values from `.env` or a preceding job.
- Validate configuration before invoking backup commands.
- Preserve exact-match type-3 archive checks; do not use substring matching for destination filenames.
- Continue independent jobs after failure, attempt the email report last, and exit nonzero if any job or SMTP delivery failed.
- Keep SMTP certificate verification enabled; do not add curl `--insecure`.
- Treat `jobs-available` files as executable trusted configuration, not as untrusted data.

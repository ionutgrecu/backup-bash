# Backup Script

A Bash backup runner that uses [rclone](https://rclone.org/) and 7-Zip to execute independently configured jobs, then sends one HTML report through SMTP. It is designed to run manually or from cron.

## Prerequisites

- Bash
- `rclone`, installed and configured with the required remotes
- `7za` for backup types 3 and 4
- `curl` with SMTP/SMTPS support
- A configured `.env` file
- One or more enabled job files

## Global configuration

Copy the sample and edit it:

```sh
cp .env.sample .env
```

The global settings remain in `.env`:

| Variable | Description |
| --- | --- |
| `ADMIN_EMAIL` | Report recipients, separated by commas |
| `FROM_EMAIL` | Envelope sender and `From` address |
| `SMTP_URL` | SMTP endpoint, such as `smtp://smtp.example.com:587` or `smtps://smtp.example.com:465` |
| `SMTP_USERNAME` | SMTP login; leave both username and password empty for an unauthenticated server |
| `SMTP_PASSWORD` | SMTP password |
| `SMTP_REQUIRE_TLS` | `true` to require TLS, or `false` to permit an unencrypted SMTP connection |
| `TMP_PATH` | Existing writable staging directory used by backup types 3 and 4 |
| `MOVE_DELETE_FILES_THRESHOLD_DAYS` | For type 2, delete remote files older than this many days; empty or `0` disables deletion |

For STARTTLS on port 587:

```sh
SMTP_URL=smtp://smtp.example.com:587
SMTP_REQUIRE_TLS=true
```

For implicit TLS on port 465:

```sh
SMTP_URL=smtps://smtp.example.com:465
SMTP_REQUIRE_TLS=true
```

When authentication is used, both `SMTP_USERNAME` and `SMTP_PASSWORD` must be set. TLS certificates are verified by curl.

## Job configuration

Available jobs live in `jobs-available`. Start with the tracked sample:

```sh
cp jobs-available/sample.conf jobs-available/photos.conf
```

Each job is a trusted Bash-style configuration file with these fields:

```sh
SOURCE="/srv/photos"
DESTINATION="s3:/backups/photos"
BACKUP_TYPE=0
IGNORE_EXISTING=true
COMPRESSION_LEVEL=0
ENCRYPTION_PASSWORD=""
UPLOAD_THREADS=3
```

| Variable | Description |
| --- | --- |
| `SOURCE` | Local path or rclone source |
| `DESTINATION` | Local path or configured rclone destination |
| `BACKUP_TYPE` | Backup mode `0` through `4` |
| `IGNORE_EXISTING` | `true` to skip existing destination files/archives, otherwise `false` |
| `COMPRESSION_LEVEL` | 7-Zip level: `0`, `1`, `3`, `5`, `7`, or `9` |
| `ENCRYPTION_PASSWORD` | Required for types 3 and 4; may be empty for types 0–2 |
| `UPLOAD_THREADS` | Positive number passed to `rclone --transfers` |

Quote values containing spaces or shell-significant characters. Real job files are ignored by Git because they may contain encryption passwords.

### Enabling and disabling jobs

Enable a job with a symlink:

```sh
ln -s ../jobs-available/photos.conf jobs-enabled/photos.conf
```

Disable it by removing only the symlink:

```sh
rm jobs-enabled/photos.conf
```

The runner accepts only symlinks that resolve to regular files inside `jobs-available`. Enabled jobs run in filename order. The tracked sample is not enabled automatically.

## Backup types

- `0` — Copy source files to the destination. Extra destination files remain.
- `1` — Sync the source to the destination. Extra destination files are deleted.
- `2` — Move source files to the destination, optionally followed by age-based remote cleanup.
- `3` — Copy, encrypt, and compress each immediate source subfolder into its own `.7z` archive, then upload it.
- `4` — Encrypt and compress the entire source into a date-stamped `.7z` archive, then upload it.

Types 0–2 are intended for content that does not need compression or is already encrypted. Types 3 and 4 use `TMP_PATH` for isolated staging and encrypt archive headers and content with `ENCRYPTION_PASSWORD`.

For types 3 and 4, compression level `0` performs encryption with no compression.

### Existing destination behavior

When `IGNORE_EXISTING=true`:

- Types 0, 1, 2, and 4 pass `--ignore-existing` to their destination transfer.
- Type 3 lists destination archives once, skips an exact existing `folder-name.7z`, and also protects the final upload with `--ignore-existing`.

When it is `false`, the flag and type-3 archive skip are omitted; normal rclone `--size-only` behavior applies. Type 1 remains a sync operation and can still delete destination files that are absent from the source.

All transfer operations preserve `--size-only --ignore-checksum --no-check-certificate` and use the job's `UPLOAD_THREADS`.

## Running

```sh
./backup.sh
```

The lock file `/tmp/backup-bash.lock` prevents concurrent runs. Invalid jobs and failed commands are recorded in the report while later jobs continue. The script attempts to send the report after all jobs and exits nonzero if job discovery, validation, a backup command, cleanup, or SMTP delivery fails.

For cron, use an absolute path:

```cron
0 2 * * * /path/to/backup-bash.git/backup.sh
```

## Migrating from `BACKUP_PATHS`

Create one job file for each old pipe-delimited `BACKUP_PATHS` entry, moving its source, destination, backup type, and compression level into that file. Add `IGNORE_EXISTING`, `ENCRYPTION_PASSWORD`, and `UPLOAD_THREADS` to every job, then enable it with a symlink.

The script no longer reads `BACKUP_PATHS`, the global `ENCRYPTION_PASSWORD`, the global `UPLOAD_THREADS`, `BREVO_API_KEY`, or jq. Replace the Brevo API settings with the SMTP variables shown above.

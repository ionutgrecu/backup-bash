# Backup Script 

This script performs backups of specified directories using `rclone` and `7za` for compression and encryption. The backup details are sent via email using the [Brevo Api](https://app.brevo.com/).

## Prerequisites

- `rclone` installed and configured
- `7za` (7-Zip) installed
- `jq` installed
- `curl` installed
- `.env` file with the following variables:
    - `BACKUP_PATHS`: Comma-separated list of paths and destinations with backup type and compression level (e.g., `/path/to/source|/path/to/dest|[BACKUP_TYPE]|[COMPRESSION_LEVEL],/another/path|/another/dest|1|3`)
    - `ENCRYPTION_PASSWORD`: Password for 7-Zip encryption
    - `ADMIN_EMAIL`: Email address to send the backup report
    - `BREVO_API_KEY`: API key for Brevo

Config an `rclone` drive with the provider you want.

## Backup Types

- `0`: Copy files to the remote destination. Extra files from remote destionation won't get deleted. It's useful to protect against accidental deletion of files.
- `1`: Sync files to the remote destination. Extra files from remote destination will get deleted.
- `2`: Encrypt and compress each subfolder to the remote destination
- `3`: Encrypt and compress the entire folder to the remote destination and append the current date to the backup filename

Backup types `0` and `1` are intended for very large folders (over 50Gb) with nonconfidential/public content which doesn't deserve to be compressed (images, videos, etc), for which encryption is not necessary.

Backup types `2` and `3` are intended for confidential/private content which should be encrypted and/or compressed before being uploaded to the remote destination.

If you have a local backup files already archived which is not encrypted, you can use the `BACKUP_TYPE = 2` with `COMPRESSION_LEVEL = 0` to keep an encrypted copy to a remote location.

To protect against ransomware arrack, which can destroy content to an external drive through rclone, you can setup an s3 bucket with versioning/snapshot enabled or an s3 user limited only to upload and read.

## Compression Levels

This value is ignored if the backup type is `0` or `1` (copy or sync).
This is the compression level `[0 | 1 | 3 | 5 | 7 | 9 ]` for 7-Zip. The higher the number, the better the compression, but it will take longer to compress the files and require more resources.
The `COMPRESSION_LEVEL = 0` is equivalent to just encrypt the destionation files.

## Usage

1. Clone the repository:
     ```sh
     git clone https://github.com/ionutgrecu/backup-bash.git
     cd backup-bash.git
     ```

2. Create and configure the `.env` file:
     ```sh
     cp .env.example .env
     # Edit .env with your preferred editor
     ```

3. Run the backup script:
     ```sh
     ./backup.sh
     ```

## Example .env File

```sh
ADMIN_EMAIL=admin@domain.ltd
ENCRYPTION_PASSWORD=Yah3achee1ohthae7uiGei5yai1eip8O....
BACKUP_PATHS="/root/backup|s3:/backup|1|0,/var/www/html/storage/app|s3:/app|0|0,/var/www/html/config|s3:/config|3|7"
BREVO_API_KEY= ...
```

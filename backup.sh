#!/bin/bash

cd "$(dirname "$0")" || exit 1

LOCKFILE="/tmp/backup-bash.lock"
CURRENT_STAGING_DIR=""

cleanup_staging() {
    if [[ -n "$CURRENT_STAGING_DIR" && -d "$CURRENT_STAGING_DIR" ]]; then
        rm -rf -- "$CURRENT_STAGING_DIR"
        local cleanup_status=$?
        if [[ $cleanup_status -eq 0 ]]; then
            CURRENT_STAGING_DIR=""
        fi
        return "$cleanup_status"
    fi

    CURRENT_STAGING_DIR=""
    return 0
}

acquire_lock() {
    if [[ -e "$LOCKFILE" ]]; then
        echo "Script is already running. Exiting."
        exit 1
    fi
    touch "$LOCKFILE"
}

release_lock() {
    cleanup_staging >/dev/null 2>&1 || true
    rm -f -- "$LOCKFILE"
}

trap release_lock EXIT
acquire_lock

if [[ ! -f .env ]]; then
    echo "Missing .env file. Copy .env.sample to .env and configure it."
    exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source .env
env_status=$?
set +o allexport

if [[ $env_status -ne 0 ]]; then
    echo "Unable to load .env."
    exit 1
fi

DATE=$(date +"%Y%m%d_%H%M")
CURRENT_DATE=$(date +"%Y-%m-%d")
OVERALL_STATUS=0
JOB_OUTPUT=""
LAST_COMMAND_OUTPUT=""
REPORT_SECTIONS=()

job_log() {
    local message="$1"
    printf '%s\n' "$message"
    JOB_OUTPUT+="$message"$'\n'
}

run_logged() {
    local log_file
    local command_status
    local tee_status
    local -a pipeline_statuses

    log_file=$(mktemp /tmp/backup-bash-output.XXXXXX)
    if [[ -z "$log_file" ]]; then
        job_log "Unable to create a temporary command log."
        return 1
    fi

    "$@" 2>&1 | tee "$log_file"
    pipeline_statuses=("${PIPESTATUS[@]}")
    command_status=${pipeline_statuses[0]}
    tee_status=${pipeline_statuses[1]}
    LAST_COMMAND_OUTPUT=$(<"$log_file")

    if [[ -n "$LAST_COMMAND_OUTPUT" ]]; then
        JOB_OUTPUT+="$LAST_COMMAND_OUTPUT"$'\n'
    fi

    if ! rm -f -- "$log_file"; then
        job_log "Unable to remove temporary command log: $log_file"
        return 1
    fi

    if [[ $command_status -ne 0 ]]; then
        return "$command_status"
    fi

    return "$tee_status"
}

run_quiet_capture() {
    local command_status
    local error_file
    local command_errors

    error_file=$(mktemp /tmp/backup-bash-error.XXXXXX)
    if [[ -z "$error_file" ]]; then
        job_log "Unable to create a temporary error log."
        return 1
    fi

    LAST_COMMAND_OUTPUT=$("$@" 2>"$error_file")
    command_status=$?
    command_errors=$(<"$error_file")

    if [[ -n "$command_errors" ]]; then
        printf '%s\n' "$command_errors"
        JOB_OUTPUT+="$command_errors"$'\n'
    fi

    if ! rm -f -- "$error_file"; then
        job_log "Unable to remove temporary error log: $error_file"
        return 1
    fi

    return "$command_status"
}

run_rclone_transfer() {
    local operation="$1"
    local apply_ignore_existing="$2"
    local source_path="$3"
    local destination_path="$4"
    local args=(
        rclone "$operation"
        --transfers "$UPLOAD_THREADS"
        --size-only
        --ignore-checksum
        --no-check-certificate
        --progress
        --stats-unit bytes
    )

    if [[ "$apply_ignore_existing" == "true" && "$IGNORE_EXISTING" == "true" ]]; then
        args+=(--ignore-existing)
    fi

    args+=("$source_path" "$destination_path")
    run_logged "${args[@]}"
}

html_escape() {
    local value="$1"
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//$'\n'/<br>}
    printf '%s' "$value"
}

add_report_section() {
    local job_name="$1"
    local status="$2"
    local output="$3"
    local escaped_name
    local escaped_status
    local escaped_output

    escaped_name=$(html_escape "$job_name")
    escaped_status=$(html_escape "$status")
    escaped_output=$(html_escape "$output")
    REPORT_SECTIONS+=("<h2>${escaped_name}: ${escaped_status}</h2><p>${escaped_output}</p>")
}

validate_job() {
    local errors=()

    [[ -n "$SOURCE" ]] || errors+=("SOURCE is required")
    [[ -n "$DESTINATION" ]] || errors+=("DESTINATION is required")

    case "$BACKUP_TYPE" in
        0|1|2|3|4) ;;
        *) errors+=("BACKUP_TYPE must be one of: 0, 1, 2, 3, 4") ;;
    esac

    case "$IGNORE_EXISTING" in
        true|false) ;;
        *) errors+=("IGNORE_EXISTING must be true or false") ;;
    esac

    case "$COMPRESSION_LEVEL" in
        0|1|3|5|7|9) ;;
        *) errors+=("COMPRESSION_LEVEL must be one of: 0, 1, 3, 5, 7, 9") ;;
    esac

    if [[ ! "$UPLOAD_THREADS" =~ ^[1-9][0-9]*$ ]]; then
        errors+=("UPLOAD_THREADS must be a positive integer")
    fi

    if [[ ( "$BACKUP_TYPE" == "3" || "$BACKUP_TYPE" == "4" ) && -z "$ENCRYPTION_PASSWORD" ]]; then
        errors+=("ENCRYPTION_PASSWORD is required for backup types 3 and 4")
    fi

    if [[ "$BACKUP_TYPE" == "3" || "$BACKUP_TYPE" == "4" ]]; then
        if [[ -z "$TMP_PATH" || ! -d "$TMP_PATH" || ! -w "$TMP_PATH" ]]; then
            errors+=("TMP_PATH must be an existing writable directory for backup types 3 and 4")
        fi
    fi

    if [[ "$BACKUP_TYPE" == "2" && -n "$MOVE_DELETE_FILES_THRESHOLD_DAYS" && ! "$MOVE_DELETE_FILES_THRESHOLD_DAYS" =~ ^[0-9]+$ ]]; then
        errors+=("MOVE_DELETE_FILES_THRESHOLD_DAYS must be empty or a non-negative integer")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        local error
        for error in "${errors[@]}"; do
            job_log "Configuration error: $error"
        done
        return 1
    fi

    return 0
}

prepare_staging() {
    CURRENT_STAGING_DIR=$(mktemp -d -- "${TMP_PATH%/}/backup-bash.XXXXXX")
    if [[ -z "$CURRENT_STAGING_DIR" || ! -d "$CURRENT_STAGING_DIR" ]]; then
        CURRENT_STAGING_DIR=""
        job_log "Unable to create a staging directory in $TMP_PATH."
        return 1
    fi

    return 0
}

run_type_0() {
    job_log "Backup type: 0 - Copy files to the remote destination"
    run_rclone_transfer copy true "$SOURCE" "${DESTINATION%/}/"
}

run_type_1() {
    job_log "Backup type: 1 - Sync files to the remote destination"
    run_rclone_transfer sync true "$SOURCE" "${DESTINATION%/}/"
}

run_type_2() {
    local failed=0

    job_log "Backup type: 2 - Move files to the remote destination"
    if ! run_rclone_transfer move true "$SOURCE" "${DESTINATION%/}/"; then
        failed=1
    fi

    if [[ -n "$MOVE_DELETE_FILES_THRESHOLD_DAYS" && "$MOVE_DELETE_FILES_THRESHOLD_DAYS" -gt 0 ]]; then
        job_log "Deleting files older than $MOVE_DELETE_FILES_THRESHOLD_DAYS days from $DESTINATION"
        if ! run_logged rclone delete --min-age "${MOVE_DELETE_FILES_THRESHOLD_DAYS}d" "${DESTINATION%/}/"; then
            failed=1
        fi
    fi

    return "$failed"
}

run_type_3() {
    local failed=0
    local folder
    local folder_name
    local folder_source
    local folder_staging
    local archive_name
    local archive_path
    local remote_files=""
    local folders=()

    job_log "Backup type: 3 - Encrypt and compress each subfolder to the remote destination"

    if ! prepare_staging; then
        return 1
    fi

    if ! run_quiet_capture rclone lsf "$SOURCE" --dirs-only; then
        cleanup_staging || job_log "Unable to remove staging directory: $CURRENT_STAGING_DIR"
        return 1
    fi

    if [[ -n "$LAST_COMMAND_OUTPUT" ]]; then
        mapfile -t folders <<< "$LAST_COMMAND_OUTPUT"
    fi

    if [[ "$IGNORE_EXISTING" == "true" ]]; then
        if ! run_quiet_capture rclone lsf "$DESTINATION" --files-only; then
            cleanup_staging || job_log "Unable to remove staging directory: $CURRENT_STAGING_DIR"
            return 1
        fi
        remote_files="$LAST_COMMAND_OUTPUT"
    fi

    if [[ ${#folders[@]} -eq 0 ]]; then
        job_log "No subfolders found in $SOURCE."
    fi

    for folder in "${folders[@]}"; do
        folder=${folder%/}
        folder_name=$(basename "$folder")
        archive_name="${folder_name}.7z"

        if [[ "$IGNORE_EXISTING" == "true" ]] && grep -Fqx -- "$archive_name" <<< "$remote_files"; then
            job_log "File already exists in remote: $archive_name"
            continue
        fi

        folder_source="${SOURCE%/}/${folder}"
        folder_staging="${CURRENT_STAGING_DIR}/${folder_name}"
        archive_path="${CURRENT_STAGING_DIR}/${archive_name}"

        if ! run_rclone_transfer copy false "$folder_source" "$folder_staging"; then
            failed=1
            continue
        fi

        if ! run_logged 7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "$archive_path" "$folder_staging"; then
            failed=1
            continue
        fi

        if ! rm -rf -- "$folder_staging"; then
            job_log "Unable to remove staged folder: $folder_staging"
            failed=1
        fi

        if ! run_rclone_transfer move true "$archive_path" "${DESTINATION%/}/"; then
            failed=1
        fi
    done

    if ! cleanup_staging; then
        job_log "Unable to remove staging directory: $CURRENT_STAGING_DIR"
        failed=1
    fi

    return "$failed"
}

run_type_4() {
    local failed=0
    local folder_name
    local archive_path

    job_log "Backup type: 4 - Encrypt and compress the entire folder to the remote destination"

    if ! prepare_staging; then
        return 1
    fi

    folder_name="$(basename "$SOURCE")_$DATE"
    archive_path="${CURRENT_STAGING_DIR}/${folder_name}.7z"

    if ! run_logged 7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "$archive_path" "$SOURCE"; then
        failed=1
    elif ! run_rclone_transfer move true "$archive_path" "${DESTINATION%/}/"; then
        failed=1
    fi

    if ! cleanup_staging; then
        job_log "Unable to remove staging directory: $CURRENT_STAGING_DIR"
        failed=1
    fi

    return "$failed"
}

run_job() {
    local job_file="$1"
    local SOURCE=""
    local DESTINATION=""
    local BACKUP_TYPE=""
    local IGNORE_EXISTING=""
    local COMPRESSION_LEVEL=""
    local ENCRYPTION_PASSWORD=""
    local UPLOAD_THREADS=""
    local source_status

    JOB_OUTPUT=""

    # Job files are trusted Bash-style configuration files.
    # shellcheck disable=SC1090
    source "$job_file"
    source_status=$?
    if [[ $source_status -ne 0 ]]; then
        job_log "Unable to load job configuration: $job_file"
        return 1
    fi

    job_log "Backup source: $SOURCE"
    job_log "Backup destination: $DESTINATION"

    if ! validate_job; then
        return 1
    fi

    case "$BACKUP_TYPE" in
        0) run_type_0 ;;
        1) run_type_1 ;;
        2) run_type_2 ;;
        3) run_type_3 ;;
        4) run_type_4 ;;
    esac
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

build_html_report() {
    local html
    local section

    html="<p>Backup Report for $(html_escape "${HOSTNAME:-unknown}") on $(html_escape "$CURRENT_DATE")</p>"
    html+="<p>Script generator: backup-bash</p>"

    for section in "${REPORT_SECTIONS[@]}"; do
        html+="$section"
    done

    printf '%s' "$html"
}

send_email_report() {
    local smtp_require_tls="${SMTP_REQUIRE_TLS:-true}"
    local recipients=()
    local recipient_args=()
    local raw_recipient
    local recipient
    local recipients_header=""
    local smtp_args
    local subject
    local html_report
    local -a pipeline_statuses
    local curl_status

    if [[ -z "$SMTP_URL" || -z "$FROM_EMAIL" || -z "$ADMIN_EMAIL" ]]; then
        echo "SMTP_URL, FROM_EMAIL, and ADMIN_EMAIL are required to send the report."
        return 1
    fi

    if [[ "$SMTP_URL" != smtp://* && "$SMTP_URL" != smtps://* ]]; then
        echo "SMTP_URL must start with smtp:// or smtps://."
        return 1
    fi

    if [[ -n "$SMTP_REQUIRE_TLS" && "$smtp_require_tls" != "true" && "$smtp_require_tls" != "false" ]]; then
        echo "SMTP_REQUIRE_TLS must be true or false."
        return 1
    fi

    if [[ -n "$SMTP_USERNAME" || -n "$SMTP_PASSWORD" ]]; then
        if [[ -z "$SMTP_USERNAME" || -z "$SMTP_PASSWORD" ]]; then
            echo "SMTP_USERNAME and SMTP_PASSWORD must either both be set or both be empty."
            return 1
        fi
    fi

    IFS=',' read -ra recipients <<< "$ADMIN_EMAIL"
    for raw_recipient in "${recipients[@]}"; do
        recipient=$(trim_whitespace "$raw_recipient")
        if [[ -z "$recipient" || "$recipient" == *$'\r'* || "$recipient" == *$'\n'* ]]; then
            echo "ADMIN_EMAIL contains an invalid recipient."
            return 1
        fi
        recipient_args+=(--mail-rcpt "$recipient")
        if [[ -n "$recipients_header" ]]; then
            recipients_header+=", "
        fi
        recipients_header+="$recipient"
    done

    if [[ "$FROM_EMAIL" == *$'\r'* || "$FROM_EMAIL" == *$'\n'* ]]; then
        echo "FROM_EMAIL contains invalid newline characters."
        return 1
    fi

    smtp_args=(
        curl
        --silent
        --show-error
        --url "$SMTP_URL"
        --mail-from "$FROM_EMAIL"
        "${recipient_args[@]}"
        --upload-file -
    )

    if [[ "$smtp_require_tls" == "true" ]]; then
        smtp_args+=(--ssl-reqd)
    fi

    if [[ -n "$SMTP_USERNAME" ]]; then
        smtp_args+=(--user "$SMTP_USERNAME:$SMTP_PASSWORD")
    fi

    subject="Backup ${HOSTNAME:-unknown} - $CURRENT_DATE"
    html_report=$(build_html_report)

    {
        printf 'From: %s\r\n' "$FROM_EMAIL"
        printf 'To: %s\r\n' "$recipients_header"
        printf 'Subject: %s\r\n' "$subject"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/html; charset=UTF-8\r\n'
        printf '\r\n'
        printf '%s\r\n' "$html_report"
    } | "${smtp_args[@]}"
    pipeline_statuses=("${PIPESTATUS[@]}")
    curl_status=${pipeline_statuses[1]}

    if [[ $curl_status -ne 0 ]]; then
        echo "Unable to send the backup report through SMTP."
        return "$curl_status"
    fi

    echo "Backup report sent through SMTP."
    return 0
}

process_enabled_jobs() {
    local enabled_entries=()
    local available_dir
    local job_link
    local job_file
    local job_name
    local found_job=0

    available_dir=$(readlink -f jobs-available)
    if [[ -z "$available_dir" ]]; then
        JOB_OUTPUT="The jobs-available directory does not exist."
        printf '%s\n' "$JOB_OUTPUT"
        add_report_section "Job discovery" "FAILED" "$JOB_OUTPUT"
        OVERALL_STATUS=1
        return 1
    fi

    if [[ ! -d jobs-enabled ]]; then
        JOB_OUTPUT="The jobs-enabled directory does not exist."
        printf '%s\n' "$JOB_OUTPUT"
        add_report_section "Job discovery" "FAILED" "$JOB_OUTPUT"
        OVERALL_STATUS=1
        return 1
    fi

    shopt -s nullglob
    enabled_entries=(jobs-enabled/*)
    shopt -u nullglob

    for job_link in "${enabled_entries[@]}"; do
        found_job=1
        job_name=$(basename "$job_link")
        JOB_OUTPUT=""

        if [[ ! -L "$job_link" ]]; then
            JOB_OUTPUT="Enabled job must be a symlink: $job_link"
            printf '%s\n' "$JOB_OUTPUT"
            add_report_section "$job_name" "FAILED" "$JOB_OUTPUT"
            OVERALL_STATUS=1
            continue
        fi

        job_file=$(readlink -f "$job_link")
        if [[ -z "$job_file" || ! -f "$job_file" ]]; then
            JOB_OUTPUT="Enabled job is a dangling or invalid symlink: $job_link"
            printf '%s\n' "$JOB_OUTPUT"
            add_report_section "$job_name" "FAILED" "$JOB_OUTPUT"
            OVERALL_STATUS=1
            continue
        fi

        case "$job_file" in
            "$available_dir"/*) ;;
            *)
                JOB_OUTPUT="Enabled job must point inside jobs-available: $job_link"
                printf '%s\n' "$JOB_OUTPUT"
                add_report_section "$job_name" "FAILED" "$JOB_OUTPUT"
                OVERALL_STATUS=1
                continue
                ;;
        esac

        echo "Running job: $job_name"
        if run_job "$job_file"; then
            add_report_section "$job_name" "SUCCESS" "$JOB_OUTPUT"
        else
            add_report_section "$job_name" "FAILED" "$JOB_OUTPUT"
            OVERALL_STATUS=1
        fi
    done

    if [[ $found_job -eq 0 ]]; then
        JOB_OUTPUT="No jobs are enabled."
        printf '%s\n' "$JOB_OUTPUT"
        add_report_section "Job discovery" "FAILED" "$JOB_OUTPUT"
        OVERALL_STATUS=1
    fi
}

process_enabled_jobs

if ! send_email_report; then
    OVERALL_STATUS=1
fi

exit "$OVERALL_STATUS"

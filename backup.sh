#!/bin/bash

cd "$(dirname "$0")"

set -o allexport
source .env
set +o allexport

DATE=$(date +"%Y%m%d_%H%M")
IFS=',' read -ra paths <<< "$BACKUP_PATHS"
all_outputs=""

for path_info in "${paths[@]}"; do
    IFS='|' read -r path DESTINATION BACKUP_TYPE COMPRESSION_LEVEL <<< "$path_info"

    echo "Backup path: $path to $DESTINATION"

    if [[ "$BACKUP_TYPE" == "0" ]]; then
        echo "Backup type: 0 - Copy files to the remote destination"
        output=$(rclone copy --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress "$path" "$DESTINATION/" 2>&1 | tee /dev/tty)
    elif [[ "$BACKUP_TYPE" == "1" ]]; then
        echo "Backup type: 1 - Sync files to the remote destination"
        output=$(rclone sync --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress "$path" "$DESTINATION/" 2>&1 | tee /dev/tty)
    elif [[ "$BACKUP_TYPE" == "2" ]]; then
        echo "Backup type: 2 - Encrypt and compress each subfolder to the remote destination"
        output=""

        for folder in $(rclone lsf "$path" --dirs-only); do
            folder_name=$(basename "$folder")

            if rclone ls "$DESTINATION" | grep -q "$folder_name.7z"; then
                output+="File already exists in remote: $folder_name.7z"
                output+="<br>"
                continue
            fi

            folder=$(echo "$folder" | sed 's:/*$::')

            rclone copy --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress "$path/$folder" "$TMP_PATH/$folder"
            7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "$TMP_PATH/${folder_name}.7z" "$TMP_PATH/$folder"
            rm -rf "$TMP_PATH/$folder"
            output+=$(rclone move --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress "$TMP_PATH/${folder_name}.7z" "$DESTINATION/" 2>&1 | tee /dev/tty)
            output+="<br>"
        done
    elif [[ "$BACKUP_TYPE" == "3" ]]; then
        echo "Backup type: 3 - Encrypt and compress the entire folder to the remote destination"
        folder_name="$(basename "$path")_$DATE"
        7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "$TMP_PATH/$folder_name.7z" "$path"
        output=$(rclone move --transfers $UPLOAD_THREADS --size-only --ignore-checksum --no-check-certificate --progress "$TMP_PATH/$folder_name.7z" "$DESTINATION/" 2>&1 | tee /dev/tty)
    else
        output="Invalid backup type: $BACKUP_TYPE for path: $path"
        continue
    fi

    echo $output
    formatted_output=$(echo "$output" | sed ':a;N;$!ba;s/\n/<br>/g')
    all_outputs+="${formatted_output}<br><br>"
done

json_output=$(jq -Rs . <<< "$all_outputs")
current_date=$(date +"%Y-%m-%d")

json_payload=$(jq -n \
    --arg subject "Backup $HOSTNAME - $current_date" \
    --arg email "$FROM_EMAIL" \
    --arg to_email1 "$ADMIN_EMAIL" \
    --arg htmlContent "<p>Backup Report for $HOSTNAME on $current_date</p><p><strong>Source:</strong> $source_dir</p><p><strong>Destination:</strong> $destination_dir</p><p><strong>Details:</strong><br>$all_outputs" \
    '{
        subject: $subject,
        sender: { email: $email },
        to: [{ email: $to_email1 }],
        htmlContent: $htmlContent
    }'
)

echo $(curl -H "api-key:$BREVO_API_KEY" \
    -X POST \
    -d "$json_payload" \
    https://api.brevo.com/v3/smtp/email \
)

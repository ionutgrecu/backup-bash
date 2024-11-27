#!/bin/bash

cd "$(dirname "$0")"

set -o allexport
source .env
set +o allexport

DATE=$(date +"%Y%m%d_%H%M")
IFS=',' read -ra paths <<< "$BACKUP_PATHS"
all_outputs=""

for path_info in "${paths[@]}"; do
    IFS=':' read -r path BACKUP_TYPE COMPRESSION_LEVEL <<< "$path_info"

    if [ ! -d "$path" ]; then
        echo "Path does not exist: $path"
        continue
    fi

    echo "Backup path: $path"

    if [[ "$BACKUP_TYPE" == "0" ]]; then
        output=$(rclone copy --size-only --ignore-checksum --no-check-certificate -v "$path" "$RCLONE_REMOTE/" 2>&1)
    elif [[ "$BACKUP_TYPE" == "1" ]]; then
        output=$(rclone sync --size-only --ignore-checksum --no-check-certificate -v "$path" "$RCLONE_REMOTE/" 2>&1)
    elif [[ "$BACKUP_TYPE" == "2" ]]; then
        output=""
        
        for folder in "$path"/*; do
            folder_name=$(basename "$folder")

            if rclone ls "$RCLONE_REMOTE" | grep -q "$folder_name.7z"; then
                output+="File already exists in remote: $folder_name.7z"
                output+="<br>"
                continue
            fi

            7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "/tmp/${folder_name}.7z" "$folder"
            output+=$(rclone move --size-only --ignore-checksum --no-check-certificate -v "/tmp/${folder_name}.7z" "$RCLONE_REMOTE/" 2>&1)
            output+="<br>"
        done
    elif [[ "$BACKUP_TYPE" == "3" ]]; then
        folder_name="$(basename "$path")_$DATE"
        7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "/tmp/$folder_name.7z" "$path"
        output=$(rclone move --size-only --ignore-checksum --no-check-certificate -v "/tmp/$folder_name.7z" "$RCLONE_REMOTE/" 2>&1)
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
    --arg email "server@$HOSTNAME" \
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

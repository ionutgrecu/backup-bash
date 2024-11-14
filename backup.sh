#!/bin/bash 

cd "$(dirname "$0")"

set -o allexport
source .env
set +o allexport

DATE=$(date +"%Y%m%d_%H%M")
IFS=',' read -ra paths <<< "$BACKUP_PATHS"

for path_info in "${paths[@]}"; do
    IFS=':' read -r path BACKUP_TYPE COMPRESSION_LEVEL <<< "$path_info"
    
    if [ ! -d "$path" ]; then
        echo "Path does not exist: $path"
        continue
    fi

    echo "Backup path: $path"

    if [[ "$BACKUP_TYPE" == "0" ]]; then
        rclone copy --ignore-checksum --no-check-certificate -v "$path" "$RCLONE_REMOTE/"
    elif [[ "$BACKUP_TYPE" == "1" ]]; then
        rclone sync --ignore-checksum --no-check-certificate -v "$path" "$RCLONE_REMOTE/"
    elif [[ "$BACKUP_TYPE" == "2" ]]; then
        for folder in "$path"/*; do
            folder_name=$(basename "$folder")
            7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "/tmp/${folder_name}.7z" "$folder"
            rclone move --ignore-checksum --no-check-certificate -v "/tmp/${folder_name}.7z" "$RCLONE_REMOTE/"
        done
    elif [[ "$BACKUP_TYPE" == "3" ]]; then
        folder_name="$(basename "$path")_$DATE"
        7za a -t7z -mhe=on -mx="$COMPRESSION_LEVEL" -p"$ENCRYPTION_PASSWORD" "/tmp/$folder_name.7z" "$path"
        rclone move --ignore-checksum --no-check-certificate -v "/tmp/$folder_name.7z" "$RCLONE_REMOTE/"
    else
        echo "Invalid backup type: $BACKUP_TYPE for path: $path"
        continue
    fi
done

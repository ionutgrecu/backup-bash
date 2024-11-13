#!/bin/bash 

cd "$(dirname "$0")"

set -o allexport
source .env
set +o allexport

IFS=',' read -ra paths <<< "$BACKUP_PATHS"

for path in "${paths[@]}"; do
    if [ ! -d "$path" ]; then
        echo "Path does not exist: $path"
        continue
    fi

    echo "Backup path: $path"
    echo $DESTINATION_PATH
done

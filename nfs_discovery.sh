#!/bin/bash

# Get list of NFS mounts
mounts=$(mount -t nfs,nfs4 | awk '{print $3}' | sort -u)

# Start JSON output
echo "{"
echo "  \"data\": ["

first=1
while IFS= read -r mountpoint; do
  if [ -n "$mountpoint" ]; then
    # Get NFS server for the mountpoint
    server=$(mount -t nfs,nfs4 | grep "[[:space:]]${mountpoint}[[:space:]]" | awk '{print $1}' | cut -d':' -f1)
    if [ $first -eq 1 ]; then
      first=0
    else
      echo ","
    fi
    echo "    {"
    echo "      \"{#MOUNTPOINT}\": \"$mountpoint\","
    echo "      \"{#SERVER}\": \"$server\""
    echo "    }"
  fi
done <<< "$mounts"

# End JSON output
echo "  ]"
echo "}"
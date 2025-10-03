#!/bin/bash

MOUNTPOINT="$1"
METRIC="$2"
#DEBUG_LOG="${ZABBIX_NFS_DEBUG_LOG:-/var/log/zabbix/nfs_mount_stat_debug.log}"

# Ensure the debug log directory exists and is writable
#DEBUG_DIR=$(dirname "$DEBUG_LOG")
#if [ ! -d "$DEBUG_DIR" ]; then
#  mkdir -p "$DEBUG_DIR" 2>/dev/null || {
#    echo "ZBX_NOTSUPPORTED: Cannot create debug log directory $DEBUG_DIR"
#    exit 1
#  }
#fi

# Validate inputs
if [ -z "$MOUNTPOINT" ] || [ -z "$METRIC" ]; then
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): ZBX_NOTSUPPORTED: Missing mountpoint or metric Usage: $0 <mountpoint> <metric>" >> "$DEBUG_LOG"
  echo "ZBX_NOTSUPPORTED: Missing mountpoint or metric"
  exit 1
fi

# Log inputs and environment
#echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Running for mountpoint=$MOUNTPOINT, metric=$METRIC, user=$USER" >> "$DEBUG_LOG" 2>/dev/null || echo "ZBX_NOTSUPPORTED: Cannot write to debug log $DEBUG_LOG"

# Verify mountpoint is NFS
mount_output=$(mount -t nfs,nfs4 | grep -E "[[:space:]]${MOUNTPOINT}([[:space:]]|,|$)")
if [ -z "$mount_output" ]; then
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Mountpoint $MOUNTPOINT not found in 'mount -t nfs,nfs4'" >> "$DEBUG_LOG"
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Mount output: $(mount | grep $MOUNTPOINT)" >> "$DEBUG_LOG"
  echo "ZBX_NOTSUPPORTED: Mountpoint $MOUNTPOINT is not an NFS mount"
  exit 1
fi
#echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Mountpoint $MOUNTPOINT found: $mount_output" >> "$DEBUG_LOG"

# Extract the block for the specific mountpoint
block=$(awk -v mp="$MOUNTPOINT" '
BEGIN { in_block = 0; block = "" }
/^device / && $0 ~ "mounted on " mp " " { in_block = 1 }
in_block { block = block $0 "\n" }
/^device / && in_block && $0 !~ "mounted on " mp " " { in_block = 0 }
END { print block }
' /proc/self/mountstats)

# Log raw mountstats excerpt for debugging
mountstats_excerpt=$(grep -A 20 "[[:space:]]${MOUNTPOINT}[[:space:]]" /proc/self/mountstats)
#echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Raw /proc/self/mountstats excerpt for $MOUNTPOINT:" >> "$DEBUG_LOG"
#echo "$mountstats_excerpt" >> "$DEBUG_LOG"

# Check if block is empty
if [ -z "$block" ]; then
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): No block found for mountpoint=$MOUNTPOINT in /proc/self/mountstats" >> "$DEBUG_LOG"
  echo "ZBX_NOTSUPPORTED: No NFS data for mountpoint $MOUNTPOINT"
  exit 1
fi

# Log the extracted block for debugging
#echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Extracted block for $MOUNTPOINT:" >> "$DEBUG_LOG"
#echo "$block" >> "$DEBUG_LOG"

# Extract the requested metric
case "$METRIC" in
  age)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*age:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed age: $result" >> "$DEBUG_LOG"
    ;;
  bytes_read)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*bytes:" | awk '{print $2 + $4}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed bytes_read: $result" >> "$DEBUG_LOG"
    ;;
  bytes_written)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*bytes:" | awk '{print $3 + $5}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed bytes_written: $result" >> "$DEBUG_LOG"
    ;;
  read)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*READ:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed read: $result" >> "$DEBUG_LOG"
    ;;
  write)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*WRITE:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed write: $result" >> "$DEBUG_LOG"
    ;;
  retrans_total)
    result=$(echo "$block" | awk '
    BEGIN { sum = 0; in_per_op = 0 }
    /^per-op statistics/ { in_per_op = 1; next }
    in_per_op && /^[A-Z]+:/ { sum += $3 }
    END { print sum }
    ' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed retrans_total: $result" >> "$DEBUG_LOG"
    ;;
  getattr)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*GETATTR:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Raw getattr line: $(echo "$block" | grep -Ei "^[[:space:]]*GETATTR:")" >> "$DEBUG_LOG"
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed getattr: $result" >> "$DEBUG_LOG"
    ;;
  setattr)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*SETATTR:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed setattr: $result" >> "$DEBUG_LOG"
    ;;
  create)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*CREATE:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed create: $result" >> "$DEBUG_LOG"
    ;;
  mkdir)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*MKDIR:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed mkdir: $result" >> "$DEBUG_LOG"
    ;;
  symlink)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*SYMLINK:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed symlink: $result" >> "$DEBUG_LOG"
    ;;
  mknod)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*MKNOD:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed mknod: $result" >> "$DEBUG_LOG"
    ;;
  remove)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*REMOVE:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed remove: $result" >> "$DEBUG_LOG"
    ;;
  rmdir)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*RMDIR:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed rmdir: $result" >> "$DEBUG_LOG"
    ;;
  rename)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*RENAME:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed rename: $result" >> "$DEBUG_LOG"
    ;;
  link)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*LINK:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed link: $result" >> "$DEBUG_LOG"
    ;;
  readdir)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*READDIR:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed readdir: $result" >> "$DEBUG_LOG"
    ;;
  readdirplus)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*READDIRPLUS:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed readdirplus: $result" >> "$DEBUG_LOG"
    ;;
  fsstat)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*FSSTAT:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed fsstat: $result" >> "$DEBUG_LOG"
    ;;
  fsinfo)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*FSINFO:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed fsinfo: $result" >> "$DEBUG_LOG"
    ;;
  pathconf)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*PATHCONF:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed pathconf: $result" >> "$DEBUG_LOG"
    ;;
  commit)
    result=$(echo "$block" | grep -Ei "^[[:space:]]*COMMIT:" | awk '{print $2}' | tr -d '[:space:]')
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Parsed commit: $result" >> "$DEBUG_LOG"
    ;;
  *)
    #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Invalid metric=$METRIC" >> "$DEBUG_LOG"
    echo "ZBX_NOTSUPPORTED: Invalid metric $METRIC"
    exit 1
    ;;
esac

# Check if result is empty or non-numeric
if [ -z "$result" ] || ! [[ "$result" =~ ^[0-9]+$ ]]; then
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): No valid data for metric=$METRIC, result=$result" >> "$DEBUG_LOG"
  echo "ZBX_NOTSUPPORTED: No valid data for $METRIC on $MOUNTPOINT"
  exit 1
else
  #echo "$(date +'%Y-%m-%d %H:%M:%S.%N %Z'): Success, metric=$METRIC, result=$result" >> "$DEBUG_LOG"
  echo "$result"
fi

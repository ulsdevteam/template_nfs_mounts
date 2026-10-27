#!/bin/bash
# nfs_mount_stat.sh <mountpoint> <metric>
# Reads /proc/self/mountstats only. It never touches the mount itself,
# so it cannot hang when the NFS server is down.

MP="$1"
METRIC="$2"
STATS="${NFS_MOUNTSTATS:-/proc/self/mountstats}"   # override is for testing only

notsup() { echo "ZBX_NOTSUPPORTED: $1"; exit 1; }

[ -n "$MP" ] && [ -n "$METRIC" ] || notsup "Missing mountpoint or metric"

kind=op; op=""; a=0; b=0
case "$METRIC" in
  age)            kind=age ;;
  bytes_read)     kind=bytes; a=2; b=4 ;;     # normal + direct read bytes
  bytes_written)  kind=bytes; a=3; b=5 ;;     # normal + direct write bytes
  retrans_total)  kind=retrans ;;             # sum over ops of (transmissions - ops)
  fsstat)         op="FSSTAT|STATFS" ;;       # FSSTAT on NFSv3, STATFS on NFSv4
  read|write|getattr|setattr|create|mkdir|symlink|mknod|remove|rmdir|rename|link|readdir|readdirplus|fsinfo|pathconf|commit)
                  op="${METRIC^^}" ;;
  *)              notsup "Invalid metric $METRIC" ;;
esac

grep -Fq " mounted on $MP with fstype nfs" "$STATS" 2>/dev/null \
  || notsup "Mountpoint $MP is not an NFS mount"

result=$(awk -v mp="$MP" -v kind="$kind" -v op="$op" -v a="$a" -v b="$b" '
  $1 == "device" { inblk = (index($0, " mounted on " mp " with fstype nfs") > 0); perop = 0; next }
  !inblk         { next }
  $1 == "per-op" { perop = 1; next }
  kind == "age"     && $1 == "age:"   { val = $2; found = 1 }
  kind == "bytes"   && $1 == "bytes:" { val = $a + $b; found = 1 }
  kind == "op"      && perop && $1 ~ ("^(" op "):$") { val = $2; found = 1 }
  kind == "retrans" && perop && $1 ~ /^[A-Z_0-9]+:$/ { val += $3 - $2; found = 1 }
  END { if (found) printf "%.0f\n", val }
' "$STATS")

[[ "$result" =~ ^[0-9]+$ ]] || notsup "No valid data for $METRIC on $MP"
echo "$result"

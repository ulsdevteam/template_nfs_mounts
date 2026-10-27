#!/bin/bash
#
# nfs_mount_stat.sh - print one NFS statistic for one mount, for Zabbix.
#
# Usage:  nfs_mount_stat.sh <mount point> <metric>
# Example: nfs_mount_stat.sh /var/www/storage getattr
#
# The numbers come from /proc/self/mountstats, which the kernel keeps in
# memory. Reading it never talks to the NFS server, so this script cannot hang
# when a server is down.
#
# Output: a single whole number, or a line starting with ZBX_NOTSUPPORTED
# (which makes Zabbix mark the item unsupported) and exit status 1.
#
# Metrics
#   age                       seconds since the mount was made
#   bytes_read                bytes read by applications (normal + direct I/O)
#   bytes_written             bytes written by applications (normal + direct I/O)
#   retrans_total             RPC retransmissions, summed over all operations
#   read write getattr setattr create mkdir mknod symlink link remove rmdir
#   rename readdir readdirplus fsinfo pathconf commit
#                             number of NFS operations of that kind so far
#   fsstat                    same, for FSSTAT (NFSv3) or STATFS (NFSv4)
#
# Not every operation exists on every NFS version. NFSv4 has no MKDIR, RMDIR,
# MKNOD or READDIRPLUS, so asking for those on a v4 mount reports
# ZBX_NOTSUPPORTED.
#
# What a mount looks like in /proc/self/mountstats (abridged):
#
#   device nfs01:/export mounted on /mnt/data with fstype nfs4 statvers=1.1
#           age:    17229
#           bytes:  <normal read> <normal write> <direct read> <direct write> ...
#           per-op statistics
#                   READ: <operations> <transmissions> <timeouts> ...
#                GETATTR: <operations> <transmissions> <timeouts> ...

MOUNT_POINT="$1"
METRIC_NAME="$2"

# Where to read statistics from. Tests set NFS_MOUNTSTATS to a fixture file;
# normally this is /proc/self/mountstats.
MOUNTSTATS_FILE="${NFS_MOUNTSTATS:-/proc/self/mountstats}"

# Tell Zabbix this item has no value, with a reason, and stop.
report_unsupported() {
  echo "ZBX_NOTSUPPORTED: $1"
  exit 1
}

# --- Check the arguments ------------------------------------------------------

if [ -z "$MOUNT_POINT" ] || [ -z "$METRIC_NAME" ]; then
  report_unsupported "Missing mountpoint or metric"
fi

# --- Work out where in mountstats to look for this metric ---------------------
#
# Each metric is found in one of four ways ("lookup kind"):
#   age      the "age:" line of the mount
#   bytes    the "bytes:" line; add two of its columns
#   retrans  every per-operation line; add up (transmissions - operations)
#   op       one named per-operation line; take its operation count

lookup_kind="op"        # most metrics are plain operation counts
operation_pattern=""    # operation name(s) to look for, e.g. "GETATTR"
first_byte_column=0     # for "bytes": which two columns to add together
second_byte_column=0

case "$METRIC_NAME" in
  age)
    lookup_kind="age"
    ;;
  bytes_read)
    lookup_kind="bytes"
    first_byte_column=2     # normal reads
    second_byte_column=4    # direct reads
    ;;
  bytes_written)
    lookup_kind="bytes"
    first_byte_column=3     # normal writes
    second_byte_column=5    # direct writes
    ;;
  retrans_total)
    lookup_kind="retrans"
    ;;
  fsstat)
    # NFSv3 calls this operation FSSTAT, NFSv4 calls it STATFS.
    operation_pattern="FSSTAT|STATFS"
    ;;
  read|write|getattr|setattr|create|mkdir|mknod|symlink|link|remove|rmdir|rename|readdir|readdirplus|fsinfo|pathconf|commit)
    # The operation is listed in mountstats under the upper-case metric name.
    operation_pattern="${METRIC_NAME^^}"
    ;;
  *)
    report_unsupported "Invalid metric $METRIC_NAME"
    ;;
esac

# --- Make sure the mount point is an NFS mount --------------------------------
#
# mountstats describes each mount on a line like
#   "device <source> mounted on <mount point> with fstype nfs4 ..."
# grep -F matches the text literally, so characters such as "." in a path are
# not treated as wildcards.

if ! grep -Fq " mounted on $MOUNT_POINT with fstype nfs" "$MOUNTSTATS_FILE" 2>/dev/null; then
  report_unsupported "Mountpoint $MOUNT_POINT is not an NFS mount"
fi

# --- Read the number out of this mount's section of mountstats ----------------
#
# A mount's section starts at its "device" line and runs until the next
# "device" line. awk walks the file once and picks the value described by
# $lookup_kind. Every line is split into whitespace-separated columns, so
# $1 is the first word (for example "READ:"), $2 the second, and so on.

result=$(awk \
  -v mount_point="$MOUNT_POINT" \
  -v lookup_kind="$lookup_kind" \
  -v operation_pattern="$operation_pattern" \
  -v first_byte_column="$first_byte_column" \
  -v second_byte_column="$second_byte_column" '

  # A "device" line starts a new section. Remember whether it is ours.
  # index() compares plain text, so the mount point is not read as a pattern.
  $1 == "device" {
    inside_this_mount = (index($0, " mounted on " mount_point " with fstype nfs") > 0)
    inside_per_op_section = 0
    next
  }

  # Ignore everything that belongs to other mounts.
  !inside_this_mount { next }

  # The per-operation lines (READ:, GETATTR:, ...) come after this heading.
  $1 == "per-op" {
    inside_per_op_section = 1
    next
  }

  # age:    <seconds>
  lookup_kind == "age" && $1 == "age:" {
    value = $2
    found_value = 1
  }

  # bytes:  <normal read> <normal write> <direct read> <direct write> ...
  lookup_kind == "bytes" && $1 == "bytes:" {
    value = $first_byte_column + $second_byte_column
    found_value = 1
  }

  # READ:   <operations> <transmissions> <timeouts> ...
  # The first number is how many operations ran, which is what we report.
  lookup_kind == "op" && inside_per_op_section && $1 ~ ("^(" operation_pattern "):$") {
    value = $2
    found_value = 1
  }

  # Every operation line looks like "NAME: <operations> <transmissions> ...".
  # An operation sent more times than it ran was retransmitted, so
  # (transmissions - operations) is its retransmission count. Add them all up.
  lookup_kind == "retrans" && inside_per_op_section && $1 ~ /^[A-Z_0-9]+:$/ {
    value += $3 - $2
    found_value = 1
  }

  # printf "%.0f" prints large counters as whole numbers, never as 1e+09.
  END {
    if (found_value) {
      printf "%.0f\n", value
    }
  }
' "$MOUNTSTATS_FILE")

# --- Report the result --------------------------------------------------------

# Anything other than a whole number means the metric is not present for this
# mount (for example MKDIR on an NFSv4 mount).
if ! [[ "$result" =~ ^[0-9]+$ ]]; then
  report_unsupported "No valid data for $METRIC_NAME on $MOUNT_POINT"
fi

echo "$result"

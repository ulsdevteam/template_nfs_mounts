#!/bin/bash
# Tests for nfs_mount_stat.sh and nfs_discovery.sh using fixtures (no NFS mounts needed).
# Usage: tests/run_tests.sh      Requires bash, awk, grep, python3 (JSON validation only).
cd "$(dirname "$0")/.." || exit 1
FX=tests/fixtures; pass=0; fail=0
export NFS_MOUNTSTATS=$FX/mountstats_nfs.txt NFS_PROC_MOUNTS=$FX/proc_mounts.txt

check() { # description expected mountpoint metric
  local got; got=$(bash ./nfs_mount_stat.sh "$3" "$4")
  if [ "$got" == "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: expected [$2] got [$got]"; fi
}
V4=/var/www/peertube/storage; V3=/mnt/v3data
check "v4 age"               17229        $V4 age
check "v4 bytes_read"        947903661    $V4 bytes_read
check "v4 bytes_written"     664255       $V4 bytes_written
check "v4 read ops"          14368        $V4 read
check "v4 write ops"         425          $V4 write
check "v4 getattr"           16953        $V4 getattr
check "v4 fsstat (STATFS)"   1049         $V4 fsstat
check "v4 retrans_total"     0            $V4 retrans_total
check "v4 mkdir not on v4"   "ZBX_NOTSUPPORTED: No valid data for mkdir on $V4" $V4 mkdir
check "v3 age"               120          $V3 age
check "v3 bytes_read"        5000000300   $V3 bytes_read
check "v3 retrans_total"     8            $V3 retrans_total
check "v3 fsstat (FSSTAT)"   3            $V3 fsstat
check "v3 mkdir"             2            $V3 mkdir
check "prefix is not a mount" "ZBX_NOTSUPPORTED: Mountpoint /var/www/peertube is not an NFS mount" /var/www/peertube age
check "non-NFS mount"        "ZBX_NOTSUPPORTED: Mountpoint /proc is not an NFS mount" /proc age
check "bad metric"           "ZBX_NOTSUPPORTED: Invalid metric bogus" $V4 bogus
check "missing args"         "ZBX_NOTSUPPORTED: Missing mountpoint or metric" "" ""

out=$(bash ./nfs_discovery.sh)
n=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(len(d)); [print(x["{#MOUNTPOINT}"],x["{#SERVER}"],sep="|") for x in d]') \
  || { fail=$((fail+1)); echo "FAIL: discovery output is not valid JSON"; }
exp=$'4\n/var/www/peertube/storage|nfs-a.example.edu\n/mnt/v3data|10.0.0.9\n/mnt/v6|fe80::1\n/mnt/we"ird|srv'
if [ "$n" == "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: discovery: got:"; echo "$n"; fi

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]

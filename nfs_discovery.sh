#!/bin/bash
# nfs_discovery.sh - Zabbix LLD for NFS mounts.
# Reads /proc/self/mounts only, so it never touches the mounts and cannot hang.
# Emits {#MOUNTPOINT} and {#SERVER} (bare host/IP, IPv6 brackets stripped).

MOUNTS="${NFS_PROC_MOUNTS:-/proc/self/mounts}"   # override is for testing only

awk '
function jesc(s,   r, i, c) {
    r = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") r = r "\\"
        r = r c
    }
    return r
}
$3 ~ /^nfs4?$/ && !seen[$2]++ {
    i = index($1, ":/")
    srv = (i > 0) ? substr($1, 1, i - 1) : $1
    gsub(/^\[|\]$/, "", srv)
    out = out (n++ ? ",\n" : "") "    {\"{#MOUNTPOINT}\": \"" jesc($2) "\", \"{#SERVER}\": \"" jesc(srv) "\"}"
}
END { printf "{\n  \"data\": [\n%s\n  ]\n}\n", out }
' "$MOUNTS"

#!/bin/bash
#
# nfs_discovery.sh - Zabbix low-level discovery (LLD) for NFS mounts.
#
# Prints one JSON entry per NFS mount, in the format Zabbix expects:
#
#   {
#     "data": [
#       {"{#MOUNTPOINT}": "/mnt/data", "{#SERVER}": "nfs01.example.edu"}
#     ]
#   }
#
#   {#MOUNTPOINT}  where the share is mounted on this host
#   {#SERVER}      the NFS server's host name or IP (without the ":/export" part)
#
# The list comes from /proc/self/mounts, which the kernel keeps in memory.
# Unlike running df or ls on a mount, reading it can never hang, even when an
# NFS server is down.

# Where to read the mount list from. Tests set NFS_PROC_MOUNTS to point at a
# fixture file; normally this is just /proc/self/mounts.
PROC_MOUNTS_FILE="${NFS_PROC_MOUNTS:-/proc/self/mounts}"

awk '
# Make text safe to place inside a JSON string by adding a backslash in front
# of any double quote or backslash.
function json_escape(text,    escaped_text, position, character) {
    escaped_text = ""
    for (position = 1; position <= length(text); position++) {
        character = substr(text, position, 1)
        if (character == "\\" || character == "\"") {
            escaped_text = escaped_text "\\"
        }
        escaped_text = escaped_text character
    }
    return escaped_text
}

# Turn a mount source such as "nfs01.example.edu:/export/data" into just the
# server name "nfs01.example.edu".
function server_name_from(device,    separator_position, server) {
    # The server ends where the ":/" before the export path begins.
    separator_position = index(device, ":/")
    if (separator_position > 0) {
        server = substr(device, 1, separator_position - 1)
    } else {
        server = device
    }
    # IPv6 addresses are written in brackets, e.g. "[fe80::1]:/export".
    # Remove the brackets so only the address remains.
    gsub(/^\[|\]$/, "", server)
    return server
}

# Each line of /proc/self/mounts has the form:
#   <device> <mount point> <filesystem type> <options> <dump> <pass>
# so field 1 is the device, field 2 the mount point, field 3 the type.
{
    device      = $1
    mount_point = $2
    fs_type     = $3

    # Keep only NFS mounts (type "nfs" or "nfs4"), and report each mount
    # point once even if it appears on more than one line (stacked mounts).
    if (fs_type ~ /^nfs4?$/ && !(mount_point in already_reported)) {
        already_reported[mount_point] = 1

        json_entry = "    {\"{#MOUNTPOINT}\": \"" json_escape(mount_point) "\", " \
                     "\"{#SERVER}\": \""         json_escape(server_name_from(device)) "\"}"

        # Entries are separated by a comma and newline; there is no comma
        # before the first entry.
        if (entry_count > 0) {
            all_entries = all_entries ",\n"
        }
        all_entries = all_entries json_entry
        entry_count++
    }
}

# After the last line, print the complete JSON document. With no NFS mounts
# this is an empty list, which Zabbix accepts.
END {
    printf "{\n  \"data\": [\n%s\n  ]\n}\n", all_entries
}
' "$PROC_MOUNTS_FILE"

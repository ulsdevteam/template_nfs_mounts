# Zabbix NFS Client Mounts Monitoring

## Overview

This project provides a Zabbix template and associated scripts to monitor NFS (Network File System) client mounts on Linux systems. It uses Low-Level Discovery (LLD) to automatically detect NFS mounts and their associated servers, collecting metrics such as disk space usage, mount accessibility, server connectivity, and detailed NFS statistics (e.g., read/write operations, bytes transferred, retransmissions) from `/proc/self/mountstats`. The template includes item prototypes, trigger prototypes, and graph prototypes to visualize performance and alert on issues like low free space, stale mounts, or high retransmission rates.

Key features:
- **Automatic Discovery**: Discovers all NFS mounts and their servers using LLD.
- **Comprehensive Metrics**: Monitors disk space (total, free, used, % free), mount accessibility, server connectivity, and per-mount NFS statistics (e.g., `read`, `write`, `getattr`, `setattr`, `retrans_total`).
- **Triggers**: Alerts for inaccessible mounts, failed server connections, low free space (<10%), recent remounts, and high operation rates (>100/sec for various NFS operations).
- **Graphs**: Visualizes NFS operations, data transfer rates, retransmissions, and filesystem usage.

The project includes:
- `template_nfs_client_mounts.xml`: Zabbix template for NFS monitoring.
- `userparameter_nfs.conf`: Zabbix agent User Parameters for custom metrics.
- `nfs_discovery.sh`: Script for LLD of NFS mounts and servers.
- `nfs_mount_stat.sh`: Script to extract NFS statistics from `/proc/self/mountstats`.

## Requirements

### Software
- **Zabbix Server and Agent**: Version 5.0 or later.
- **Linux System**: The monitored host must run a Linux distribution with NFS client support and `/proc/self/mountstats` available.
- **Zabbix Agent**: Installed and running on the monitored host.
- **rpcbind**: Required for `nfs.server.check[*]` to verify NFS server connectivity (install via `apt install rpcbind` or `yum install rpcbind`).
- **Bash and Standard Utilities**: Scripts require `bash`, `awk`, `grep`, `mount`, and `rpcinfo`.

### Permissions
- **Zabbix Agent**: Must run as a user with read access to `/proc/self/mountstats` and execute permissions for scripts in `/usr/local/bin/`.
- **Scripts**: `nfs_discovery.sh` and `nfs_mount_stat.sh` must be executable (`chmod +x`).

### Hardware
- Minimal resource requirements; depends on the number of NFS mounts and polling frequency.

## Installation

### Step 1: Deploy Scripts
1. Copy the provided scripts to the monitored host:
   ```bash
   sudo cp nfs_discovery.sh /usr/local/bin/
   sudo cp nfs_mount_stat.sh /usr/local/bin/
   ```
2. Make the scripts executable:
   ```bash
   sudo chmod +x /usr/local/bin/nfs_discovery.sh
   sudo chmod +x /usr/local/bin/nfs_mount_stat.sh
   ```

### Step 2: Configure Zabbix Agent
1. Copy the User Parameters configuration to the Zabbix agent directory:
   ```bash
   sudo cp userparameter_nfs.conf /etc/zabbix/zabbix_agentd.d/
   ```
2. Restart the Zabbix agent to apply the configuration:
   ```bash
   sudo systemctl restart zabbix-agent
   ```
3. Verify the agent is running and no errors occur:
   ```bash
   grep -i error /var/log/zabbix/zabbix_agentd.log
   ```

### Step 3: Import the Zabbix Template
1. Log in to the Zabbix web interface.
2. Navigate to **Configuration > Templates > Import**.
3. Select `template_nfs_client_mounts.xml` and upload it.
4. Ensure the options "Create new" and "Update existing" are checked as needed.
5. Apply the template to hosts with NFS mounts.

### Step 4: Verify Monitoring
1. Wait for the Low-Level Discovery (LLD) to run (default interval: 1 hour) or force discovery:
   ```bash
   zabbix_get -s 127.0.0.1 -k nfs.discovery
   ```
2. Check **Monitoring > Latest Data** for items like:
   - `nfs.mount.stat[/mountpoint,read]`
   - `nfs.mount.stat[/mountpoint,write]`
   - `vfs.fs.size[/mountpoint,pfree]`
3. Verify graphs in **Monitoring > Graphs** (e.g., "NFS Operations on /sambashares", "NFS Data Transfer on /mountpoint").
4. Test specific metrics:
   ```bash
   zabbix_get -s 127.0.0.1 -k 'nfs.mount.stat[/mountpoint,read]'
   zabbix_get -s 127.0.0.1 -k 'nfs.mount.stat[/mountpoint,write]'
   zabbix_get -s 127.0.0.1 -k 'nfs.mount.stat[/mountpoint,getattr]'
   ```

### Troubleshooting
- **Import Errors**: Check `/var/log/zabbix/zabbix_server.log` for XML parsing issues.
- **Script Errors**: Review `/tmp/nfs_mount_stat_debug.log` for issues with `nfs_mount_stat.sh` (e.g., missing metrics like `getattr`).
  ```bash
  cat /tmp/nfs_mount_stat_debug.log | grep -A 5 "getattr"
  ```
- **Missing Metrics**: If metrics like `symlink` or `mknod` return `ZBX_NOTSUPPORTED`, verify their presence:
  ```bash
  grep -A 20 "[[:space:]]/mountpoint[[:space:]]" /proc/self/mountstats | grep -Ei "SYMLINK|MKNOD"
  ```
- **Dependencies**: Verify `rpcbind` is installed for `nfs.server.check[*]`:
  ```bash
  rpm -q rpcbind || apt install rpcbind
  ```

### Notes
- **Performance**: Adjust the LLD interval (default: 1h) or item polling intervals (default: 1m) if monitoring many mounts.


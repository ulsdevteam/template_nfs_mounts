# Zabbix NFS Client Mounts Monitoring

Zabbix template and agent scripts for monitoring NFS client mounts on Linux. Low-level discovery (LLD) finds each
NFS mount, then the template collects accessibility, server reachability, space usage and per-mount NFS statistics
read from `/proc/self/mountstats`.

## Versions

Each Zabbix major version has its own template because the XML import format and trigger expression syntax differ.
All three are generated from one definition (`tools/build_templates.py`) so they stay in sync.

| Folder | Zabbix | Status |
|--------|--------|--------|
| `5.0/` | 5.0 LTS | Regenerated in this release; import and confirm on a 5.0 server (the previous file was tested on 5.0.47) |
| `6.0/` | 6.0 LTS | Regenerated in this release; **not yet imported on a real server** |
| `7.0/` | 7.0 LTS | Regenerated in this release; **not yet imported on a real server** |

Update this table as each version is confirmed. `tests/lint_templates.py` checks structure (UUIDs, expression syntax,
dependencies, graph/item references) but is no substitute for an import test.

## What is monitored (per discovered mount)

| What | Key | Notes |
|------|-----|-------|
| Accessibility | `nfs.mount.check[{#MOUNTPOINT}]` | `stat` exit code: 0 OK, 124/137 hung, 1/2 missing or stale |
| Server reachable | `nfs.server.check[{#SERVER},{#MOUNTPOINT}]` | `rpcinfo` exit code: 0 OK, 124 timed out, other non-zero failed |
| Mount age | `nfs.mount.stat[{#MOUNTPOINT},age]` | seconds; a drop means a remount |
| Throughput | `...,bytes_read` / `...,bytes_written` | application-level bytes, as a rate |
| Operations/s | `...,read` `write` `getattr` `setattr` `create` `remove` `rename` `readdir` `commit` | ops that exist on NFSv3 and v4 |
| Retransmissions/s | `...,retrans_total` | sum over ops of (transmissions - ops) |
| Space | `vfs.fs.size[{#MOUNTPOINT},total/used/free/pfree]` | |

`nfs_mount_stat.sh` also supports `mkdir`, `rmdir`, `mknod`, `symlink`, `link`, `readdirplus`, `fsinfo`, `pathconf` and
`fsstat` (`FSSTAT` on v3, `STATFS` on v4). They are not in the template because several do not exist on NFSv4 mounts and
would be unsupported there; add item prototypes if you need them on v3.

## Triggers

| Trigger | Priority | Condition |
|---------|----------|-----------|
| NFS server not responding | High | server check non-zero twice in a row |
| NFS mount not accessible | High | `stat` check non-zero twice in a row |
| Free space below `{$NFS.PFREE.HIGH}`% (5) | High | depends on: not accessible |
| Free space below `{$NFS.PFREE.AVG}`% (10) | Average | depends on: the 5% trigger |
| Free space below `{$NFS.PFREE.WARN}`% (20) | Warning | depends on: the 10% trigger |
| Recently (re)mounted | Information | age below `{$NFS.AGE.MIN}` s (300) |
| Sustained RPC retransmissions | Warning | rate above `{$NFS.RETRANS.RATE}` (0) for 10 minutes |

Workload counters (operations/s) are collected and graphed but do not alert; "busy" is not a failure.

## Setup

1. **Scripts** (on each monitored host):
   ```
   sudo install -m 0755 nfs_discovery.sh nfs_mount_stat.sh /usr/local/bin/
   ```
2. **Agent config**: copy `userparameter_nfs.conf` into the directory your `zabbix_agentd.conf` `Include=` points at
   (commonly `/etc/zabbix/zabbix_agentd.d/` or `.conf.d/`), set `Timeout=10` in `zabbix_agentd.conf`, and restart the agent.
   The checks wrap `stat` and `rpcinfo` in `timeout`, which must stay below the agent `Timeout`.
3. **Template**: import `5.0/`, `6.0/` or `7.0/` to match your server (Data collection / Configuration > Templates > Import)
   and link it to the host. If you are replacing an older version, tick "Delete missing" for discovery rules.
4. **Verify** against the running agent from your Zabbix server or proxy (the host must be in the agent `Server=` list):
   ```
   zabbix_get -s HOST -k nfs.discovery
   zabbix_get -s HOST -k 'nfs.mount.stat[/mountpoint,age]'
   zabbix_get -s HOST -k 'nfs.mount.check[/mountpoint]'
   zabbix_get -s HOST -k 'nfs.server.check[SERVER,/mountpoint]'
   ```
   `zabbix_agentd -t` runs a separate process and can disagree with the daemon; trust `zabbix_get`.

## Requirements

Zabbix agent (passive checks) and server 5.0, 6.0 or 7.0; Linux with `/proc/self/mountstats`; `bash`, `awk`, `grep`,
`timeout`, `stat`. `rpcinfo` (package `rpcbind` or `rpcbind-utils`) is needed only for the default server check. Servers that do
not answer rpcinfo (some NFSv4-only setups) can use the TCP 2049 variant in `userparameter_nfs.conf`.
The agent user needs read access to `/proc/self/mountstats` and execute access to the scripts. It needs no `sudo` access: the scripts read `/proc` and never run `mount`.

**SELinux (RHEL and derivatives).** In enforcing mode the agent runs in the `zabbix_agent_t` domain, which is not allowed to
connect to the portmapper (111) or NFS (2049) ports, so `nfs.server.check` returns non-zero under the agent even though
`rpcinfo` works from a shell. Install the small policy module in `selinux/` (build steps are in the file header). It grants
only those two connections. The other checks need nothing: they read `/proc` and run `stat`.

## Development

```
tests/run_tests.sh                 # script tests against fixtures (real NFSv4 mountstats data + a synthetic v3 mount)
python3 tools/build_templates.py   # regenerate 5.0/6.0/7.0 XML (edit the definition at the top of the script, not the XML)
python3 tests/lint_templates.py    # structural lint of the generated templates
```

The scripts honour `NFS_MOUNTSTATS` and `NFS_PROC_MOUNTS` to read fixtures instead of `/proc`.

## Adding a metric

There are two cases. Most additions are the first one.

### A. Another NFS operation count (for example LOOKUP)

Operation names are listed under `per-op statistics` in `/proc/self/mountstats`. You can see which ones your mounts
have with `grep -A100 'mounted on /your/mount ' /proc/self/mountstats`. Names differ between NFS versions, and a
name that is missing on a mount makes the item unsupported there. The worked example below adds `lookup`.

1. **Script.** In `nfs_mount_stat.sh`, add the lower-case name to the operation list in the `case` block:

   ```
   read|write|getattr|...|pathconf|commit|lookup)
   ```

   The script looks the operation up under the upper-case version of the name (`LOOKUP:`). If the operation has a
   different name on NFSv3 and NFSv4 (as `fsstat` does: `FSSTAT` / `STATFS`), add its own `case` branch that sets
   `operation_pattern` to both names instead, like the existing `fsstat` branch.
2. **Test.** In `tests/run_tests.sh`, add a line next to the other `check` lines, using a value from
   `tests/fixtures/mountstats_nfs.txt` (the NFSv4 mount has `LOOKUP: 6773 ...`):

   ```
   check "v4 lookup"            6773         $V4 lookup
   ```

   If the operation does not exist in the fixture, add a line for it to the fixture first. Run `tests/run_tests.sh`.
3. **Template.** In `tools/build_templates.py`, add the name to the `OPS` list. That one change creates the item
   prototype (as a per-second rate) and adds it to the operations graph. Then regenerate and lint:

   ```
   python3 tools/build_templates.py
   python3 tests/lint_templates.py
   ```
4. **Deploy.** Copy the updated `nfs_mount_stat.sh` to `/usr/local/bin/` on each host, and re-import the template for
   your Zabbix version. A new item prototype appears for every mount at the next discovery run.
5. **Document.** Add it to the operations row of the table under "What is monitored".

Adding a trigger works the same way: add an entry to `TRIGGERS` in `tools/build_templates.py`. The script writes the
right expression syntax for each Zabbix version, so write the entry once.

### B. A different kind of value (for example average round-trip time)

Operation lines carry more than the count. After the operation name the columns are: operations, transmissions,
major timeouts, bytes sent, bytes received, cumulative queue time (ms), cumulative round-trip time (ms), cumulative
execution time (ms), and on newer kernels an error count. A latency metric reads one of those columns, so it needs
its own lookup rather than just a name in the list:

1. In `nfs_mount_stat.sh`, add a new `lookup_kind` in the `case` block (for example `rtt`) that sets the operation
   and the column, then add a matching rule in the `awk` block next to the `op` rule. The `op` rule reads `$2`; yours
   would read `$7` for the round-trip column.
2. Cumulative milliseconds only mean something divided by the operation count over the same interval. Either add a
   second metric that returns the count, or compute the average in Zabbix with a calculated item. A raw
   cumulative-milliseconds item with *Change per second* shows total wait time per second, not latency.
3. Add a fixture value, a test, and an entry in `tools/build_templates.py` as in steps 2 to 5 above. Because the
   existing rate preprocessing is attached to the `rate` flag in `ITEMS`, a new item with a different shape needs its
   own `ITEMS` entry rather than an addition to `OPS`.

## Troubleshooting

- **`nfs.server.check` is non-zero under the agent but `rpcinfo` works in a shell** (also as `sudo -u zabbix`): SELinux. Run
  `ausearch -m avc -c rpcinfo -ts recent` and look for `name_connect` denials on ports 111 and 2049, then install `selinux/zabbix_nfs_rpcinfo.te`.
- **`nfs.mount.stat` returns `ZBX_NOTSUPPORTED: No valid data for X`**: that operation is not listed for this mount's NFS version. Check
  `grep -A100 'mounted on /mountpoint ' /proc/self/mountstats`.
- **Server check is non-zero but the mount works**: run `rpcinfo -t SERVER 100003`; if it fails, use the TCP 2049 variant of `nfs.server.check`.
- **Mount points containing spaces** are not supported (the kernel escapes them as `\040`).
- **Agent newer than server** (for example a 6.0 agent on a 5.0 server) usually works for passive checks but is unsupported; upgrade the server first.

## References

- https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/nfs_iostat.h
- https://utcc.utoronto.ca/~cks/space/blog/linux/NFSMountstatsBytesEvents
- https://www.zabbix.com/documentation/guidelines/en/thosts/key_principles
- https://www.zabbix.com/documentation/guidelines/en/thosts/template_styling#template-styling

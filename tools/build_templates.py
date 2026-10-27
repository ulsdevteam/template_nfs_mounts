#!/usr/bin/env python3
"""Generate the Zabbix NFS client template for 5.0, 6.0 and 7.0 from one definition.

Usage: tools/build_templates.py [repo_root]   (writes <root>/<ver>/template_nfs_client_mounts_<ver>.xml)

The formats differ in ways that matter on import:
  5.0      {Template:key.func()} expressions, <params>, applications, no UUIDs, root <groups>
  6.0/7.0  func(/Template/key,args) expressions, <parameters>, tags, UUIDv4s
  7.0      root <template_groups> instead of <groups>
UUIDs are derived deterministically from entity names so regenerating never changes them.
"""
import hashlib, sys, os, xml.etree.ElementTree as ET

T = "Template NFS Client Mounts"
GROUP = "Templates/Operating systems"
MP, SRV = "{#MOUNTPOINT}", "{#SERVER}"
DATE = "2026-10-26T20:00:00Z"

def uuid4(name):
    b = bytearray(hashlib.sha256(("template_nfs_mounts:" + name).encode()).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    return b.hex()

# ---- definition ---------------------------------------------------------------------------
OPS = ["read", "write", "getattr", "setattr", "create", "remove", "rename", "readdir", "commit"]
K_CHECK, K_SRV = f"nfs.mount.check[{MP}]", f"nfs.server.check[{SRV},{MP}]"
K_AGE, K_RETR = f"nfs.mount.stat[{MP},age]", f"nfs.mount.stat[{MP},retrans_total]"
K_PF = f"vfs.fs.size[{MP},pfree]"

ITEMS = [  # name, key, delay, value_type, units, description, rate?
    (f"NFS mount [{MP}] accessibility (stat exit code)", K_CHECK, "1m", "UNSIGNED", None,
     "Exit code of a timed stat on the mount point. 0 = OK, 124/137 = hung (timeout fired), 1/2 = missing or stale handle.", False),
    (f"NFS server [{SRV}] rpcinfo exit code (mount {MP})", K_SRV, "1m", "UNSIGNED", None,
     "Exit code of rpcinfo for the NFS program (100003). 0 = server answers, 124 = timed out, other non-zero = rpcinfo failed.", False),
    (f"NFS mount [{MP}] age", K_AGE, "1m", "UNSIGNED", "s", "Seconds since the mount was established.", False),
    (f"NFS mount [{MP}] bytes read (application level)", f"nfs.mount.stat[{MP},bytes_read]", "1m", "FLOAT", "Bps", None, True),
    (f"NFS mount [{MP}] bytes written (application level)", f"nfs.mount.stat[{MP},bytes_written]", "1m", "FLOAT", "Bps", None, True),
] + [(f"NFS mount [{MP}] {o.upper()} operations/s", f"nfs.mount.stat[{MP},{o}]", "1m", "FLOAT", "ops/s", None, True) for o in OPS] + [
    (f"NFS mount [{MP}] RPC retransmissions/s", K_RETR, "1m", "FLOAT", "retrans/s", "Sum over all ops of (transmissions - ops).", True),
    (f"NFS mount [{MP}] free space", f"vfs.fs.size[{MP},free]", "5m", "UNSIGNED", "B", None, False),
    (f"NFS mount [{MP}] free space (%)", K_PF, "5m", "FLOAT", "%", None, False),
    (f"NFS mount [{MP}] total space", f"vfs.fs.size[{MP},total]", "5m", "UNSIGNED", "B", None, False),
    (f"NFS mount [{MP}] used space", f"vfs.fs.size[{MP},used]", "5m", "UNSIGNED", "B", None, False),
]
MACROS = [("{$NFS.PFREE.HIGH}", "5", "Free space % below which HIGH fires"),
          ("{$NFS.PFREE.AVG}", "10", "Free space % below which AVERAGE fires"),
          ("{$NFS.PFREE.WARN}", "20", "Free space % below which WARNING fires"),
          ("{$NFS.AGE.MIN}", "300", "Mount age (s) under which a remount is reported"),
          ("{$NFS.RETRANS.RATE}", "0", "RPC retransmissions/s that must be exceeded for 10m to alert")]
# id, (key, func, args, operator+rhs), name, priority, description, depends_on
TRIGGERS = [
    ("srv", (K_SRV, "min", "#2", ">0"), f"NFS server {SRV} is not responding (checked for {MP})", "HIGH",
     "The server check (rpcinfo) returned a non-zero exit code twice in a row.", None),
    ("acc", (K_CHECK, "min", "#2", ">0"), f"NFS mount {MP} is not accessible", "HIGH",
     "stat on the mount point failed or timed out twice in a row (hung or stale mount).", None),
    ("pf5", (K_PF, "last", "", "<{$NFS.PFREE.HIGH}"), f"NFS mount {MP}: free space below {{$NFS.PFREE.HIGH}}%", "HIGH", "", "acc"),
    ("pf10", (K_PF, "last", "", "<{$NFS.PFREE.AVG}"), f"NFS mount {MP}: free space below {{$NFS.PFREE.AVG}}%", "AVERAGE", "", "pf5"),
    ("pf20", (K_PF, "last", "", "<{$NFS.PFREE.WARN}"), f"NFS mount {MP}: free space below {{$NFS.PFREE.WARN}}%", "WARNING", "", "pf10"),
    ("age", (K_AGE, "last", "", "<{$NFS.AGE.MIN}"), f"NFS mount {MP} was (re)mounted less than {{$NFS.AGE.MIN}}s ago", "INFO",
     "Mount age is below the threshold; the filesystem was recently mounted or remounted.", "acc"),
    ("retr", (K_RETR, "min", "10m", ">{$NFS.RETRANS.RATE}"), f"NFS mount {MP}: sustained RPC retransmissions", "WARNING",
     "Retransmissions occurred in every sample for 10 minutes; check the network path and server load.", "acc"),
]
GRAPHS = [
    (f"NFS throughput on {MP}", [f"nfs.mount.stat[{MP},bytes_read]", f"nfs.mount.stat[{MP},bytes_written]"], False),
    (f"NFS operations/s on {MP}", [f"nfs.mount.stat[{MP},{o}]" for o in OPS], False),
    (f"NFS RPC retransmissions on {MP}", [K_RETR], False),
    (f"NFS free space (%) on {MP}", [K_PF], True),
    (f"NFS space usage on {MP}", [f"vfs.fs.size[{MP},total]", f"vfs.fs.size[{MP},used]"], False),
]
COLORS = ["1A7C11", "F63100", "2774A4", "A54F10", "FC6EA3", "6C59DC", "AC8C14", "611F27", "F230E0"]

# ---- emitters -----------------------------------------------------------------------------
def expr(v, spec):
    key, fn, args, tail = spec
    if v == "5.0":
        return "{%s:%s.%s(%s)}%s" % (T, key, fn, args, tail)
    a = f",{args}" if args else ""
    return f"{fn}(/{T}/{key}{a}){tail}"

def sub(p, tag, text=None):
    e = ET.SubElement(p, tag)
    if text is not None:
        e.text = text
    return e

def build(v):
    modern = v != "5.0"
    root = ET.Element("zabbix_export")
    sub(root, "version", v); sub(root, "date", DATE)
    gtag = "template_groups" if v == "7.0" else "groups"
    g = sub(sub(root, gtag), "group")
    if modern: sub(g, "uuid", uuid4("group"))
    sub(g, "name", GROUP)
    tpl = sub(sub(root, "templates"), "template")
    if modern: sub(tpl, "uuid", uuid4("template"))
    sub(tpl, "template", T); sub(tpl, "name", T)
    sub(tpl, "description", "NFS client monitoring: per-mount accessibility (stat), server reachability, space usage and "
        "statistics from /proc/self/mountstats. Needs userparameter_nfs.conf, nfs_discovery.sh and nfs_mount_stat.sh on the host.")
    sub(sub(sub(tpl, "groups"), "group"), "name", GROUP)
    ms = sub(tpl, "macros")
    for m, val, d in MACROS:
        e = sub(ms, "macro"); sub(e, "macro", m); sub(e, "value", val); sub(e, "description", d)
    dr = sub(sub(tpl, "discovery_rules"), "discovery_rule")
    if modern: sub(dr, "uuid", uuid4("lld"))
    sub(dr, "name", "NFS mounts discovery"); sub(dr, "key", "nfs.discovery"); sub(dr, "delay", "15m"); sub(dr, "lifetime", "7d")
    sub(dr, "description", "Returns {#MOUNTPOINT} and {#SERVER} (bare host name or IP) for each NFS mount.")
    ips = sub(dr, "item_prototypes")
    for name, key, delay, vt, units, desc, rate in ITEMS:
        ip = sub(ips, "item_prototype")
        if modern: sub(ip, "uuid", uuid4("item:" + key))
        sub(ip, "name", name); sub(ip, "key", key); sub(ip, "delay", delay)
        if rate: sub(ip, "history", "30d")
        if vt != "UNSIGNED": sub(ip, "value_type", vt)
        if units: sub(ip, "units", units)
        if desc: sub(ip, "description", desc)
        if modern:
            tg = sub(sub(ip, "tags"), "tag"); sub(tg, "tag", "component"); sub(tg, "value", "nfs")
        else:
            sub(sub(sub(ip, "application_prototypes"), "application_prototype"), "name", "NFS " + MP)
        if rate:
            st = sub(sub(ip, "preprocessing"), "step"); sub(st, "type", "CHANGE_PER_SECOND")
            sub(st, "parameters" if modern else "params")
    tps = sub(dr, "trigger_prototypes"); made = {}
    for id_, spec, name, prio, desc, dep in TRIGGERS:
        tp = sub(tps, "trigger_prototype")
        if modern: sub(tp, "uuid", uuid4("trigger:" + id_))
        e = expr(v, spec)
        sub(tp, "expression", e); sub(tp, "name", name); sub(tp, "priority", prio)
        if desc: sub(tp, "description", desc)
        if dep:
            d = sub(sub(tp, "dependencies"), "dependency"); sub(d, "name", made[dep][0]); sub(d, "expression", made[dep][1])
        if modern:
            tg = sub(sub(tp, "tags"), "tag"); sub(tg, "tag", "scope"); sub(tg, "value", "availability")
        made[id_] = (name, e)
    gps = sub(dr, "graph_prototypes")
    for name, keys, fixed in GRAPHS:
        gp = sub(gps, "graph_prototype")
        if modern: sub(gp, "uuid", uuid4("graph:" + name))
        sub(gp, "name", name)
        if fixed:
            sub(gp, "yaxismin", "0"); sub(gp, "yaxismax", "100")
            sub(gp, "ymin_type_1", "FIXED"); sub(gp, "ymax_type_1", "FIXED")
        gis = sub(gp, "graph_items")
        for i, k in enumerate(keys):
            gi = sub(gis, "graph_item"); sub(gi, "sortorder", str(i)); sub(gi, "color", COLORS[i % len(COLORS)])
            it = sub(gi, "item"); sub(it, "host", T); sub(it, "key", k)
    ET.indent(root, space="    ")
    return ET.ElementTree(root)

def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..")
    for v in ("5.0", "6.0", "7.0"):
        path = os.path.join(base, v, f"template_nfs_client_mounts_{v}.xml")
        build(v).write(path, encoding="UTF-8", xml_declaration=True)
        print("wrote", os.path.normpath(path))

if __name__ == "__main__":
    main()

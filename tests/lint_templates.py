#!/usr/bin/env python3
"""Structural lint for the generated templates. Not a substitute for importing into a real Zabbix,
but it catches the mistakes that made earlier 6.0/7.0 files unimportable.
Usage: tests/lint_templates.py [repo_root | path/to/template.xml version]"""
import re, sys, os, xml.etree.ElementTree as ET

LEGACY = {"applications", "application_prototypes", "items", "host_prototypes", "value_maps", "httptests", "graphs", "triggers"}
ENUM_TAGS = {"type", "value_type", "priority", "status", "drawtype"}
UUID4 = re.compile(r"[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}")

def lint(path, v):
    errs = []; r = ET.parse(path).getroot(); modern = v != "5.0"
    if r.findtext("version") != v: errs.append(f"version tag is {r.findtext('version')!r}, expected {v}")
    want_root = "template_groups" if v == "7.0" else "groups"
    if r.find(want_root) is None: errs.append(f"root <{want_root}> missing")
    tags = {e.tag for e in r.iter()}
    if modern:
        for t in sorted(tags & (LEGACY | {"params", "application_prototypes"})):
            if t != "graphs" or r.find("graphs") is not None: errs.append(f"legacy tag <{t}> in {v} file")
        if "params" in tags: errs.append("<params> used; 6.0+ uses <parameters>")
        us = [u.text for u in r.iter("uuid")]
        errs += [f"invalid UUIDv4: {u}" for u in us if not UUID4.fullmatch(u or "")]
        if len(us) != len(set(us)): errs.append("duplicate UUIDs")
    else:
        if "uuid" in tags: errs.append("<uuid> present in 5.0 file")
    for e in r.iter():
        if e.tag in ENUM_TAGS and (e.text or "").strip().isdigit(): errs.append(f"numeric enum <{e.tag}>{e.text}")
    dr = r.find(".//discovery_rule")
    keys = [i.findtext("key") for i in dr.iter("item_prototype")]
    if len(keys) != len(set(keys)): errs.append("duplicate item prototype keys")
    trig = {}; tname = r.findtext("templates/template/template")
    for tp in dr.iter("trigger_prototype"):
        ex = tp.findtext("expression"); trig[tp.findtext("name")] = ex
        if modern and not re.match(r"\w+\(/" + re.escape(tname) + "/", ex): errs.append(f"not a {v} expression: {ex}")
        if not modern and not re.match(r"\{" + re.escape(tname) + r":.+\.\w+\([^)]*\)\}", ex): errs.append(f"not a 5.0 expression: {ex}")
        if re.search(r"change\(0,", ex): errs.append(f"invalid change() call: {ex}")
        if not any(k in ex for k in keys): errs.append(f"trigger references no known item: {ex}")
    for tp in dr.iter("trigger_prototype"):
        for d in tp.iter("dependency"):
            if trig.get(d.findtext("name")) != d.findtext("expression"): errs.append(f"unresolved dependency {d.findtext('name')}")
    for gi in dr.iter("graph_item"):
        if gi.findtext("item/key") not in keys: errs.append(f"graph references unknown item {gi.findtext('item/key')}")
    return errs, set(keys)

def main():
    a = sys.argv[1:]
    jobs = [(a[0], a[1])] if len(a) == 2 else [(os.path.join(a[0] if a else ".", v, f"template_nfs_client_mounts_{v}.xml"), v) for v in ("5.0", "6.0", "7.0")]
    bad = 0; keysets = []
    for p, v in jobs:
        errs, ks = lint(p, v); keysets.append(ks); bad += len(errs)
        print(f"{v}: {'OK' if not errs else str(len(errs)) + ' problem(s)'}  ({p})")
        for e in errs[:12]: print("   -", e)
        if len(errs) > 12: print(f"   ... and {len(errs) - 12} more")
    if len(keysets) == 3 and not (keysets[0] == keysets[1] == keysets[2]): print("item keys differ between versions"); bad += 1
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()

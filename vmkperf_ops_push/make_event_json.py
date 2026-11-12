#!/usr/bin/env python3
"""make_event_json.py - build a per-CPU-generation event file for vmkperf_ops_push

Reads an intel/perfmon core event JSON (e.g. SPR/events/sapphirerapids_core.json)
and writes events/<cpu>.json holding only the events this collector uses,
with EventCode / UMask / CounterMask copied verbatim from Intel's file.

Usage (on the analysis machine, not on ESXi):
    python3 make_event_json.py sapphirerapids /path/to/sapphirerapids_core.json 6-143
    python3 make_event_json.py graniterapids  /path/to/graniterapids_core.json  6-173,6-174

Event selection order == counter priority. The first four 'restricted'
events (Counter 0-3 only) are the most the hardware can run at once;
anything beyond that is started only if a counter is free.
"""
import json, sys, os, datetime

# key, Intel EventName, description shown in the doc/CSV header
WANTED = [
    ("llc_miss",        "LONGEST_LAT_CACHE.MISS",                             "LLC misses (demand + prefetch)"),
    ("llc_ref",         "LONGEST_LAT_CACHE.REFERENCE",                        "LLC references"),
    ("cycles",          "CPU_CLK_UNHALTED.THREAD_P",                          "unhalted core cycles"),
    ("instr",           "INST_RETIRED.ANY_P",                                 "retired instructions"),
    ("l3_load_miss",    "MEM_LOAD_RETIRED.L3_MISS",                           "retired demand loads that missed L3"),
    ("l3miss_rd",       "OFFCORE_REQUESTS.L3_MISS_DEMAND_DATA_RD",            "offcore demand data reads that missed L3"),
    ("l3miss_rd_outst", "OFFCORE_REQUESTS_OUTSTANDING.L3_MISS_DEMAND_DATA_RD","outstanding cycles of those reads (sum)"),
    ("l3_stall",        "MEMORY_ACTIVITY.STALLS_L3_MISS",                     "execution stall cycles with an L3 miss pending"),
    ("l3_load_hit",     "MEM_LOAD_RETIRED.L3_HIT",                            "retired demand loads that hit L3"),
]

def main():
    if len(sys.argv) < 4:
        print(__doc__); sys.exit(1)
    cpu, src, fm = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
    d = json.load(open(src))
    hdr = d.get("Header", {})
    byname = {e["EventName"]: e for e in d["Events"]}
    out = {
        "cpu": cpu,
        "family_model": fm,
        "source": "intel/perfmon %s V%s (DatePublished %s)" % (
            os.path.basename(src), hdr.get("Version", "?"), hdr.get("DatePublished", "?")),
        "generated": datetime.date.today().isoformat(),
        "events": [],
    }
    missing = []
    for key, name, desc in WANTED:
        e = byname.get(name)
        if not e:
            missing.append(name); continue
        ctr = e.get("Counter", "")
        out["events"].append({
            "key": key, "name": name,
            "event": e["EventCode"].lower(), "umask": e["UMask"].lower(),
            "cmask": int(e.get("CounterMask", "0") or 0),
            "counters": ctr,
            "restricted": not ("4" in ctr and "7" in ctr),
            "desc": desc,
        })
    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "events", cpu + ".json")
    json.dump(out, open(dst, "w"), indent=2)
    print("wrote", dst, "events", len(out["events"]), "missing", missing)

if __name__ == "__main__":
    main()

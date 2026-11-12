#!/usr/bin/env python3
"""make_event_json_amd.py - build the AMD event files for vmkperf_ops_push

Reads the Linux kernel perf event list of one AMD Zen generation
(tools/perf/pmu-events/arch/x86/amdzen<N>/*.json, maintained by AMD) and writes
events/<name>.json holding only the core-PMC events this collector uses, with
EventCode / UMask copied verbatim from those files.

Usage (on the analysis machine, not on ESXi):
    python3 make_event_json_amd.py naples /path/to/amdzen1 "source note"
    python3 make_event_json_amd.py rome   /path/to/amdzen2 "source note"
    python3 make_event_json_amd.py milan  /path/to/amdzen3 "source note"
    python3 make_event_json_amd.py genoa  /path/to/amdzen4 "source note"
    python3 make_event_json_amd.py turin  /path/to/amdzen5 "source note"

One file per Zen generation, named after its first EPYC server line:
    naples = Zen 1   rome = Zen 2   milan = Zen 3   genoa = Zen 4   turin = Zen 5
The CPUID family-model values in each file are the ones the Broadcom Compatibility Guide lists
for ESXi 8.0 and later. events/cpu_map.json also holds the model ranges the kernel uses to
choose the list (tools/perf/pmu-events/arch/x86/mapfile.csv).

Which events [v1.5]: the collector has one metric set, events/metrics.json, and its nine event
keys are the ones of the Intel event files (llc_miss, llc_ref, cycles, instr, l3_load_miss,
l3miss_rd, l3miss_rd_outst, l3_stall, l3_load_hit). Of these, an AMD core performance counter
has two: cycles (ls_not_halted_cyc) and instr (ex_ret_instr). The LLC and L3 keys have no AMD
core event (the L3 events of AMD belong to the L3 PMU, which is not a core counter), so the
AMD files hold cycles and instr only, and the metrics that need another key stay empty.

These CPUs have six core performance counters per logical CPU and no fixed counter, so cycles
and instr take two of the six.
"""
import json, sys, os, glob, datetime

DESC = {
    "cycles":       "core cycles not in halt",
    "instr":        "retired instructions",
}
# key order = counter priority
ORDER = ["cycles", "instr"]

# AMD event name per key; the same in the event list of every generation
NAMES = {"cycles": "ls_not_halted_cyc", "instr": "ex_ret_instr"}

GENERATIONS = {
    "naples": {"list": "amdzen1", "family_model": ["23-1", "23-17"],
               "label": "AMD Zen 1: EPYC 7001 Series (CPUID 17.01), Ryzen Embedded V1000 Series (17.11)"},
    "rome":   {"list": "amdzen2", "family_model": ["23-49"],
               "label": "AMD Zen 2: EPYC 7002/7Fx2/7Hx2 Series (CPUID 17.31)"},
    "milan":  {"list": "amdzen3", "family_model": ["25-1"],
               "label": "AMD Zen 3: EPYC 7003/7003X Series (CPUID 19.01)"},
    "genoa":  {"list": "amdzen4", "family_model": ["25-17", "25-160"],
               "label": "AMD Zen 4: EPYC 9004 Series (CPUID 19.11, 19.A0), EPYC 8004 Series (19.A0)"},
    "turin":  {"list": "amdzen5", "family_model": ["26-2", "26-17"],
               "label": "AMD Zen 5: EPYC 9005 Series (CPUID 1A.2, 1A.11)"},
}
GP_COUNTERS = 6          # core PMCs per logical CPU (kernel: AMD64_NUM_COUNTERS_CORE)
LOG_KEYS = ["IPC"]       # what the per-interval log line shows: the one ratio with inputs on AMD

def main():
    if len(sys.argv) < 3 or sys.argv[1] not in GENERATIONS:
        print(__doc__); sys.exit(1)
    cpu, src = sys.argv[1], sys.argv[2]
    note = sys.argv[3] if len(sys.argv) > 3 else ""
    gen = GENERATIONS[cpu]
    byname = {}
    for f in sorted(glob.glob(os.path.join(src, "*.json"))):
        for e in json.load(open(f)):
            if "EventName" in e and e.get("Unit", "core") == "core":
                byname[e["EventName"]] = (e, os.path.basename(f))
    ctrs = ",".join(str(i) for i in range(GP_COUNTERS))
    out = {
        "cpu": cpu,
        "vendor": "amd",
        "label": gen["label"],
        "family_model": gen["family_model"],
        "source": "Linux kernel tools/perf/pmu-events/arch/x86/%s %s" % (gen["list"], note),
        "generated": datetime.date.today().isoformat(),
        "gp_counters": GP_COUNTERS,
        "fixed_cycles": False,
        "events": [],
        "log_keys": LOG_KEYS,
    }
    missing = []
    for key in ORDER:
        name = NAMES[key]
        if name not in byname:
            missing.append(name); continue
        e, fn = byname[name]
        code = int(e["EventCode"], 16)
        if code > 0xFF:
            raise SystemExit("event %s has a 12-bit code %s; vmkperf -e takes 8 bits here" % (name, e["EventCode"]))
        umask = int(e.get("UMask", "0x0") or "0x0", 16)
        out["events"].append({
            "key": key, "name": name,
            "event": "0x%02x" % code, "umask": "0x%02x" % umask,
            "cmask": 0,
            "counters": ctrs,
            "restricted": False,
            "desc": DESC[key],
            "file": fn,
        })
    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "events", cpu + ".json")
    json.dump(out, open(dst, "w"), indent=2)
    print("wrote", dst, "events", len(out["events"]), "missing", missing)
    if missing:
        sys.exit(1)

if __name__ == "__main__":
    main()

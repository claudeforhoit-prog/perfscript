#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""수집기 코드에서 스크립트별 수집 지표 목록(METRICS.md)을 만든다.

사용: python3 tools/gen_metrics.py            # 저장소 루트의 METRICS.md 를 다시 쓴다
      python3 tools/gen_metrics.py --check    # METRICS.md 가 코드와 같은지만 확인 (다르면 종료 코드 1)

읽는 곳
  게스트  ops_metric_push.sh 의 METRIC_TABLE
  GPU     gpu_metric_push.sh 의 METRIC_TABLE, PROP_TABLE
  호스트  vmkperf_ops_push/events/*.json 과 vmkperf_ops_push.py 의 plan_counters()
"""
import sys, os, re, json, glob, importlib.util

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "METRICS.md")

def shell_block(path, name):
    t = open(path, encoding="utf-8").read()
    m = re.search(r'^%s="\n(.*?)^"' % name, t, re.S | re.M)
    if not m:
        raise SystemExit("%s: %s not found" % (path, name))
    return [l for l in m.group(1).splitlines() if l.strip() and not l.lstrip().startswith("#")]

def version(path, pat):
    m = re.search(pat, open(path, encoding="utf-8").read(), re.M)
    return m.group(1) if m else "?"

def esc(s):
    return str(s).replace("|", "\\|")

def table(head, rows):
    out = ["| " + " | ".join(esc(h) for h in head) + " |", "|" + "|".join([" :-- "] * len(head)) + "|"]
    out += ["| " + " | ".join(esc(c) for c in r) + " |" for r in rows]
    return "\n".join(out)

CALC = {"raw": "값 그대로", "ratio": "s1/s2", "pct": "s1/s2×100", "spct": "s1/(s1+s2)×100",
        "delta": "1분 증가분", "dspct": "Δs1/(Δs1+Δs2)×100", "pti": "s1/s2×1000"}

INTEL_CLS = {"intel_skx": "SKX", "intel_icx": "ICX", "intel_spr": "SPR", "intel_emr": "EMR", "intel_gnr": "GNR"}

def cpu_label(c):
    if not c:
        return "전체"
    neg = c.startswith("cpu!=")
    out, intel = [], []
    for p in c.split("=", 1)[1].split(","):
        if p in INTEL_CLS:
            intel.append(INTEL_CLS[p])
        elif p == "intel":
            out.append("Intel 전체")
        elif p == "amd_zen":
            out.append("AMD Zen 전체")
        elif p.startswith("amd_zen"):
            out.append("Zen " + p[len("amd_zen"):])
        else:
            out.append(p)
    if intel:
        out.append("Intel " + ", ".join(intel))
    v = ", ".join(out)
    return ("AMD Zen 제외" if v == "AMD Zen 전체" else v + " 제외") if neg else v

def guest(path):
    rows = []
    for l in shell_block(path, "METRIC_TABLE"):
        m = re.match(r"^(.+?\|\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$", l.strip())
        if not m:
            raise SystemExit("cannot parse METRIC_TABLE line: " + l)
        name, calc, s1, s2, rest = m.groups()
        w = rest.split()
        cpu, named = "", False
        while w and (w[-1].startswith("cpu=") or w[-1].startswith("cpu!=") or w[-1] == "collect=named"):
            t = w.pop()
            if t == "collect=named":
                named = True
            else:
                cpu = t
        desc = " ".join(w)
        grp, _, nm = name.partition("|")
        rows.append([grp, nm, CALC.get(calc, calc), s1, "" if s2 == "-" else s2, cpu_label(cpu),
                     "이름 지정" if named else "기본", desc])
    return rows

GPU_SRC = {"q": "nvidia-smi --query-gpu", "d": "nvidia-smi dmon", "r": "nvidia-smi --query-remapped-rows", "x": "수집기 계산"}
GPU_AGG = {"avg": "구간 평균", "last": "마지막 값", "pct": "구간 중 해당 비율(%)"}

def gpu(path):
    rows = []
    for l in shell_block(path, "METRIC_TABLE"):
        f = l.split()
        p, _, field = f[2].partition(":")
        rows.append([f[0], GPU_AGG.get(f[1], f[1]), GPU_SRC.get(p, p), field])
    props = []
    for l in shell_block(path, "PROP_TABLE"):
        f = l.split()
        props.append([" ".join(f[:-1]), f[-1]])
    return rows, props

GEN_ORDER = ["sapphirerapids", "emeraldrapids", "graniterapids", "naples", "rome", "milan", "genoa", "turin"]
INTEL_LABEL = {"sapphirerapids": "Intel Xeon 4th Gen (Sapphire Rapids)",
               "emeraldrapids": "Intel Xeon 5th Gen (Emerald Rapids)",
               "graniterapids": "Intel Xeon 6 (Granite Rapids)"}

def host(dirpath):
    spec = importlib.util.spec_from_file_location("vk", os.path.join(dirpath, "vmkperf_ops_push.py"))
    vk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vk)
    cpu_map = json.load(open(os.path.join(dirpath, "events", "cpu_map.json")))
    gens = []
    for f in sorted(glob.glob(os.path.join(dirpath, "events", "*.json"))):
        b = os.path.basename(f)
        if b.startswith("metrics") or b == "cpu_map.json":
            continue
        ev = json.load(open(f))
        fixed = ev.get("fixed_cycles", True)
        vk.GP_COUNTERS = list(range(int(ev.get("gp_counters", 8))))
        planned = [e for e in ev["events"] if not (fixed and e["key"] == "cycles")]
        started = {e["key"] for e, c in vk.plan_counters(planned) if c is not None}
        if fixed:
            started.add("cycles")
        skipped = [e["key"] for e in ev["events"] if e["key"] not in started]
        mfile = ev.get("metrics_file", "metrics.json")
        mdefs = json.load(open(os.path.join(dirpath, "events", mfile)))["metrics"]
        def inputs(m):
            exprs = [m["src"]] if m["type"] == "sum" else [m["num"], m["den"]]
            return {k.strip() for x in exprs for k in x.split("+")}
        have = {e["key"] for e in ev["events"]}
        ok = [m["key"] for m in mdefs if inputs(m) <= started]
        no_counter = [m["key"] for m in mdefs if inputs(m) <= have and not inputs(m) <= started]
        no_event = [m["key"] for m in mdefs if not inputs(m) <= have]
        fm = sorted(k for k, v in cpu_map.items() if v == ev["cpu"] and not k.startswith("_"))
        gens.append(dict(cpu=ev["cpu"], label=ev.get("label") or INTEL_LABEL.get(ev["cpu"], ev["cpu"]), fm=fm, mfile=mfile,
                         gp=len(vk.GP_COUNTERS), fixed=fixed, events=len(ev["events"]),
                         skipped=skipped, ok=ok, no_counter=no_counter, no_event=no_event))
    gens.sort(key=lambda g: GEN_ORDER.index(g["cpu"]) if g["cpu"] in GEN_ORDER else 99)
    mdefs_all = {}
    for f in sorted(glob.glob(os.path.join(dirpath, "events", "metrics*.json"))):
        for m in json.load(open(f))["metrics"]:
            mdefs_all.setdefault(m["key"], (m, []))[1].append(os.path.basename(f))
    return vk, gens, mdefs_all

def build():
    g_path = os.path.join(ROOT, "ops_metric_push.sh")
    p_path = os.path.join(ROOT, "gpu_metric_push.sh")
    h_dir = os.path.join(ROOT, "vmkperf_ops_push")
    gv = version(g_path, r"^# ops_metric_push\.sh\s+v([\d.]+)")
    pv = version(p_path, r"^# gpu_metric_push\.sh\s+v([\d.]+)")
    vk, gens, mdefs = host(h_dir)
    L = []
    L.append("# 스크립트별 수집 지표\n")
    L.append("이 파일은 `tools/gen_metrics.py` 가 수집기 코드에서 만든다. 손으로 고치지 않는다. "
             "수집기의 지표 표를 바꾼 커밋에서 `python3 tools/gen_metrics.py` 를 실행해 함께 커밋한다.\n")
    L.append(table(["수집기", "판", "실행 위치", "Ops 지표 경로"], [
        ["ops_metric_push.sh", gv, "게스트 OS, BM 호스트(--target bm)", "VM 또는 BM 객체 > Custom Metrics > <그룹> > <지표>"],
        ["gpu_metric_push.sh", pv, "게스트 OS (GPU DirectPath I/O), BM 호스트(--target bm)", "VM 또는 BM 객체 > Custom Metrics > Guest GPU > gpu<N> > <지표>"],
        ["vmkperf_ops_push.py", vk.VERSION, "ESXi 호스트", "Host > Custom Metrics > Host Perf > <지표>"],
    ]) + "\n")

    rows = guest(g_path)
    L.append("## 1. 게스트 OS — ops_metric_push.sh v%s (%d개)\n" % (gv, len(rows)))
    L.append("- 출처: 스크립트의 `METRIC_TABLE`. `s1`, `s2` 는 계산에 쓰는 원본 값이다(perf 이벤트, /proc/meminfo, /proc/vmstat).")
    L.append("- 적용 CPU 가 맞지 않는 줄은 수집하지 않고 CSV 칸만 비워 둔다. 지원하지 않는 perf 이벤트를 쓰는 줄은 시작할 때 자동으로 빠진다.")
    L.append("- `--perf-fit` 을 쓰면 하드웨어 카운터 수에 맞을 때까지 표의 뒤쪽 perf 이벤트부터 뺀다.")
    L.append("- 수집 조건이 '기본' 인 줄은 `--collect` 없이 실행할 때 수집한다. '이름 지정' 인 줄(%d개)은 `--collect` 에 "
             "지표 이름을 적었을 때만 수집하고, `--collect both` 와 `--collect perf` 에는 포함되지 않는다." % sum(1 for r in rows if r[6] == "이름 지정"))
    L.append("- 적용 CPU 의 Intel 약칭: SKX 는 Skylake-SP, Cascade Lake-SP, Cooper Lake-SP(CPUID model 55h). ICX 는 Ice Lake-SP 와 "
             "Ice Lake-D(6Ah, 6Ch). SPR 은 Sapphire Rapids(8Fh). EMR 은 Emerald Rapids(CFh). GNR 은 Granite Rapids 와 Granite Rapids-D(ADh, AEh).\n")
    L.append(table(["그룹", "지표", "계산", "s1", "s2", "적용 CPU", "수집 조건", "설명"], rows) + "\n")

    grows, props = gpu(p_path)
    L.append("## 2. GPU — gpu_metric_push.sh v%s (지표 %d개, 구성 정보 %d개)\n" % (pv, len(grows), len(props)))
    L.append("- 출처: 스크립트의 `METRIC_TABLE`, `PROP_TABLE`. GPU 마다 `gpu0`, `gpu1` … 아래에 기록한다.")
    L.append("- 드라이버나 GPU 가 주지 않는 필드는 시작할 때 확인해 빠진다(`--check` 로 확인).\n")
    L.append(table(["지표", "1분 집계", "원본", "필드"], grows) + "\n")
    L.append("구성 정보 (Custom Configuration > Guest GPU > gpu<N>)\n")
    L.append(table(["항목", "nvidia-smi 필드"], props) + "\n")

    L.append("## 3. ESXi 호스트 — vmkperf_ops_push.py v%s\n" % vk.VERSION)
    L.append("- 출처: `events/<세대>.json`(이벤트), `events/metrics*.json`(지표 계산), `vmkperf_ops_push.py` 의 `plan_counters()`(카운터 배치).")
    L.append("- 수집 여부는 이 스크립트가 수집기의 배치 함수로 계산한 값이다. 실제 호스트에서는 `check` 와 시작 로그의 `SKIPPED` 줄로 확인한다.")
    L.append("- Intel 은 ESXi 고정 카운터로 cycles 를 센다고 가정했다(기본 동작). AMD 는 고정 카운터가 없어 cycles 도 일반 카운터 하나를 쓴다.")
    L.append("- 선택 수집: `--qos` 를 켜면 rmID 별 LLC 점유량(`LLC_Occ_*_MB`)을 함께 보낸다.\n")
    L.append(table(["세대", "CPUID family-model", "일반 카운터", "이벤트", "수집 지표", "카운터 부족으로 빠지는 지표", "이벤트 없음"], [
        ["%s (%s)" % (g["cpu"], g["label"].split(":")[0]) if ":" in g["label"] else "%s (%s)" % (g["cpu"], g["label"]), ", ".join(g["fm"]),
         "%d%s" % (g["gp"], "" if not g["fixed"] else " + 고정(cycles)"),
         "%d (시작 못 함: %s)" % (g["events"], ", ".join(g["skipped"]) or "없음"),
         len(g["ok"]), ", ".join(g["no_counter"]) or "-", ", ".join(g["no_event"]) or "-"] for g in gens]) + "\n")
    L.append("세대별 대상 CPU\n")
    L.append("\n".join("- `%s`: %s" % (g["cpu"], g["label"]) for g in gens) + "\n")
    L.append("지표 정의\n")
    hrows = []
    for k, (m, files) in mdefs.items():
        calc = m["src"] if m["type"] == "sum" else "%s%s / %s" % (
            ("%s × " % m["scale"]) if m.get("scale") else ("100 × " if m["type"] == "pct" else ""), m["num"], m["den"])
        hrows.append([k, m["type"], calc, ", ".join(files), m.get("desc", "")])
    L.append(table(["지표", "형식", "계산 (이벤트 키)", "정의 파일", "설명"], hrows) + "\n")
    return "\n".join(L)

if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        same = os.path.exists(OUT) and open(OUT, encoding="utf-8").read() == text
        print("METRICS.md up to date" if same else "METRICS.md differs from code: run python3 tools/gen_metrics.py")
        sys.exit(0 if same else 1)
    open(OUT, "w", encoding="utf-8").write(text)
    print("wrote", OUT)

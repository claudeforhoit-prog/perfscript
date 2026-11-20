# -*- coding: utf-8 -*-
"""
cpu_affinity 폴더의 PowerShell 스크립트 2개의 계산부를 Python 으로 옮긴 모델과 점검.

    python3 cpu_affinity_model.py            # 점검 실행 (끝에 RESULT 줄)

  m310   : SetVcpuAffinityProfile_v3_12.ps1 의 계산부 (v3.10 에서 정한 계산. v3.11, v3.12 는 첫머리 설명만 다르다)
  mvdp11 : VmDeployPlan_v1_1.ps1 의 계산부 (Get-VmPlanAffinity 와 표의 행)
  m39, mvdp, m37 : 이전 판(v3.9, VmDeployPlan v1.0, v3.7)의 계산부. 판 사이의 차이를 볼 때 쓴다

PowerShell 이 없는 장비에서 값을 확인하려고 둔다. 스크립트 자체를 실행하는 시험이 아니므로, 스크립트를 고치면 이 모델도
같이 고치고, PowerShell 이 있는 PC 에서 Test-VmDeployPlan 을 실행해 확인한다.
아래 주석의 Lnnn 은 v3.9, v1.0 파일의 줄 번호다.
"""
import math
import os
import re
import sys


PROFILE_SPEC = {  # v3.9 L254-260 == VDP L100-106 (Sheet 필드 제외 동일)
    "rev12":   dict(PvmRule="core-all",   SvmScope="node", SvmThreads="all",     SvmOrder="desc", Reserve=4),
    "rev11":   dict(PvmRule="core-all",   SvmScope="node", SvmThreads="sibling", SvmOrder="desc", Reserve=4),
    "rnd_aff": dict(PvmRule="core-first", SvmScope="host", SvmThreads="sibling", SvmOrder="asc",  Reserve=0),
    "vm4d":    dict(PvmRule="none",       SvmScope="none", SvmThreads="all",     SvmOrder="asc",  Reserve=0),
    "clear":   dict(PvmRule="none",       SvmScope="none", SvmThreads="all",     SvmOrder="asc",  Reserve=0),
}

def ceil_div(a, b):
    return int(math.ceil(a / b))

def core_threads_asc(core, tpc):                       # v3.9 L495-500 / VDP L131-136
    return [core * tpc + t for t in range(tpc)]

def cores_to_pcpu(cores, mode, order, tpc):            # v3.9 L502-516 / VDP L137-150
    t0 = 1 if mode == "sibling" else 0
    out = []
    if order == "desc":
        for t in range(tpc - 1, t0 - 1, -1):
            for c in sorted(cores, reverse=True):
                out.append(c * tpc + t)
    else:
        for c in sorted(cores):
            for t in range(t0, tpc):
                out.append(c * tpc + t)
    return out


class Err(Exception):
    pass


# ---------------------------------------------------------------------------
# 공통: 호스트 토폴로지 (적용 스크립트 = 호스트 판독, VDP = 입력값). 같은 입력이면 같은 값.
# ---------------------------------------------------------------------------
def host_topo(sockets, cps, ht, snc):
    tpc = 2 if ht else 1                                # 적용: L329 TotalThreads/TotalCores, VDP L322
    total = sockets * cps
    nps = snc
    nnodes = sockets * nps                              # 적용: L349 (또는 NumaInfo 노드 수), VDP L327
    cpn = cps // nps                                    # 적용: L348, VDP L328
    nodesets = [list(range(n * cpn, (n + 1) * cpn)) for n in range(nnodes)]  # 적용 L350-352 / NumaInfo 정렬, VDP L330
    return dict(S=sockets, CPS=cps, TPC=tpc, HT=ht, TOTAL=total, NPS=nps, NN=nnodes, CPN=cpn, NODES=nodesets)


def reserve_per_node(spec, nps, esxi_reserve):          # 적용 L398-406 / VDP L331-333
    rps = esxi_reserve if esxi_reserve >= 0 else spec["Reserve"]
    if rps % nps != 0:
        raise Err("reserve-not-divisible")
    return rps // nps


def svm_plan(spec, prof, T, rpn, svm, settings, extras, notes):
    """SVM 배치. v3.9 L620-706 == v3.7 L540-623 == VDP L190-237 (계산 동일)"""
    if svm is None or spec["SvmScope"] == "none":
        return
    n = svm["NumCpu"]
    if spec["SvmScope"] == "host":                       # L623
        pc = cores_to_pcpu(list(range(T["TOTAL"])), spec["SvmThreads"], spec["SvmOrder"], T["TPC"])
        if pc:
            v = ",".join(map(str, pc))
            for i in range(n):
                settings[(svm["Name"], f"sched.vcpu{i}.affinity")] = v
        else:
            if n % T["NN"] != 0:                         # L642 / VDP L201
                raise Err("svm-topo-not-divisible")
            c = n // T["NN"]
            for k, val in (("cpuid.coresPerSocket", c), ("numa.vcpu.coresPerNode", c),
                           ("numa.autosize.vcpu.maxPerVirtualNode", c), ("numa.autosize.cookie", 0)):
                extras[(svm["Name"], k)] = str(val)
        return
    mode = spec["SvmThreads"]                            # L666-670 / VDP L212-216
    if mode == "sibling" and not T["HT"]:
        mode = "all"
        notes.append("svm-ht-off-all")
    usable = []
    for nd in range(T["NN"]):                            # L672-680 / VDP L217-225
        cores = T["NODES"][nd]
        if len(cores) <= rpn:
            raise Err("node-le-reserve")
        usable.append(cores[rpn:])
    vpn = ceil_div(n, T["NN"])                           # L682-683 / VDP L226-227
    if vpn < 1:
        vpn = 1
    for v in range(n):                                   # L690-704 / VDP L228-235
        tn = (T["NN"] - 1) - (v // vpn)
        if tn < 0:
            tn = 0
        pc = cores_to_pcpu(usable[tn], mode, spec["SvmOrder"], T["TPC"])
        if not pc:
            raise Err("node-empty")
        settings[(svm["Name"], f"sched.vcpu{v}.affinity")] = ",".join(map(str, pc))


def pin_pvms(spec, T, targets, settings):
    """PVM 핀 값. v3.9 L590-615 == v3.7 L510-535 == VDP L176-187"""
    if spec["PvmRule"] == "none":
        return
    for P in targets:
        n = P["VM"]["NumCpu"]
        if n > P["Cap"]:
            raise Err("vcpu-gt-cap")
        for i in range(n):
            core = P["CoreBase"] + i
            if spec["PvmRule"] == "core-all":
                val = ",".join(map(str, core_threads_asc(core, T["TPC"])))
            else:
                val = str(core * T["TPC"])
            settings[(P["VM"]["Name"], f"sched.vcpu{i}.affinity")] = val


# ---------------------------------------------------------------------------
# m39 : SetVcpuAffinityProfile v3.9
#   pvms = [dict(Name, NumCpu, Cps)]  (Cps = VM 의 NumCoresPerSocket, 0 = 미판독)
# ---------------------------------------------------------------------------
def m39(profile, sockets, cps, ht, snc, pvms, svm=None, esxi_reserve=-1):
    spec = PROFILE_SPEC[profile]
    T = host_topo(sockets, cps, ht, snc)
    settings, extras, notes = {}, {}, []
    try:
        rpn = reserve_per_node(spec, T["NPS"], esxi_reserve)            # L398-406
        npvm = len(pvms)                                                # L431
        multi = npvm >= 2                                               # L432
        if multi and profile == "rnd_aff":                              # L446-449
            raise Err("rnd_aff-multi")
        cpn_rule = T["TOTAL"] // T["NN"]                                # L470

        def get_vs(vm, role):                                           # L471-489
            if role == "SVM":
                auto = 1
                if profile == "vm4d":
                    auto = T["NN"]
                if spec["SvmScope"] == "host" and not T["HT"]:
                    auto = T["NN"]
            else:
                auto = int(min(math.ceil(vm["NumCpu"] / cpn_rule), T["NN"]))
                if auto < 1:
                    auto = 1
            c = vm.get("Cps", 0) or 0
            vs = auto
            if c > 0:
                vs = ceil_div(vm["NumCpu"], c)
            if vs < 1:
                vs = 1
            return dict(VS=vs, Auto=auto, Cps=c)

        targets = []                                                    # L527
        two_split = (npvm == 2 and T["S"] >= 2)                         # L528
        if npvm == 1:                                                   # L529-531
            targets.append(dict(VM=pvms[0], CoreBase=0, Cap=T["TOTAL"], Tag="PVM", Socket=-1, Index=0, VsInfo=get_vs(pvms[0], "PVM")))
        elif two_split:                                                 # L532-542
            for k in range(2):
                need = pvms[k]["NumCpu"]
                if spec["PvmRule"] != "none" and need > T["CPS"]:
                    raise Err("two-vm-socket-overflow")
                targets.append(dict(VM=pvms[k], CoreBase=k * T["CPS"], Cap=T["CPS"], Tag=f"PVM{k+1}(소켓{k})", Socket=k, Index=k, VsInfo=get_vs(pvms[k], "PVM")))
        elif npvm >= 2:                                                 # L543-554
            cur = 0
            for k in range(npvm):
                need = pvms[k]["NumCpu"]
                if spec["PvmRule"] != "none" and cur + need > T["TOTAL"]:
                    raise Err("multi-total-overflow")
                targets.append(dict(VM=pvms[k], CoreBase=cur, Cap=need, Tag=f"PVM{k+1}", Socket=cur // T["CPS"], Index=k, VsInfo=get_vs(pvms[k], "PVM")))
                cur += need
        if npvm >= 3 and spec["PvmRule"] != "none":                     # L578-588
            for P in targets:
                a = P["CoreBase"]; b = a + P["VM"]["NumCpu"] - 1
                if (a // cpn_rule) != (b // cpn_rule) and P["VsInfo"]["VS"] == 1:
                    notes.append(f"boundary:{P['VM']['Name']}:{a}-{b}")
        pin_pvms(spec, T, targets, settings)                            # L590-615
        svm_plan(spec, profile, T, rpn, svm, settings, extras, notes)   # L620-706
        if profile == "vm4d":                                           # L712-760
            for P in targets:
                vs = P["VsInfo"]["VS"]
                start = 0
                if two_split:
                    start = P["Socket"] * T["NPS"]
                elif npvm >= 2:
                    start = (P["Index"] * vs) % T["NN"]
                for j in range(vs):
                    settings[(P["VM"]["Name"], f"sched.node{j}.affinity")] = str((start + j) % T["NN"])
            if svm is not None:                                         # L729-737: SVM = 전 호스트 노드, VM 판독값 무관
                sv = get_vs(svm, "SVM")
                if sv["Cps"] > 0 and sv["VS"] != T["NN"]:
                    notes.append(f"svm-vs-mismatch:{sv['VS']}")
                for j in range(T["NN"]):
                    settings[(svm["Name"], f"sched.node{j}.affinity")] = str(j)
    except Err as e:
        return dict(error=str(e), settings={}, extras={}, notes=notes)
    return dict(error="", settings=settings, extras=extras, notes=notes)


# ---------------------------------------------------------------------------
# m37 : SetVcpuAffinityProfile v3.7 (변경 전)
# ---------------------------------------------------------------------------
def m37(profile, sockets, cps, ht, snc, pvms, svm=None, esxi_reserve=-1):
    spec = PROFILE_SPEC[profile]
    T = host_topo(sockets, cps, ht, snc)
    settings, extras, notes = {}, {}, []
    try:
        rpn = reserve_per_node(spec, T["NPS"], esxi_reserve)
        npvm = len(pvms)
        if npvm >= 2 and profile == "rnd_aff":
            raise Err("rnd_aff-multi")
        targets = []
        if npvm == 1:                                                   # v3.7 L472-474
            targets.append(dict(VM=pvms[0], CoreBase=0, Cap=T["TOTAL"], Socket=-1))
        elif npvm >= 2:                                                 # v3.7 L475-491
            cursor = [0] * T["S"]
            for k in range(npvm):
                s = k % T["S"]
                need = pvms[k]["NumCpu"]
                if spec["PvmRule"] != "none" and cursor[s] + need > T["CPS"]:
                    raise Err("socket-overflow")
                targets.append(dict(VM=pvms[k], CoreBase=s * T["CPS"] + cursor[s], Cap=need, Socket=s))
                cursor[s] += need
        pin_pvms(spec, T, targets, settings)
        svm_plan(spec, profile, T, rpn, svm, settings, extras, notes)
        if profile == "vm4d":                                           # v3.7 L629-651
            for P in targets:
                if P["Socket"] >= 0:
                    nodes = list(range(P["Socket"] * T["NPS"], (P["Socket"] + 1) * T["NPS"]))
                else:
                    nodes = list(range(T["NN"]))
                for j, hn in enumerate(nodes):
                    settings[(P["VM"]["Name"], f"sched.node{j}.affinity")] = str(hn)
            if svm is not None:
                for j in range(T["NN"]):
                    settings[(svm["Name"], f"sched.node{j}.affinity")] = str(j)
    except Err as e:
        return dict(error=str(e), settings={}, extras={}, notes=notes)
    return dict(error="", settings=settings, extras=extras, notes=notes)


# ---------------------------------------------------------------------------
# mvdp : VmDeployPlan v1.0  (New-VmDeployPlan L270-470 의 계산부 + Get-VmPlanAffinity L111-266)
# ---------------------------------------------------------------------------
def mvdp(profile, sockets, cps, ht, snc, pvm_vcpu, pvm_count=0, svm_vcpu=0, esxi_reserve=-1,
         pvm_vs=0, svm_vs=0, share="10000:1", lpage="on", vpmc="off", pvm_mem=(), svm_mem=0, prefix=""):
    spec = PROFILE_SPEC[profile]
    pvm_vcpu = list(pvm_vcpu)
    npvm = pvm_count if pvm_count > 0 else len(pvm_vcpu)               # L308
    if npvm >= 2 and profile == "rnd_aff":                             # L316
        return dict(error="rnd_aff-multi")
    if cps % snc != 0:                                                 # L305
        return dict(error="snc-not-divisible")
    vlist = [pvm_vcpu[0] if len(pvm_vcpu) == 1 else pvm_vcpu[k] for k in range(npvm)]   # L317-321
    mlist = [0 if len(pvm_mem) == 0 else (pvm_mem[0] if len(pvm_mem) == 1 else pvm_mem[k]) for k in range(npvm)]
    T = host_topo(sockets, cps, ht, snc)                               # L324-333
    try:
        rpn = reserve_per_node(spec, T["NPS"], esxi_reserve)
    except Err as e:
        return dict(error=str(e))
    pri = []
    for k in range(npvm):                                              # L339-345
        nm = prefix + "ev%02d" % (k + 1)
        vsauto = int(min(math.ceil(vlist[k] / T["CPN"]), T["NN"]))
        if vsauto < 1:
            vsauto = 1
        vs = pvm_vs if pvm_vs > 0 else vsauto
        pri.append(dict(Name=nm, NumCpu=vlist[k], Index=k, MemGB=mlist[k], VS=vs))
    sec = None
    if svm_vcpu > 0:                                                   # L346-351
        nm = prefix + "ev%02d" % (npvm + 1)
        vsa = T["NN"] if (profile == "vm4d" or (spec["SvmScope"] == "host" and not T["HT"])) else 1
        vs = svm_vs if (svm_vs > 0 and profile != "vm4d") else vsa      # vm4d 의 SVM 은 -SvmVSockets 를 무시 (L362)
        sec = dict(Name=nm, NumCpu=svm_vcpu, Index=0, MemGB=svm_mem, VS=vs)
    multi = npvm >= 2
    if npvm == 1:                                                      # L354-358
        sk = "Dual" if sec else "PvmOnly"
    elif npvm == 2:
        sk = "TwoDual" if sec else "Two"
    elif npvm >= 3:
        sk = "MultiDual" if sec else "Multi"
    else:
        sk = "SvmOnly"
    SN = dict(PvmOnly="PVM 단독", Dual="Dual VM", Two="Two VM", TwoDual="Two Dual VM", Multi="Multi VM", MultiDual="Multi Dual VM", SvmOnly="SVM 단독")
    topo = SN[sk] + (f" (PVM {npvm} 대)" if npvm >= 3 else "")

    # ---- Get-VmPlanAffinity ----
    settings, extras, notes = {}, {}, []
    targets = []
    two_split = (npvm == 2 and T["S"] >= 2)                            # L155
    try:
        if npvm == 1:                                                  # L156-158
            targets.append(dict(VM=pri[0], CoreBase=0, Cap=T["TOTAL"], Tag="PVM", Socket=-1, Index=0))
        elif two_split:                                                # L159-168
            for k in range(2):
                s = k % T["S"]
                need = pri[k]["NumCpu"]
                if spec["PvmRule"] != "none" and need > T["CPS"]:
                    raise Err("two-vm-socket-overflow")
                targets.append(dict(VM=pri[k], CoreBase=s * T["CPS"], Cap=T["CPS"], Tag=f"PVM{k+1}(소켓{s})", Socket=s, Index=k))
        elif npvm >= 2:                                                # L169-180
            cur = 0
            for k in range(npvm):
                need = pri[k]["NumCpu"]
                if spec["PvmRule"] != "none" and cur + need > T["TOTAL"]:
                    raise Err("multi-total-overflow")
                targets.append(dict(VM=pri[k], CoreBase=cur, Cap=need, Tag=f"PVM{k+1}", Socket=cur // T["CPS"], Index=k))
                cur += need
        pin_pvms(spec, T, targets, settings)                           # L182-191
        svm_plan(spec, profile, T, rpn, sec, settings, extras, notes)  # L194-238
        if profile == "vm4d":                                          # L241-264
            for P in targets:
                vs = P["VM"]["VS"]
                if vs < 1:
                    vs = 1
                start = 0
                if two_split:
                    start = P["Socket"] * T["NPS"]
                elif npvm >= 2:
                    start = (P["Index"] * vs) % T["NN"]
                for j in range(vs):
                    settings[(P["VM"]["Name"], f"sched.node{j}.affinity")] = str((start + j) % T["NN"])
            if sec:
                vs = sec["VS"] if sec["VS"] >= 1 else 1
                for j in range(vs):
                    settings[(sec["Name"], f"sched.node{j}.affinity")] = str(j % T["NN"])
    except Err as e:
        return dict(error=str(e))
    if npvm >= 3 and spec["PvmRule"] != "none":                        # L366-374
        for P in targets:
            a = P["CoreBase"]; b = a + P["VM"]["NumCpu"] - 1
            if (a // T["CPN"]) != (b // T["CPN"]) and P["VM"]["VS"] == 1:
                notes.append(f"boundary:{P['VM']['Name']}:{a}-{b}")

    # ---- 세로 표 행 (L376-460) ----
    vms = [dict(v, Role="PVM") for v in pri] + ([dict(sec, Role="SVM")] if sec else [])
    rows = {}
    def put(item, name, val):
        rows[(name, item)] = str(val)
    ht_text = "on" if T["HT"] else "off"
    snc_text = f"SNC-{T['NPS']} ({T['NPS']} nodes/socket)" if T["NPS"] > 1 else "disabled (1 node/socket)"
    m = re_ratio(share)
    if m == "normal":
        sp = ss = "normal"
    else:
        sp, ss = f"{m[0]} (custom)", f"{m[1]} (custom)"
    lpk = ["sched.mem.lpage.enable1GPage", "sched.mem.pin", "sched.mem.prealloc", "sched.mem.prealloc.pinnedMainMem", "sched.swap.vmxSwapEnabled"]
    lpv = ["TRUE", "TRUE", "TRUE", "TRUE", "FALSE"] if lpage == "on" else ["(없음)"] * 5
    for v in vms:
        n = v["Name"]; vs = v["VS"]; c = ceil_div(v["NumCpu"], vs)
        put("sockets x cores per socket", n, f"{T['S']} x {T['CPS']}")
        put("Hyperthreading", n, ht_text)
        put("SNC", n, snc_text)
        put("pCPU count", n, T["TOTAL"] * T["TPC"])
        put("structure / profile", n, f"{topo} / {profile}")
        put("role", n, v["Role"])
        put("cpu", n, v["NumCpu"])
        put("cores per socket / sockets", n, f"{c} / {vs}" + ("" if v["NumCpu"] % vs == 0 else " (vCPU 가 소켓 수로 안 나뉨)"))
        put("vNUMA nodes", n, vs)
        put("memory (GB)", n, v["MemGB"] if v["MemGB"] > 0 else "-")
        put("memory reservation", n, f"{v['MemGB']} (locked)" if v["MemGB"] > 0 else "-")
        put("cpu shares", n, sp if v["Role"] == "PVM" else ss)
        put("mem shares", n, sp if v["Role"] == "PVM" else ss)
        put("physical placement", n, placement(v, spec, profile, multi, targets, T, rpn))
        for k, val in zip(lpk, lpv):
            put(k, n, val)
        put("numa.vcpu.maxPerVirtualNode", n, c)
        put("vpmc.enable", n, "TRUE" if vpmc == "on" else "(없음)")
        put("numa.nodeAffinity", n, "(없음)")
    allp = dict(settings); allp.update(extras)
    keys = set(k for (_, k) in allp)
    for key in keys:
        for v in vms:
            rows[(v["Name"], key)] = allp.get((v["Name"], key), "")
    return dict(error="", settings=settings, extras=extras, notes=notes, rows=rows, vms=vms, topo=topo, sk=sk)


def re_ratio(share):
    import re
    mm = re.match(r'^\s*(\d+)\s*:\s*(\d+)\s*$', share)
    if mm:
        return (mm.group(1), mm.group(2))
    if re.match(r'^\s*normal\s*$', share, re.I):
        return "normal"
    raise ValueError(share)


def placement(v, spec, profile, multi, targets, T, rpn):           # VDP L382-411
    if v["Role"] == "SVM":
        if spec["SvmScope"] == "node":
            return f"float on {T['NN']} NUMA nodes (reserved {rpn} cores/node excluded)"
        if spec["SvmScope"] == "host":
            return "float on all cores"
        return "node affinity" if profile == "vm4d" else "free float"
    n = v["NumCpu"]
    tg = [t for t in targets if t["VM"]["Name"] == v["Name"]]
    if spec["PvmRule"] == "none":
        return "node affinity" if profile == "vm4d" else "free float"
    if multi and tg:
        a = tg[0]["CoreBase"]; b = a + n - 1
        sa, sb = a // T["CPS"], b // T["CPS"]
        st = f"socket {sa}" if sa == sb else f"sockets {sa}-{sb}"
        return f"cores {a}-{b} pinned ({st})"
    span = ceil_div(n, T["CPS"])
    return f"host cores 0-{n-1} pinned ({span} sockets, {v['VS']} NUMA nodes)"


# ---------------------------------------------------------------------------
# v3.10, VmDeployPlan v1.1 : SVM 배치가 SVM 의 가상 소켓 수를 반영한다 (그 밖의 계산은 위와 같다)
# ---------------------------------------------------------------------------
def svm_plan310(spec, prof, T, rpn, svm, settings, extras, notes, vsinfo):
    """SVM 배치. v3.10 의 5절, VDP v1.1 의 Get-VmPlanAffinity. vsinfo = dict(VS, Cps) (Cps 0 = 미판독)."""
    if svm is None or spec["SvmScope"] == "none":
        return
    n = svm["NumCpu"]
    if spec["SvmScope"] == "host":                       # 변경 없음
        pc = cores_to_pcpu(list(range(T["TOTAL"])), spec["SvmThreads"], spec["SvmOrder"], T["TPC"])
        if pc:
            v = ",".join(map(str, pc))
            for i in range(n):
                settings[(svm["Name"], f"sched.vcpu{i}.affinity")] = v
        else:
            if n % T["NN"] != 0:
                raise Err("svm-topo-not-divisible")
            c = n // T["NN"]
            for k, val in (("cpuid.coresPerSocket", c), ("numa.vcpu.coresPerNode", c),
                           ("numa.autosize.vcpu.maxPerVirtualNode", c), ("numa.autosize.cookie", 0)):
                extras[(svm["Name"], k)] = str(val)
        return
    mode = spec["SvmThreads"]
    if mode == "sibling" and not T["HT"]:
        mode = "all"
        notes.append("svm-ht-off-all")
    usable = []
    for nd in range(T["NN"]):
        cores = T["NODES"][nd]
        if len(cores) <= rpn:
            raise Err("node-le-reserve")
        usable.append(cores[rpn:])
    NN = T["NN"]
    vs = int(vsinfo["VS"])
    if vs < NN:                                          # v3.10: 가상 소켓 수 < 호스트 노드 수
        cps = int(vsinfo.get("Cps", 0) or 0)
        gsize = cps if cps > 0 else ceil_div(n, vs)
        if gsize < 1:
            gsize = 1
        gvals = []
        for g in range(vs):
            hi = NN - (g * NN) // vs
            lo = NN - ((g + 1) * NN) // vs
            merged = []
            for nd in range(hi - 1, lo - 1, -1):
                merged += cores_to_pcpu(usable[nd], mode, spec["SvmOrder"], T["TPC"])
            if not merged:
                raise Err("group-empty")
            gvals.append(",".join(map(str, merged)))
        for v in range(n):
            g = v // gsize
            if g > vs - 1:
                g = vs - 1
            settings[(svm["Name"], f"sched.vcpu{v}.affinity")] = gvals[g]
        notes.append(f"svm-merged:vs{vs}")
        return
    vpn = ceil_div(n, NN)                                # 변경 없음 (가상 소켓 수 >= 호스트 노드 수)
    if vpn < 1:
        vpn = 1
    for v in range(n):
        tn = (NN - 1) - (v // vpn)
        if tn < 0:
            tn = 0
        pc = cores_to_pcpu(usable[tn], mode, spec["SvmOrder"], T["TPC"])
        if not pc:
            raise Err("node-empty")
        settings[(svm["Name"], f"sched.vcpu{v}.affinity")] = ",".join(map(str, pc))


def m310(profile, sockets, cps, ht, snc, pvms, svm=None, esxi_reserve=-1):
    spec = PROFILE_SPEC[profile]
    T = host_topo(sockets, cps, ht, snc)
    settings, extras, notes = {}, {}, []
    try:
        rpn = reserve_per_node(spec, T["NPS"], esxi_reserve)            # L398-406
        npvm = len(pvms)                                                # L431
        multi = npvm >= 2                                               # L432
        if multi and profile == "rnd_aff":                              # L446-449
            raise Err("rnd_aff-multi")
        cpn_rule = T["TOTAL"] // T["NN"]                                # L470

        def get_vs(vm, role):                                           # L471-489
            if role == "SVM":
                auto = 1
                if profile == "vm4d":
                    auto = T["NN"]
                if spec["SvmScope"] == "host" and not T["HT"]:
                    auto = T["NN"]
            else:
                auto = int(min(math.ceil(vm["NumCpu"] / cpn_rule), T["NN"]))
                if auto < 1:
                    auto = 1
            c = vm.get("Cps", 0) or 0
            vs = auto
            if c > 0:
                vs = ceil_div(vm["NumCpu"], c)
            if vs < 1:
                vs = 1
            return dict(VS=vs, Auto=auto, Cps=c)

        targets = []                                                    # L527
        two_split = (npvm == 2 and T["S"] >= 2)                         # L528
        if npvm == 1:                                                   # L529-531
            targets.append(dict(VM=pvms[0], CoreBase=0, Cap=T["TOTAL"], Tag="PVM", Socket=-1, Index=0, VsInfo=get_vs(pvms[0], "PVM")))
        elif two_split:                                                 # L532-542
            for k in range(2):
                need = pvms[k]["NumCpu"]
                if spec["PvmRule"] != "none" and need > T["CPS"]:
                    raise Err("two-vm-socket-overflow")
                targets.append(dict(VM=pvms[k], CoreBase=k * T["CPS"], Cap=T["CPS"], Tag=f"PVM{k+1}(소켓{k})", Socket=k, Index=k, VsInfo=get_vs(pvms[k], "PVM")))
        elif npvm >= 2:                                                 # L543-554
            cur = 0
            for k in range(npvm):
                need = pvms[k]["NumCpu"]
                if spec["PvmRule"] != "none" and cur + need > T["TOTAL"]:
                    raise Err("multi-total-overflow")
                targets.append(dict(VM=pvms[k], CoreBase=cur, Cap=need, Tag=f"PVM{k+1}", Socket=cur // T["CPS"], Index=k, VsInfo=get_vs(pvms[k], "PVM")))
                cur += need
        if npvm >= 3 and spec["PvmRule"] != "none":                     # L578-588
            for P in targets:
                a = P["CoreBase"]; b = a + P["VM"]["NumCpu"] - 1
                if (a // cpn_rule) != (b // cpn_rule) and P["VsInfo"]["VS"] == 1:
                    notes.append(f"boundary:{P['VM']['Name']}:{a}-{b}")
        pin_pvms(spec, T, targets, settings)                            # L590-615
        svm_plan310(spec, profile, T, rpn, svm, settings, extras, notes, get_vs(svm, "SVM") if svm is not None else None)
        if profile == "vm4d":                                           # L712-760
            for P in targets:
                vs = P["VsInfo"]["VS"]
                start = 0
                if two_split:
                    start = P["Socket"] * T["NPS"]
                elif npvm >= 2:
                    start = (P["Index"] * vs) % T["NN"]
                for j in range(vs):
                    settings[(P["VM"]["Name"], f"sched.node{j}.affinity")] = str((start + j) % T["NN"])
            if svm is not None:                                         # L729-737: SVM = 전 호스트 노드, VM 판독값 무관
                sv = get_vs(svm, "SVM")
                if sv["Cps"] > 0 and sv["VS"] != T["NN"]:
                    notes.append(f"svm-vs-mismatch:{sv['VS']}")
                for j in range(T["NN"]):
                    settings[(svm["Name"], f"sched.node{j}.affinity")] = str(j)
    except Err as e:
        return dict(error=str(e), settings={}, extras={}, notes=notes)
    return dict(error="", settings=settings, extras=extras, notes=notes)




def mvdp11(profile, sockets, cps, ht, snc, pvm_vcpu, pvm_count=0, svm_vcpu=0, esxi_reserve=-1,
         pvm_vs=0, svm_vs=0, share="10000:1", lpage="on", vpmc="off", pvm_mem=(), svm_mem=0, prefix=""):
    spec = PROFILE_SPEC[profile]
    pvm_vcpu = list(pvm_vcpu)
    npvm = pvm_count if pvm_count > 0 else len(pvm_vcpu)               # L308
    if npvm >= 2 and profile == "rnd_aff":                             # L316
        return dict(error="rnd_aff-multi")
    if cps % snc != 0:                                                 # L305
        return dict(error="snc-not-divisible")
    vlist = [pvm_vcpu[0] if len(pvm_vcpu) == 1 else pvm_vcpu[k] for k in range(npvm)]   # L317-321
    mlist = [0 if len(pvm_mem) == 0 else (pvm_mem[0] if len(pvm_mem) == 1 else pvm_mem[k]) for k in range(npvm)]
    T = host_topo(sockets, cps, ht, snc)                               # L324-333
    try:
        rpn = reserve_per_node(spec, T["NPS"], esxi_reserve)
    except Err as e:
        return dict(error=str(e))
    pri = []
    for k in range(npvm):                                              # L339-345
        nm = prefix + "ev%02d" % (k + 1)
        vsauto = int(min(math.ceil(vlist[k] / T["CPN"]), T["NN"]))
        if vsauto < 1:
            vsauto = 1
        vs = pvm_vs if pvm_vs > 0 else vsauto
        pri.append(dict(Name=nm, NumCpu=vlist[k], Index=k, MemGB=mlist[k], VS=vs))
    sec = None
    if svm_vcpu > 0:                                                   # L346-351
        nm = prefix + "ev%02d" % (npvm + 1)
        vsa = T["NN"] if (profile == "vm4d" or (spec["SvmScope"] == "host" and not T["HT"])) else 1
        vs = svm_vs if (svm_vs > 0 and profile != "vm4d") else vsa      # vm4d 의 SVM 은 -SvmVSockets 를 무시 (L362)
        sec = dict(Name=nm, NumCpu=svm_vcpu, Index=0, MemGB=svm_mem, VS=vs)
    multi = npvm >= 2
    if npvm == 1:                                                      # L354-358
        sk = "Dual" if sec else "PvmOnly"
    elif npvm == 2:
        sk = "TwoDual" if sec else "Two"
    elif npvm >= 3:
        sk = "MultiDual" if sec else "Multi"
    else:
        sk = "SvmOnly"
    SN = dict(PvmOnly="PVM 단독", Dual="Dual VM", Two="Two VM", TwoDual="Two Dual VM", Multi="Multi VM", MultiDual="Multi Dual VM", SvmOnly="SVM 단독")
    topo = SN[sk] + (f" (PVM {npvm} 대)" if npvm >= 3 else "")

    # ---- Get-VmPlanAffinity ----
    settings, extras, notes = {}, {}, []
    targets = []
    two_split = (npvm == 2 and T["S"] >= 2)                            # L155
    try:
        if npvm == 1:                                                  # L156-158
            targets.append(dict(VM=pri[0], CoreBase=0, Cap=T["TOTAL"], Tag="PVM", Socket=-1, Index=0))
        elif two_split:                                                # L159-168
            for k in range(2):
                s = k % T["S"]
                need = pri[k]["NumCpu"]
                if spec["PvmRule"] != "none" and need > T["CPS"]:
                    raise Err("two-vm-socket-overflow")
                targets.append(dict(VM=pri[k], CoreBase=s * T["CPS"], Cap=T["CPS"], Tag=f"PVM{k+1}(소켓{s})", Socket=s, Index=k))
        elif npvm >= 2:                                                # L169-180
            cur = 0
            for k in range(npvm):
                need = pri[k]["NumCpu"]
                if spec["PvmRule"] != "none" and cur + need > T["TOTAL"]:
                    raise Err("multi-total-overflow")
                targets.append(dict(VM=pri[k], CoreBase=cur, Cap=need, Tag=f"PVM{k+1}", Socket=cur // T["CPS"], Index=k))
                cur += need
        pin_pvms(spec, T, targets, settings)                           # L182-191
        svm_plan310(spec, profile, T, rpn, sec, settings, extras, notes,
                    dict(VS=sec["VS"], Cps=ceil_div(sec["NumCpu"], sec["VS"])) if sec else None)
        if profile == "vm4d":                                          # L241-264
            for P in targets:
                vs = P["VM"]["VS"]
                if vs < 1:
                    vs = 1
                start = 0
                if two_split:
                    start = P["Socket"] * T["NPS"]
                elif npvm >= 2:
                    start = (P["Index"] * vs) % T["NN"]
                for j in range(vs):
                    settings[(P["VM"]["Name"], f"sched.node{j}.affinity")] = str((start + j) % T["NN"])
            if sec:
                vs = sec["VS"] if sec["VS"] >= 1 else 1
                for j in range(vs):
                    settings[(sec["Name"], f"sched.node{j}.affinity")] = str(j % T["NN"])
    except Err as e:
        return dict(error=str(e))
    if npvm >= 3 and spec["PvmRule"] != "none":                        # L366-374
        for P in targets:
            a = P["CoreBase"]; b = a + P["VM"]["NumCpu"] - 1
            if (a // T["CPN"]) != (b // T["CPN"]) and P["VM"]["VS"] == 1:
                notes.append(f"boundary:{P['VM']['Name']}:{a}-{b}")

    # ---- 세로 표 행 (L376-460) ----
    vms = [dict(v, Role="PVM") for v in pri] + ([dict(sec, Role="SVM")] if sec else [])
    rows = {}
    def put(item, name, val):
        rows[(name, item)] = str(val)
    ht_text = "on" if T["HT"] else "off"
    snc_text = f"SNC-{T['NPS']} ({T['NPS']} nodes/socket)" if T["NPS"] > 1 else "disabled (1 node/socket)"
    m = re_ratio(share)
    if m == "normal":
        sp = ss = "normal"
    else:
        sp, ss = f"{m[0]} (custom)", f"{m[1]} (custom)"
    lpk = ["sched.mem.lpage.enable1GPage", "sched.mem.pin", "sched.mem.prealloc", "sched.mem.prealloc.pinnedMainMem", "sched.swap.vmxSwapEnabled"]
    lpv = ["TRUE", "TRUE", "TRUE", "TRUE", "FALSE"] if lpage == "on" else ["(없음)"] * 5
    for v in vms:
        n = v["Name"]; vs = v["VS"]; c = ceil_div(v["NumCpu"], vs)
        put("sockets x cores per socket", n, f"{T['S']} x {T['CPS']}")
        put("Hyperthreading", n, ht_text)
        put("SNC", n, snc_text)
        put("pCPU count", n, T["TOTAL"] * T["TPC"])
        put("structure / profile", n, f"{topo} / {profile}")
        put("role", n, v["Role"])
        put("cpu", n, v["NumCpu"])
        put("cores per socket / sockets", n, f"{c} / {vs}" + ("" if v["NumCpu"] % vs == 0 else " (vCPU 가 소켓 수로 안 나뉨)"))
        put("vNUMA nodes", n, vs)
        put("memory (GB)", n, v["MemGB"] if v["MemGB"] > 0 else "-")
        put("memory reservation", n, f"{v['MemGB']} (locked)" if v["MemGB"] > 0 else "-")
        put("cpu shares", n, sp if v["Role"] == "PVM" else ss)
        put("mem shares", n, sp if v["Role"] == "PVM" else ss)
        put("physical placement", n, placement(v, spec, profile, multi, targets, T, rpn))
        for k, val in zip(lpk, lpv):
            put(k, n, val)
        put("numa.vcpu.maxPerVirtualNode", n, c)
        put("vpmc.enable", n, "TRUE" if vpmc == "on" else "(없음)")
        put("numa.nodeAffinity", n, "(없음)")
    allp = dict(settings); allp.update(extras)
    keys = set(k for (_, k) in allp)
    for key in keys:
        for v in vms:
            rows[(v["Name"], key)] = allp.get((v["Name"], key), "")
    return dict(error="", settings=settings, extras=extras, notes=notes, rows=rows, vms=vms, topo=topo, sk=sk)


# ---------------------------------------------------------------------------
# 점검: python3 cpu_affinity_model.py
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
VDP_PS1 = os.path.join(HERE, "..", "cpu_affinity", "VmDeployPlan_v1_1.ps1")


def _svm_values(r, name):
    out, k = [], 0
    while (name, "sched.vcpu%d.affinity" % k) in r["settings"]:
        out.append(r["settings"][(name, "sched.vcpu%d.affinity" % k)])
        k += 1
    return out


def check_records(log):
    """테스트 플랜 CPU Affinity 시트의 기록과 사용자 사례(2026-11-20). 2소켓, 소켓당 8코어, HT on."""
    bad = 0
    pvm16 = [dict(Name="PVM", NumCpu=16, Cps=8)]
    cases = [
        ("시트 2절 vm4b_rev12: SVM 4 vCPU, 소켓당 코어 2(가상 소켓 2개)", ("rev12", pvm16, dict(Name="SVM", NumCpu=4, Cps=2), -1),
         ["31,29,27,25,30,28,26,24"] * 2 + ["15,13,11,9,14,12,10,8"] * 2),
        ("시트 3절 vm4b_rev11: 위와 같은 SVM, 소켓당 예약 2코어", ("rev11", pvm16, dict(Name="SVM", NumCpu=4, Cps=2), 2),
         ["31,29,27,25,23,21"] * 2 + ["15,13,11,9,7,5"] * 2),
        ("사용자 사례 rev11: SVM 2 vCPU, 가상 소켓 1개 (v3.9 는 31,29,27,25 와 15,13,11,9 로 나눔)", ("rev11", [dict(Name="PVM", NumCpu=8, Cps=8)], dict(Name="SVM", NumCpu=2, Cps=2), -1),
         ["31,29,27,25,15,13,11,9"] * 2),
        ("rev12: SVM 4 vCPU, 가상 소켓 1개", ("rev12", pvm16, dict(Name="SVM", NumCpu=4, Cps=4), -1),
         ["31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"] * 4),
        ("rev11: SVM 2 vCPU, 가상 소켓 2개(소켓당 코어 1)", ("rev11", pvm16, dict(Name="SVM", NumCpu=2, Cps=1), -1),
         ["31,29,27,25", "15,13,11,9"]),
    ]
    for title, (prof, pv, sv, res), want in cases:
        got = _svm_values(m310(prof, 2, 8, True, 1, pv, sv, esxi_reserve=res), "SVM")
        ok = got == want
        bad += not ok
        log("  [%s] %s" % ("ok" if ok else "FAIL", title))
        if not ok:
            log("        기대 %s\n        결과 %s" % (want, got))
    return bad


def check_versions(log):
    """v3.9 와 v3.10 의 값 비교: rev12, rev11 에서 SVM 의 가상 소켓 수가 호스트 노드 수보다 적을 때만 달라져야 한다."""
    import itertools
    hosts = [(2, 8, True, 1), (2, 8, False, 1), (2, 8, True, 2), (2, 32, True, 2), (2, 48, True, 1), (1, 8, True, 1), (1, 16, True, 2), (4, 8, True, 1)]
    tot = same = changed = bad = 0
    for (S, C, ht, snc), prof, npvm, pv, sv, cps in itertools.product(
            hosts, ["rev12", "rev11", "vm4d", "clear", "rnd_aff"], [0, 1, 2, 3], [2, 4, 8], [0, 1, 2, 3, 4, 6, 8], [0, 1, 2, 3, 4, 8]):
        if (sv == 0 and cps != 0) or (sv and cps > sv):
            continue
        pvms = [dict(Name="ev%02d" % (k + 1), NumCpu=pv, Cps=pv) for k in range(npvm)]
        svm = dict(Name="svm", NumCpu=sv, Cps=cps) if sv else None
        a = m39(prof, S, C, ht, snc, pvms, svm)
        b = m310(prof, S, C, ht, snc, pvms, svm)
        tot += 1
        ap = dict((k, v) for k, v in a["settings"].items() if k[0] != "svm")
        bp = dict((k, v) for k, v in b["settings"].items() if k[0] != "svm")
        if a["error"] != b["error"] or ap != bp or a["extras"] != b["extras"]:
            bad += 1
            log("  FAIL (SVM 밖의 값이 달라짐) %s" % ((S, C, ht, snc, prof, npvm, pv, sv, cps),))
            continue
        if a["settings"] == b["settings"]:
            same += 1
            continue
        changed += 1
        T = host_topo(S, C, ht, snc)
        vs = 1 if cps == 0 else ceil_div(sv, cps)
        if not (prof in ("rev12", "rev11") and vs < T["NN"]):
            bad += 1
            log("  FAIL (달라지면 안 되는 조합) %s" % ((S, C, ht, snc, prof, npvm, pv, sv, cps),))
            continue
        area = set()                                   # v3.9 가 SVM 에 쓰던 pCPU 전체
        for (n, _), v in m39(prof, S, C, ht, snc, pvms, dict(Name="svm", NumCpu=T["NN"] * 2, Cps=2))["settings"].items():
            if n == "svm":
                area |= set(v.split(","))
        gs = cps if cps > 0 else ceil_div(sv, vs)
        used = set()
        for v in range(sv):
            val = b["settings"][("svm", "sched.vcpu%d.affinity" % v)]
            lead = b["settings"][("svm", "sched.vcpu%d.affinity" % ((v // gs) * gs))]
            parts = val.split(",")
            if val != lead or not set(parts) <= area or len(parts) != len(set(parts)):
                bad += 1
                log("  FAIL (가상 소켓 안의 값이 다르거나 SVM 영역 밖) %s vcpu%d %s" % ((S, C, ht, snc, prof, sv, cps), v, val))
            used |= set(parts)
        if used != area:
            bad += 1
            log("  FAIL (SVM 영역을 다 쓰지 않음) %s" % ((S, C, ht, snc, prof, sv, cps),))
    log("  조합 %d: 값이 같음 %d, 달라짐 %d (rev12, rev11 에서 SVM 가상 소켓 수 < 호스트 노드 수인 경우), 이상 %d" % (tot, same, changed, bad))
    return bad


def check_plan_equals_apply(log):
    """계획표(mvdp11)의 VM 을 그대로 만들었을 때 적용 스크립트(m310)가 같은 값을 내는지."""
    import itertools
    tot = ok = 0
    for (S, C, ht, snc), n, vc, sv, svs, pf in itertools.product(
            [(1, 8, True, 1), (1, 16, True, 2), (4, 8, True, 1), (2, 8, True, 1), (2, 8, True, 2), (2, 12, False, 2), (2, 32, True, 2)],
            [0, 1, 2, 3, 5], [2, 3, 6, 8], [0, 2, 4, 6], [0, 1, 2, 4], ["rev12", "rev11", "vm4d", "clear"]):
        if sv == 0 and svs != 0:
            continue
        if n == 0 and sv == 0:
            continue
        if svs and sv % svs != 0:                      # 만들 수 없는 VM (vCPU 수가 가상 소켓 수로 나뉘지 않음. 계획표가 알림)
            continue
        r = mvdp11(pf, S, C, ht, snc, [vc] if n else [], pvm_count=n, svm_vcpu=sv, svm_vs=svs)
        if not r["error"] and any(v["NumCpu"] % v["VS"] for v in r["vms"]):
            continue                                   # 자동 규칙의 가상 소켓 수로 나뉘지 않는 PVM (계획표가 알림)
        tot += 1
        if r["error"]:
            pv = [dict(Name="ev%02d" % (k + 1), NumCpu=vc, Cps=0) for k in range(n)]
            a = m310(pf, S, C, ht, snc, pv, dict(Name="s", NumCpu=sv, Cps=0) if sv else None)
            ok += bool(a["error"])
            if not a["error"]:
                log("  FAIL (계획표는 오류, 적용은 값) %s %s" % ((S, C, ht, snc, n, vc, sv, svs, pf), r["error"]))
            continue
        pv, svd = [], None
        for v in r["vms"]:
            d = dict(Name=v["Name"], NumCpu=v["NumCpu"], Cps=ceil_div(v["NumCpu"], v["VS"]))
            if v["Role"] == "PVM":
                pv.append(d)
            else:
                svd = d
        a = m310(pf, S, C, ht, snc, pv, svd)
        x = dict(a["settings"]); x.update(a["extras"])
        y = dict(r["settings"]); y.update(r["extras"])
        if pf == "vm4d" and svd is not None:           # vm4d 의 SVM 은 두 스크립트 모두 전 노드 1:1 (가상 소켓 수와 무관)
            x = dict((k, v) for k, v in x.items() if k[0] != svd["Name"])
            y = dict((k, v) for k, v in y.items() if k[0] != svd["Name"])
        good = (x == y and not a["error"])
        ok += good
        if not good:
            log("  FAIL (계획표와 적용 값이 다름) %s" % ((S, C, ht, snc, n, vc, sv, svs, pf),))
    log("  계획표의 VM 을 그대로 만든 경우 %d건 가운데 %d건이 적용 스크립트의 값과 같음" % (tot, ok))
    return tot - ok


def _ps_value(text):
    text = text.strip()
    m = re.match(r'^@\((.*)\)$', text)
    if m:
        return [int(x) for x in m.group(1).split(",") if x.strip()]
    if text.startswith('"'):
        return text.strip('"')
    return int(text)


def check_ps1_selftest(log, path=VDP_PS1):
    """VmDeployPlan 의 Test-VmDeployPlan 에 적힌 기대값이 이 모델의 값과 같은지 (스크립트 글에서 사례를 읽는다)."""
    if not os.path.exists(path):
        log("  (건너뜀: %s 없음)" % path)
        return 0
    src = open(path, encoding="utf-8-sig").read()
    cases = re.findall(r'@\{ Name = "([^"]*)";\s*Args = \$H \+ @\{ (.*?) \}\n\s+Expect = @\{ (.*?) \} \}', src)
    bad = 0
    for name, args_text, expect_text in cases:
        args = {}
        for part in re.split(r';\s*(?=[A-Za-z0-9]+ = )', args_text):
            k, _, v = part.partition(" = ")
            args[k.strip()] = _ps_value(v)
        pvm = args.get("PvmVcpu", [])
        r = mvdp11(args["Profile"], 2, 8, args.get("HostHT", "on") == "on", args.get("HostSnc", 1), pvm,
                   pvm_count=args.get("PvmCount", 0), svm_vcpu=args.get("SvmVcpu", 0), esxi_reserve=args.get("EsxiReserveCores", -1),
                   pvm_vs=args.get("PvmVSockets", 0), svm_vs=args.get("SvmVSockets", 0), share=args.get("ShareRatio", "10000:1"),
                   lpage=args.get("Lpage1GB", "on"), vpmc=args.get("Vpmc", "off"), pvm_mem=tuple(args.get("PvmMemoryGB", [])),
                   svm_mem=args.get("SvmMemoryGB", 0))
        miss = []
        for key, want in re.findall(r'"([^"]*)" = "([^"]*)"', expect_text):
            vm, _, item = key.partition("|")
            got = "" if r.get("error") else r["rows"].get((vm, item), "")
            if got != want:
                miss.append("%s: 스크립트의 기대값 '%s', 모델 '%s'" % (key, want, got))
        bad += bool(miss)
        if miss:
            log("  [FAIL] %s" % name)
            for x in miss:
                log("        " + x)
    log("  Test-VmDeployPlan 의 사례 %d건 가운데 %d건의 기대값이 모델과 같음" % (len(cases), len(cases) - bad))
    return bad + (0 if cases else 1)


def main():
    def log(text):
        print(text)
    total = 0
    for title, fn in (("1. 시트 기록과 사용자 사례 (v3.10)", check_records), ("2. v3.9 와 v3.10 의 값 비교", check_versions),
                      ("3. 계획표(v1.1)와 적용(v3.10)의 값 비교", check_plan_equals_apply),
                      ("4. VmDeployPlan_v1_1.ps1 의 자체 점검 기대값", check_ps1_selftest)):
        print(title)
        total += fn(log)
    print("RESULT: %s" % ("전체 통과" if total == 0 else "실패 %d건" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())

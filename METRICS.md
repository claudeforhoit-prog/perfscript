# 스크립트별 수집 지표

이 파일은 `tools/gen_metrics.py` 가 수집기 코드에서 만든다. 손으로 고치지 않는다. 수집기의 지표 표를 바꾼 커밋에서 `python3 tools/gen_metrics.py` 를 실행해 함께 커밋한다.

| 수집기 | 판 | 실행 위치 | Ops 지표 경로 |
| :-- | :-- | :-- | :-- |
| ops_metric_push.sh | 4.7 | 게스트 OS, BM 호스트(--target bm) | VM 또는 BM 객체 > Custom Metrics > <그룹> > <지표> |
| gpu_metric_push.sh | 1.2 | 게스트 OS (GPU DirectPath I/O), BM 호스트(--target bm) | VM 또는 BM 객체 > Custom Metrics > Guest GPU > gpu<N> > <지표> |
| vmkperf_ops_push.py | 1.4 | ESXi 호스트 | Host > Custom Metrics > Host Perf > <지표> |

## 1. 게스트 OS — ops_metric_push.sh v4.7 (55개)

- 출처: 스크립트의 `METRIC_TABLE`. `s1`, `s2` 는 계산에 쓰는 원본 값이다(perf 이벤트, /proc/meminfo, /proc/vmstat).
- 적용 CPU 가 맞지 않는 줄은 수집하지 않고 CSV 칸만 비워 둔다. 지원하지 않는 perf 이벤트를 쓰는 줄은 시작할 때 자동으로 빠진다.
- `--perf-fit` 을 쓰면 하드웨어 카운터 수에 맞을 때까지 표의 뒤쪽 perf 이벤트부터 뺀다.
- 수집 조건이 '기본' 인 줄은 `--collect` 없이 실행할 때 수집한다. '이름 지정' 인 줄(13개)은 `--collect` 에 지표 이름을 적었을 때만 수집하고, `--collect both` 와 `--collect perf` 에는 포함되지 않는다.
- 적용 CPU 의 Intel 약칭: SKX 는 Skylake-SP, Cascade Lake-SP, Cooper Lake-SP(CPUID model 55h). ICX 는 Ice Lake-SP 와 Ice Lake-D(6Ah, 6Ch). SPR 은 Sapphire Rapids(8Fh). EMR 은 Emerald Rapids(CFh). GNR 은 Granite Rapids 와 Granite Rapids-D(ADh, AEh).

| 그룹 | 지표 | 계산 | s1 | s2 | 적용 CPU | 수집 조건 | 설명 |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| Guest Perf Generic | IPC_Ratio | s1/s2 | perf:instructions | perf:cycles | 전체 | 기본 | instructions/cycle |
| Guest Perf Generic | Cache_MissRate_Pct | s1/s2×100 | perf:cache-misses | perf:cache-references | AMD Zen 제외 | 기본 | LLC miss rate |
| Guest Perf Generic | L1D_MissRate_Pct | s1/s2×100 | perf:L1-dcache-load-misses | perf:L1-dcache-loads | AMD Zen 제외 | 기본 | L1D miss rate |
| Guest Perf Generic | DTLB_MissRate_Pct | s1/s2×100 | perf:dTLB-load-misses | perf:dTLB-loads | AMD Zen 제외 | 기본 | dTLB miss rate |
| Guest Perf Generic | Instructions | 값 그대로 | perf:instructions |  | 전체 | 기본 | instruction count |
| Guest Perf Generic | Cycles | 값 그대로 | perf:cycles |  | 전체 | 기본 | cycle count |
| Guest Perf Generic | Cache_Ref | 값 그대로 | perf:cache-references |  | AMD Zen 제외 | 기본 | LLC references |
| Guest Perf Generic | Cache_Miss | 값 그대로 | perf:cache-misses |  | AMD Zen 제외 | 기본 | LLC misses |
| Guest Perf Generic | L1D_Loads | 값 그대로 | perf:L1-dcache-loads |  | AMD Zen 제외 | 기본 | L1D loads |
| Guest Perf Generic | L1D_Load_Miss | 값 그대로 | perf:L1-dcache-load-misses |  | AMD Zen 제외 | 기본 | L1D load misses |
| Guest Perf Generic | DTLB_Loads | 값 그대로 | perf:dTLB-loads |  | AMD Zen 제외 | 기본 | dTLB loads |
| Guest Perf Generic | DTLB_Load_Miss | 값 그대로 | perf:dTLB-load-misses |  | AMD Zen 제외 | 기본 | dTLB load misses |
| Guest Perf Extended | ITLB_MissRate_Pct | s1/s2×100 | perf:iTLB-load-misses | perf:iTLB-loads | AMD Zen 제외 | 기본 | iTLB miss rate |
| Guest Perf Extended | ITLB_Loads | 값 그대로 | perf:iTLB-loads |  | AMD Zen 제외 | 기본 | iTLB loads |
| Guest Perf Extended | ITLB_Load_Miss | 값 그대로 | perf:iTLB-load-misses |  | AMD Zen 제외 | 기본 | iTLB load misses |
| Guest Perf Extended | LLC_Load_Miss | 값 그대로 | perf:LLC-load-misses |  | AMD Zen 제외 | 기본 | LLC load misses |
| Guest Perf Extended | LLC_Store_Miss | 값 그대로 | perf:LLC-store-misses |  | AMD Zen 제외 | 기본 | LLC store misses |
| Guest THP | Thp_Coverage_Pct | s1/s2×100 | meminfo:AnonHugePages | meminfo:AnonPages | 전체 | 기본 | THP coverage (instant) |
| Guest THP | Thp_AllocSuccess_Pct | Δs1/(Δs1+Δs2)×100 | vmstat:thp_fault_alloc | vmstat:thp_fault_fallback | 전체 | 기본 | 1-min delta-based fault success rate |
| Guest THP | Thp_CollapseSuccess_Pct | Δs1/(Δs1+Δs2)×100 | vmstat:thp_collapse_alloc | vmstat:thp_collapse_alloc_failed | 전체 | 기본 | 1-min delta-based collapse success rate |
| Guest THP | AnonPages_kB | 값 그대로 | meminfo:AnonPages |  | 전체 | 기본 | anonymous pages (instant) |
| Guest THP | AnonHugePages_kB | 값 그대로 | meminfo:AnonHugePages |  | 전체 | 기본 | THP pages (instant) |
| Guest THP | Thp_Fault_Alloc_Delta | 1분 증가분 | vmstat:thp_fault_alloc |  | 전체 | 기본 | THP fault allocs in 1 min |
| Guest THP | Thp_Fault_Fallback_Delta | 1분 증가분 | vmstat:thp_fault_fallback |  | 전체 | 기본 | fallbacks in 1 min |
| Guest THP | Thp_Collapse_Alloc_Delta | 1분 증가분 | vmstat:thp_collapse_alloc |  | 전체 | 기본 | collapse successes in 1 min |
| Guest THP | Thp_Collapse_Failed_Delta | 1분 증가분 | vmstat:thp_collapse_alloc_failed |  | 전체 | 기본 | collapse failures in 1 min |
| Guest Perf AMD | L2_DTLB_Miss_PTI | s1/s2×1000 | perf:l2_dtlb_miss | perf:instructions | AMD Zen 전체 | 기본 | L2 DTLB misses (page walks) per 1000 instr |
| Guest Perf AMD | L1D_Fill_Mem_PTI | s1/s2×1000 | perf:dc_fill_mem | perf:instructions | Zen 3, Zen 4, Zen 5 | 기본 | L1D fills from DRAM or MMIO per 1000 instr |
| Guest Perf AMD | L1D_Demand_Fill_Mem_PTI | s1/s2×1000 | perf:dmnd_fill_mem | perf:instructions | Zen 2 | 기본 | L1D demand fills from DRAM or IO per 1000 instr (Zen 2) |
| Guest Perf AMD | L2_Miss_PTI | s1/s2×1000 | perf:l2_miss | perf:instructions | AMD Zen 전체 | 기본 | L2 misses (IC+DC requests, no prefetch) per 1000 instr |
| Guest Perf AMD | L1D_Fill_Mem_Pct | s1/s2×100 | perf:dc_fill_mem | perf:dc_fill_all | Zen 3, Zen 4, Zen 5 | 기본 | share of L1D fills that came from DRAM or MMIO |
| Guest Perf AMD | L1D_Demand_Fill_Mem_Pct | s1/s2×100 | perf:dmnd_fill_mem | perf:dmnd_fill_all | Zen 2 | 기본 | share of L1D demand fills that came from DRAM or IO (Zen 2) |
| Guest Perf AMD | L1_DTLB_Miss_PTI | s1/s2×1000 | perf:l1_dtlb_miss | perf:instructions | AMD Zen 전체 | 기본 | L1 DTLB misses per 1000 instr |
| Guest Perf AMD | L2_ITLB_Miss_PTI | s1/s2×1000 | perf:l2_itlb_miss | perf:instructions | AMD Zen 전체 | 기본 | L2 ITLB misses (page walks) per 1000 instr |
| Guest Perf AMD | L2_DTLB_Miss | 값 그대로 | perf:l2_dtlb_miss |  | AMD Zen 전체 | 기본 | L2 DTLB misses (page walks) |
| Guest Perf AMD | L1D_Fill_Mem | 값 그대로 | perf:dc_fill_mem |  | Zen 3, Zen 4, Zen 5 | 기본 | L1D fills from DRAM or MMIO |
| Guest Perf AMD | L1D_Demand_Fill_Mem | 값 그대로 | perf:dmnd_fill_mem |  | Zen 2 | 기본 | L1D demand fills from DRAM or IO (Zen 2) |
| Guest Perf AMD | L2_Miss | 값 그대로 | perf:l2_miss |  | AMD Zen 전체 | 기본 | L2 misses (IC+DC requests, no prefetch) |
| Guest Perf AMD | L1D_Fill_All | 값 그대로 | perf:dc_fill_all |  | Zen 3, Zen 4, Zen 5 | 기본 | L1D fills from every source |
| Guest Perf AMD | L1D_Demand_Fill_All | 값 그대로 | perf:dmnd_fill_all |  | Zen 2 | 기본 | L1D demand fills from every listed source (Zen 2) |
| Guest Perf AMD | L1_DTLB_Miss | 값 그대로 | perf:l1_dtlb_miss |  | AMD Zen 전체 | 기본 | L1 DTLB misses |
| Guest Perf AMD | L2_ITLB_Miss | 값 그대로 | perf:l2_itlb_miss |  | AMD Zen 전체 | 기본 | L2 ITLB misses (page walks) |
| Guest Perf AMD | L1D_Fill_L3_PTI | s1/s2×1000 | perf:dc_fill_l3 | perf:instructions | Zen 3, Zen 4, Zen 5 | 이름 지정 | L1D fills from L3 or another L2 of the same CCX per 1000 instr |
| Guest Perf AMD | L1D_Fill_L3_Pct | s1/s2×100 | perf:dc_fill_l3 | perf:dc_fill_all | Zen 3, Zen 4, Zen 5 | 이름 지정 | share of L1D fills that came from L3 or another L2 of the same CCX |
| Guest Perf AMD | L1D_Fill_L3 | 값 그대로 | perf:dc_fill_l3 |  | Zen 3, Zen 4, Zen 5 | 이름 지정 | L1D fills from L3 or another L2 of the same CCX |
| Guest Perf Intel | LLC_Miss_PTI | s1/s2×1000 | perf:cache-misses | perf:instructions | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | LLC misses per 1000 instr |
| Guest Perf Intel | Cycles_Per_RefCycle | s1/s2 | perf:cycles | perf:ref-cycles | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | core cycles per reference cycle |
| Guest Perf Intel | L3_Load_Miss_PTI | s1/s2×1000 | perf:l3_load_miss | perf:instructions | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | retired loads that missed the L3 per 1000 instr |
| Guest Perf Intel | L3_Miss_Stall_Pct | s1/s2×100 | perf:l3_miss_stall | perf:cycles | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | share of cycles stalled while an L3-miss load is outstanding |
| Guest Perf Intel | L3_Miss_Stall_Per_Miss | s1/s2 | perf:l3_miss_stall | perf:l3_load_miss | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | stall cycles per retired load that missed the L3 |
| Guest Perf Intel | DTLB_Walk_Cycles | s1/s2 | perf:walk_pending | perf:dTLB-load-misses | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | page-walk cycles per completed page walk (loads) |
| Guest Perf Intel | Ref_Cycles | 값 그대로 | perf:ref-cycles |  | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | reference cycles |
| Guest Perf Intel | L3_Load_Miss | 값 그대로 | perf:l3_load_miss |  | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | retired loads that missed the L3 |
| Guest Perf Intel | L3_Miss_Stall | 값 그대로 | perf:l3_miss_stall |  | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | cycles stalled while an L3-miss load is outstanding |
| Guest Perf Intel | DTLB_Walk_Pending | 값 그대로 | perf:walk_pending |  | Intel SKX, ICX, SPR, EMR, GNR | 이름 지정 | page-walk cycles for loads, summed over the walks in progress |

## 2. GPU — gpu_metric_push.sh v1.2 (지표 36개, 구성 정보 17개)

- 출처: 스크립트의 `METRIC_TABLE`, `PROP_TABLE`. GPU 마다 `gpu0`, `gpu1` … 아래에 기록한다.
- 드라이버나 GPU 가 주지 않는 필드는 시작할 때 확인해 빠진다(`--check` 로 확인).

| 지표 | 1분 집계 | 원본 | 필드 |
| :-- | :-- | :-- | :-- |
| Util_Gpu_Pct | 구간 평균 | nvidia-smi --query-gpu | utilization.gpu |
| Util_MemCtrl_Pct | 구간 평균 | nvidia-smi --query-gpu | utilization.memory |
| Mem_Used_MiB | 구간 평균 | nvidia-smi --query-gpu | memory.used |
| Mem_Free_MiB | 구간 평균 | nvidia-smi --query-gpu | memory.free |
| Mem_Reserved_MiB | 마지막 값 | nvidia-smi --query-gpu | memory.reserved |
| Temp_Gpu_C | 구간 평균 | nvidia-smi --query-gpu | temperature.gpu |
| Temp_Mem_C | 구간 평균 | nvidia-smi --query-gpu | temperature.memory |
| Temp_TLimit_C | 구간 평균 | nvidia-smi --query-gpu | temperature.gpu.tlimit |
| Power_Draw_W | 구간 평균 | nvidia-smi --query-gpu | power.draw |
| Power_Limit_W | 마지막 값 | nvidia-smi --query-gpu | enforced.power.limit |
| Clock_SM_MHz | 구간 평균 | nvidia-smi --query-gpu | clocks.sm |
| Clock_Mem_MHz | 구간 평균 | nvidia-smi --query-gpu | clocks.mem |
| PState | 마지막 값 | nvidia-smi --query-gpu | pstate |
| ClkEvt_SwPowerCap_Pct | 구간 중 해당 비율(%) | nvidia-smi --query-gpu | clocks_event_reasons.sw_power_cap |
| ClkEvt_HwSlowdown_Pct | 구간 중 해당 비율(%) | nvidia-smi --query-gpu | clocks_event_reasons.hw_slowdown |
| ClkEvt_HwThermal_Pct | 구간 중 해당 비율(%) | nvidia-smi --query-gpu | clocks_event_reasons.hw_thermal_slowdown |
| ClkEvt_HwPowerBrake_Pct | 구간 중 해당 비율(%) | nvidia-smi --query-gpu | clocks_event_reasons.hw_power_brake_slowdown |
| ClkEvt_SwThermal_Pct | 구간 중 해당 비율(%) | nvidia-smi --query-gpu | clocks_event_reasons.sw_thermal_slowdown |
| PCIe_Gen | 마지막 값 | nvidia-smi --query-gpu | pcie.link.gen.current |
| PCIe_Width | 마지막 값 | nvidia-smi --query-gpu | pcie.link.width.current |
| PCIe_Rx_MBps | 구간 평균 | nvidia-smi dmon | rxpci |
| PCIe_Tx_MBps | 구간 평균 | nvidia-smi dmon | txpci |
| PCIe_Replay | 마지막 값 | nvidia-smi dmon | pci |
| ECC_Corr_Volatile | 마지막 값 | nvidia-smi --query-gpu | ecc.errors.corrected.volatile.total |
| ECC_Uncorr_Volatile | 마지막 값 | nvidia-smi --query-gpu | ecc.errors.uncorrected.volatile.total |
| ECC_Corr_Aggregate | 마지막 값 | nvidia-smi --query-gpu | ecc.errors.corrected.aggregate.total |
| ECC_Uncorr_Aggregate | 마지막 값 | nvidia-smi --query-gpu | ecc.errors.uncorrected.aggregate.total |
| Retired_SBE | 마지막 값 | nvidia-smi --query-gpu | retired_pages.sbe |
| Retired_DBE | 마지막 값 | nvidia-smi --query-gpu | retired_pages.dbe |
| Retired_Pending | 마지막 값 | nvidia-smi --query-gpu | retired_pages.pending |
| Remap_Corr | 마지막 값 | nvidia-smi --query-remapped-rows | remapped_rows.correctable |
| Remap_Uncorr | 마지막 값 | nvidia-smi --query-remapped-rows | remapped_rows.uncorrectable |
| Remap_Pending | 마지막 값 | nvidia-smi --query-remapped-rows | remapped_rows.pending |
| Remap_Failure | 마지막 값 | nvidia-smi --query-remapped-rows | remapped_rows.failure |
| GPU_Count | 마지막 값 | 수집기 계산 | gpu_count |
| Query_OK_Pct | 구간 중 해당 비율(%) | 수집기 계산 | query_ok |

구성 정보 (Custom Configuration > Guest GPU > gpu<N>)

| 항목 | nvidia-smi 필드 |
| :-- | :-- |
| Name | name |
| UUID | uuid |
| PCI Bus Id | pci.bus_id |
| Serial | serial |
| VBIOS Version | vbios_version |
| Driver Version | driver_version |
| Memory Total MiB | memory.total |
| Max SM Clock MHz | clocks.max.sm |
| Max Memory Clock MHz | clocks.max.mem |
| Default Power Limit W | power.default_limit |
| Max Power Limit W | power.max_limit |
| PCIe Max Gen | pcie.link.gen.max |
| PCIe Max Width | pcie.link.width.max |
| ECC Mode | ecc.mode.current |
| MIG Mode | mig.mode.current |
| Persistence Mode | persistence_mode |
| Compute Mode | compute_mode |

## 3. ESXi 호스트 — vmkperf_ops_push.py v1.4

- 출처: `events/<세대>.json`(이벤트), `events/metrics*.json`(지표 계산), `vmkperf_ops_push.py` 의 `plan_counters()`(카운터 배치).
- 수집 여부는 이 스크립트가 수집기의 배치 함수로 계산한 값이다. 실제 호스트에서는 `check` 와 시작 로그의 `SKIPPED` 줄로 확인한다.
- Intel 은 ESXi 고정 카운터로 cycles 를 센다고 가정했다(기본 동작). AMD 는 고정 카운터가 없어 cycles 도 일반 카운터 하나를 쓴다.
- 선택 수집: `--qos` 를 켜면 rmID 별 LLC 점유량(`LLC_Occ_*_MB`)을 함께 보낸다.

| 세대 | CPUID family-model | 일반 카운터 | 이벤트 | 수집 지표 | 카운터 부족으로 빠지는 지표 | 이벤트 없음 |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| sapphirerapids (Intel Xeon 4th Gen (Sapphire Rapids)) | 6-143 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| emeraldrapids (Intel Xeon 5th Gen (Emerald Rapids)) | 6-207 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| graniterapids (Intel Xeon 6 (Granite Rapids)) | 6-173, 6-174 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| naples (AMD Zen 1) | 23-1, 23-17 | 6 | 6 (시작 못 함: 없음) | 11 | - | L1D_Fill_Mem, L1D_Fill_All, L1D_Fill_Mem_PTI, L1D_Fill_Mem_Pct, L1D_Fill_L3, L1D_Fill_L3_PTI, L1D_Fill_L3_Pct |
| rome (AMD Zen 2) | 23-49 | 6 | 8 (시작 못 함: l1_dtlb_miss, l2_itlb_miss) | 11 | L1_DTLB_Miss, L2_ITLB_Miss, L1_DTLB_Miss_PTI, L2_ITLB_Miss_PTI | - |
| milan (AMD Zen 3) | 25-1 | 6 | 9 (시작 못 함: l1_dtlb_miss, l2_itlb_miss, dc_fill_l3) | 11 | L1_DTLB_Miss, L2_ITLB_Miss, L1_DTLB_Miss_PTI, L2_ITLB_Miss_PTI, L1D_Fill_L3, L1D_Fill_L3_PTI, L1D_Fill_L3_Pct | - |
| genoa (AMD Zen 4) | 25-160, 25-17 | 6 | 9 (시작 못 함: l1_dtlb_miss, l2_itlb_miss, dc_fill_l3) | 11 | L1_DTLB_Miss, L2_ITLB_Miss, L1_DTLB_Miss_PTI, L2_ITLB_Miss_PTI, L1D_Fill_L3, L1D_Fill_L3_PTI, L1D_Fill_L3_Pct | - |
| turin (AMD Zen 5) | 26-17, 26-2 | 6 | 9 (시작 못 함: l1_dtlb_miss, l2_itlb_miss, dc_fill_l3) | 11 | L1_DTLB_Miss, L2_ITLB_Miss, L1_DTLB_Miss_PTI, L2_ITLB_Miss_PTI, L1D_Fill_L3, L1D_Fill_L3_PTI, L1D_Fill_L3_Pct | - |

세대별 대상 CPU

- `sapphirerapids`: Intel Xeon 4th Gen (Sapphire Rapids)
- `emeraldrapids`: Intel Xeon 5th Gen (Emerald Rapids)
- `graniterapids`: Intel Xeon 6 (Granite Rapids)
- `naples`: AMD Zen 1: EPYC 7001 Series (CPUID 17.01), Ryzen Embedded V1000 Series (17.11)
- `rome`: AMD Zen 2: EPYC 7002/7Fx2/7Hx2 Series (CPUID 17.31)
- `milan`: AMD Zen 3: EPYC 7003/7003X Series (CPUID 19.01)
- `genoa`: AMD Zen 4: EPYC 9004 Series (CPUID 19.11, 19.A0), EPYC 8004 Series (19.A0)
- `turin`: AMD Zen 5: EPYC 9005 Series (CPUID 1A.2, 1A.11)

지표 정의

| 지표 | 형식 | 계산 (이벤트 키) | 정의 파일 | 설명 |
| :-- | :-- | :-- | :-- | :-- |
| LLC_Miss | sum | llc_miss | metrics.json | LLC misses in the interval |
| LLC_Ref | sum | llc_ref | metrics.json | LLC references in the interval |
| Cycles | sum | cycles | metrics.json, metrics_amd.json, metrics_amd_zen2.json | unhalted cycles in the interval |
| Instructions | sum | instr | metrics.json, metrics_amd.json, metrics_amd_zen2.json | retired instructions in the interval |
| L3_Load_Miss | sum | l3_load_miss | metrics.json | retired demand loads that missed L3 |
| L3_Load_Hit | sum | l3_load_hit | metrics.json | retired demand loads that hit L3 |
| L3_Miss_DemandRd | sum | l3miss_rd | metrics.json | offcore demand data reads that missed L3 |
| L3_Stall_Cycles | sum | l3_stall | metrics.json | stall cycles with an L3 miss pending |
| LLC_MissRate_Pct | pct | 100 × llc_miss / llc_ref | metrics.json | LLC miss / LLC reference |
| LLC_MPKI | ratio | 1000 × llc_miss / instr | metrics.json | LLC misses per 1000 instructions |
| L3_Load_MPKI | ratio | 1000 × l3_load_miss / instr | metrics.json | demand-load L3 misses per 1000 instructions |
| L3_Load_HitRate_Pct | pct | 100 × l3_load_hit / l3_load_hit+l3_load_miss | metrics.json | demand-load L3 hit / (hit+miss) |
| L3_Miss_Latency_Cyc | ratio | 1 × l3miss_rd_outst / l3miss_rd | metrics.json | average L3-miss demand read latency in cycles |
| L3_Stall_Pct | pct | 100 × l3_stall / cycles | metrics.json | share of cycles stalled on an L3 miss |
| IPC | ratio | 1 × instr / cycles | metrics.json, metrics_amd.json, metrics_amd_zen2.json | instructions per cycle |
| L2_DTLB_Miss | sum | l2_dtlb_miss | metrics_amd.json, metrics_amd_zen2.json | L2 DTLB misses (page walks) |
| L1D_Fill_Mem | sum | dc_fill_mem | metrics_amd.json | L1 data cache fills from DRAM or MMIO |
| L2_Miss | sum | l2_miss | metrics_amd.json, metrics_amd_zen2.json | core-to-L2 requests that missed L2 (no prefetch) |
| L1D_Fill_All | sum | dc_fill_all | metrics_amd.json | L1 data cache fills from every source |
| L1_DTLB_Miss | sum | l1_dtlb_miss | metrics_amd.json, metrics_amd_zen2.json | L1 DTLB misses |
| L2_ITLB_Miss | sum | l2_itlb_miss | metrics_amd.json, metrics_amd_zen2.json | L2 ITLB misses (page walks) |
| L2_DTLB_Miss_PTI | ratio | 1000 × l2_dtlb_miss / instr | metrics_amd.json, metrics_amd_zen2.json | L2 DTLB misses per 1000 instructions |
| L1D_Fill_Mem_PTI | ratio | 1000 × dc_fill_mem / instr | metrics_amd.json | L1D fills from DRAM or MMIO per 1000 instructions |
| L2_Miss_PTI | ratio | 1000 × l2_miss / instr | metrics_amd.json, metrics_amd_zen2.json | L2 misses per 1000 instructions |
| L1D_Fill_Mem_Pct | pct | 100 × dc_fill_mem / dc_fill_all | metrics_amd.json | share of L1D fills that came from DRAM or MMIO |
| L1_DTLB_Miss_PTI | ratio | 1000 × l1_dtlb_miss / instr | metrics_amd.json, metrics_amd_zen2.json | L1 DTLB misses per 1000 instructions |
| L2_ITLB_Miss_PTI | ratio | 1000 × l2_itlb_miss / instr | metrics_amd.json, metrics_amd_zen2.json | L2 ITLB misses per 1000 instructions |
| L1D_Fill_L3 | sum | dc_fill_l3 | metrics_amd.json | L1 data cache fills from the L3, or another core's L2, of the same CCX |
| L1D_Fill_L3_PTI | ratio | 1000 × dc_fill_l3 / instr | metrics_amd.json | L1D fills from L3 or another L2 of the same CCX per 1000 instructions |
| L1D_Fill_L3_Pct | pct | 100 × dc_fill_l3 / dc_fill_all | metrics_amd.json | share of L1D fills that came from L3 or another L2 of the same CCX |
| L1D_Demand_Fill_Mem | sum | dmnd_fill_mem | metrics_amd_zen2.json | L1 data cache demand fills from DRAM or IO |
| L1D_Demand_Fill_All | sum | dmnd_fill_all | metrics_amd_zen2.json | L1 data cache demand fills from every listed source |
| L1D_Demand_Fill_Mem_PTI | ratio | 1000 × dmnd_fill_mem / instr | metrics_amd_zen2.json | L1D demand fills from DRAM or IO per 1000 instructions |
| L1D_Demand_Fill_Mem_Pct | pct | 100 × dmnd_fill_mem / dmnd_fill_all | metrics_amd_zen2.json | share of L1D demand fills that came from DRAM or IO |

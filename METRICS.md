# 스크립트별 수집 지표

이 파일은 `tools/gen_metrics.py` 가 수집기 코드에서 만든다. 손으로 고치지 않는다. 수집기의 지표 표를 바꾼 커밋에서 `python3 tools/gen_metrics.py` 를 실행해 함께 커밋한다.

| 수집기 | 판 | 실행 위치 | Ops 지표 경로 |
| :-- | :-- | :-- | :-- |
| ops_metric_push.sh | 4.8 | 게스트 OS, BM 호스트(--target bm) | VM 또는 BM 객체 > Custom Metrics > <그룹> > <지표> |
| gpu_metric_push.sh | 1.2 | 게스트 OS (GPU DirectPath I/O), BM 호스트(--target bm) | VM 또는 BM 객체 > Custom Metrics > Guest GPU > gpu<N> > <지표> |
| vmkperf_ops_push.py | 1.5 | ESXi 호스트 | Host > Custom Metrics > Host Perf > <지표> |

## 1. 게스트 OS — ops_metric_push.sh v4.8 (26개)

- 출처: 스크립트의 `METRIC_TABLE`. `s1`, `s2` 는 계산에 쓰는 원본 값이다(perf 이벤트, /proc/meminfo, /proc/vmstat).
- 모든 줄을 CPU 종류와 관계없이 수집한다. 지원하지 않는 perf 이벤트를 쓰는 줄은 시작할 때 자동으로 빠진다.
- perf 이벤트 이름이 실제로 세는 이벤트는 게스트의 커널이 CPU 에 따라 정한다. AMD CPU 에서의 연결은 `README.md` 2절에 있다.
- `--perf-fit` 을 쓰면 하드웨어 카운터 수에 맞을 때까지 표의 뒤쪽 perf 이벤트부터 뺀다.

| 그룹 | 지표 | 계산 | s1 | s2 | 설명 |
| :-- | :-- | :-- | :-- | :-- | :-- |
| Guest Perf Generic | IPC_Ratio | s1/s2 | perf:instructions | perf:cycles | instructions/cycle |
| Guest Perf Generic | Cache_MissRate_Pct | s1/s2×100 | perf:cache-misses | perf:cache-references | LLC miss rate |
| Guest Perf Generic | L1D_MissRate_Pct | s1/s2×100 | perf:L1-dcache-load-misses | perf:L1-dcache-loads | L1D miss rate |
| Guest Perf Generic | DTLB_MissRate_Pct | s1/s2×100 | perf:dTLB-load-misses | perf:dTLB-loads | dTLB miss rate |
| Guest Perf Generic | Instructions | 값 그대로 | perf:instructions |  | instruction count |
| Guest Perf Generic | Cycles | 값 그대로 | perf:cycles |  | cycle count |
| Guest Perf Generic | Cache_Ref | 값 그대로 | perf:cache-references |  | LLC references |
| Guest Perf Generic | Cache_Miss | 값 그대로 | perf:cache-misses |  | LLC misses |
| Guest Perf Generic | L1D_Loads | 값 그대로 | perf:L1-dcache-loads |  | L1D loads |
| Guest Perf Generic | L1D_Load_Miss | 값 그대로 | perf:L1-dcache-load-misses |  | L1D load misses |
| Guest Perf Generic | DTLB_Loads | 값 그대로 | perf:dTLB-loads |  | dTLB loads |
| Guest Perf Generic | DTLB_Load_Miss | 값 그대로 | perf:dTLB-load-misses |  | dTLB load misses |
| Guest Perf Extended | ITLB_MissRate_Pct | s1/s2×100 | perf:iTLB-load-misses | perf:iTLB-loads | iTLB miss rate |
| Guest Perf Extended | ITLB_Loads | 값 그대로 | perf:iTLB-loads |  | iTLB loads |
| Guest Perf Extended | ITLB_Load_Miss | 값 그대로 | perf:iTLB-load-misses |  | iTLB load misses |
| Guest Perf Extended | LLC_Load_Miss | 값 그대로 | perf:LLC-load-misses |  | LLC load misses |
| Guest Perf Extended | LLC_Store_Miss | 값 그대로 | perf:LLC-store-misses |  | LLC store misses |
| Guest THP | Thp_Coverage_Pct | s1/s2×100 | meminfo:AnonHugePages | meminfo:AnonPages | THP coverage (instant) |
| Guest THP | Thp_AllocSuccess_Pct | Δs1/(Δs1+Δs2)×100 | vmstat:thp_fault_alloc | vmstat:thp_fault_fallback | 1-min delta-based fault success rate |
| Guest THP | Thp_CollapseSuccess_Pct | Δs1/(Δs1+Δs2)×100 | vmstat:thp_collapse_alloc | vmstat:thp_collapse_alloc_failed | 1-min delta-based collapse success rate |
| Guest THP | AnonPages_kB | 값 그대로 | meminfo:AnonPages |  | anonymous pages (instant) |
| Guest THP | AnonHugePages_kB | 값 그대로 | meminfo:AnonHugePages |  | THP pages (instant) |
| Guest THP | Thp_Fault_Alloc_Delta | 1분 증가분 | vmstat:thp_fault_alloc |  | THP fault allocs in 1 min |
| Guest THP | Thp_Fault_Fallback_Delta | 1분 증가분 | vmstat:thp_fault_fallback |  | fallbacks in 1 min |
| Guest THP | Thp_Collapse_Alloc_Delta | 1분 증가분 | vmstat:thp_collapse_alloc |  | collapse successes in 1 min |
| Guest THP | Thp_Collapse_Failed_Delta | 1분 증가분 | vmstat:thp_collapse_alloc_failed |  | collapse failures in 1 min |

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

## 3. ESXi 호스트 — vmkperf_ops_push.py v1.5

- 출처: `events/<세대>.json`(이벤트), `events/metrics.json`(지표 계산), `vmkperf_ops_push.py` 의 `plan_counters()`(카운터 배치).
- 수집 여부는 이 스크립트가 수집기의 배치 함수로 계산한 값이다. 실제 호스트에서는 `check` 와 시작 로그의 `SKIPPED` 줄로 확인한다.
- Intel 은 ESXi 고정 카운터로 cycles 를 센다고 가정했다(기본 동작). AMD 는 고정 카운터가 없어 cycles 도 일반 카운터 하나를 쓴다.
- 지표 정의는 모든 CPU 에 같다. AMD 의 이벤트 파일에는 지표가 쓰는 이벤트 가운데 AMD core 카운터에 있는 cycles 와 instr 만 있어, 그 밖의 지표는 '이벤트 없음' 으로 빠진다.
- 선택 수집: `--qos` 를 켜면 rmID 별 LLC 점유량(`LLC_Occ_*_MB`)을 함께 보낸다.

| 세대 | CPUID family-model | 일반 카운터 | 이벤트 | 수집 지표 | 카운터 부족으로 빠지는 지표 | 이벤트 없음 |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| sapphirerapids (Intel Xeon 4th Gen (Sapphire Rapids)) | 6-143 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| emeraldrapids (Intel Xeon 5th Gen (Emerald Rapids)) | 6-207 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| graniterapids (Intel Xeon 6 (Granite Rapids)) | 6-173, 6-174 | 8 + 고정(cycles) | 9 (시작 못 함: l3_load_hit) | 13 | L3_Load_Hit, L3_Load_HitRate_Pct | - |
| naples (AMD Zen 1) | 23-1, 23-17 | 6 | 2 (시작 못 함: 없음) | 3 | - | LLC_Miss, LLC_Ref, L3_Load_Miss, L3_Load_Hit, L3_Miss_DemandRd, L3_Stall_Cycles, LLC_MissRate_Pct, LLC_MPKI, L3_Load_MPKI, L3_Load_HitRate_Pct, L3_Miss_Latency_Cyc, L3_Stall_Pct |
| rome (AMD Zen 2) | 23-49 | 6 | 2 (시작 못 함: 없음) | 3 | - | LLC_Miss, LLC_Ref, L3_Load_Miss, L3_Load_Hit, L3_Miss_DemandRd, L3_Stall_Cycles, LLC_MissRate_Pct, LLC_MPKI, L3_Load_MPKI, L3_Load_HitRate_Pct, L3_Miss_Latency_Cyc, L3_Stall_Pct |
| milan (AMD Zen 3) | 25-1 | 6 | 2 (시작 못 함: 없음) | 3 | - | LLC_Miss, LLC_Ref, L3_Load_Miss, L3_Load_Hit, L3_Miss_DemandRd, L3_Stall_Cycles, LLC_MissRate_Pct, LLC_MPKI, L3_Load_MPKI, L3_Load_HitRate_Pct, L3_Miss_Latency_Cyc, L3_Stall_Pct |
| genoa (AMD Zen 4) | 25-160, 25-17 | 6 | 2 (시작 못 함: 없음) | 3 | - | LLC_Miss, LLC_Ref, L3_Load_Miss, L3_Load_Hit, L3_Miss_DemandRd, L3_Stall_Cycles, LLC_MissRate_Pct, LLC_MPKI, L3_Load_MPKI, L3_Load_HitRate_Pct, L3_Miss_Latency_Cyc, L3_Stall_Pct |
| turin (AMD Zen 5) | 26-17, 26-2 | 6 | 2 (시작 못 함: 없음) | 3 | - | LLC_Miss, LLC_Ref, L3_Load_Miss, L3_Load_Hit, L3_Miss_DemandRd, L3_Stall_Cycles, LLC_MissRate_Pct, LLC_MPKI, L3_Load_MPKI, L3_Load_HitRate_Pct, L3_Miss_Latency_Cyc, L3_Stall_Pct |

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
| Cycles | sum | cycles | metrics.json | unhalted cycles in the interval |
| Instructions | sum | instr | metrics.json | retired instructions in the interval |
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
| IPC | ratio | 1 × instr / cycles | metrics.json | instructions per cycle |

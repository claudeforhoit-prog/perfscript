# Ops 수집기 (ops_push)

VCF Operations 로 사용자 지표를 전송하는 수집기 세 개를 관리하는 폴더다. 접속 주소와 계정, 비밀번호는 스크립트에 넣지 않고 설정 파일 `ops_local.conf` 에서 읽는다.

| 파일 | 실행 위치 | 수집 내용 | 버전 |
| :-- | :-- | :-- | :-- |
| `ops_metric_push.sh` | 게스트 OS, BM 호스트 | perf 지표와 THP 지표 | 4.7 |
| `gpu_metric_push.sh` | GPU 를 DirectPath I/O 로 할당받은 게스트 OS, GPU 가 있는 BM 호스트 | nvidia-smi 지표 | 1.2 |
| `vmkperf_ops_push/vmkperf_ops_push.py` | ESXi 호스트 | vmkperf 지표 | 1.4 |

## 1. 접속 설정 파일 ops_local.conf

1. `ops_local.conf` 를 스크립트와 같은 폴더에 둔다. 저장소의 파일에는 키만 있고 값은 비어 있다.
2. 아래 네 값을 채운다.
3. `chmod 600 ops_local.conf` 를 실행한다.

| 키 | 내용 |
| :-- | :-- |
| `OPS_HOST` | Operations 주소 또는 IP. `https://` 를 생략하면 https 로 접속한다 |
| `OPS_USER` | Operations 계정. LOCAL 계정만 토큰을 받을 수 있다 |
| `OPS_ENC_KEY` | 암호문을 푸는 키. 임의의 문자열을 정해 넣는다 |
| `OPS_PASS_ENC` | 암호화한 비밀번호. `bash ops_metric_push.sh --encrypt` 가 이 줄을 출력한다 |

- 암호문은 `OPS_ENC_KEY` 를 먼저 넣은 뒤에 만든다. `--encrypt` 는 비밀번호를 두 번 입력받아 `OPS_PASS_ENC=...` 한 줄을 출력한다. 그 줄을 `ops_local.conf` 에 넣는다.
- 형식은 한 줄에 `키=값` 하나다. `#` 로 시작하는 줄은 주석이다. 값의 따옴표는 생략할 수 있다.
- 스크립트는 이 파일을 글자로 읽기만 하고 실행하지 않는다.
- 값의 우선순위는 명령행 옵션, 환경 변수(`OPS_HOST`, `OPS_USER`, `OPS_PASSWORD`), 설정 파일 순이다.
- 다른 위치의 파일을 쓰려면 `--config 경로` 를 지정하거나 환경 변수 `OPS_PUSH_CONFIG` 에 경로를 넣는다.
- 호스트 수집기는 `vmkperf_ops_push.py` 와 같은 폴더에서 먼저 찾고, 없으면 한 단계 위 폴더에서 찾는다.
- CSV 만 저장하는 실행(`--mode file`)에는 설정 파일이 필요 없다.
- 값을 채운 `ops_local.conf` 는 Git 에 올리지 않는다. 저장소에는 값이 빈 파일만 둔다.

## 2. 실행

게스트 OS 의 기본 셸이 csh 인 경우의 예다.

```
bash ops_metric_push.sh --list                          # 지표 목록
nohup bash ops_metric_push.sh >& /tmp/ops_push.log &    # 수집 시작
nohup bash ops_metric_push.sh --perf-fit >& /tmp/ops_push.log &
bash ops_metric_push.sh --stop                          # 중지
```

```
bash gpu_metric_push.sh --check                         # GPU 와 드라이버가 주는 값 확인
nohup bash gpu_metric_push.sh >& /tmp/gpu_metric_push.log &
bash gpu_metric_push.sh --stop
```

ESXi 호스트에서는 `vmkperf_ops_push` 폴더 전체와 `ops_local.conf` 를 같은 위치에 복사한 뒤 실행한다.

```
python3 vmkperf_ops_push.py check                       # 사전 점검
nohup python3 vmkperf_ops_push.py start > /dev/null 2>&1 &
python3 vmkperf_ops_push.py stop
```

옵션 전체는 각 스크립트의 `--help` 와 파일 첫머리 설명에 있다.

### BM 호스트에서 실행 (`--target bm`)

VM 이 아닌 BM 호스트에서도 같은 수집기를 실행한다. `--target bm` 을 지정하면 수집기가 Operations 에서 이름이 같은 객체를 모든 adapter kind 에서 찾는다.

- 객체가 있으면 그 객체에 전송한다. 지표는 VM 과 같이 `Custom Metrics` 아래에 기록된다.
- 객체가 없으면 객체를 만든 뒤 전송한다. 만든 객체의 adapter kind 는 `BareMetalPush`, object type 은 `BareMetalServer` 이다. `--adapter-kind`, `--resource-kind` 로 다른 이름을 지정할 수 있다.
- 다시 시작하면 앞서 만든 객체를 찾아 그대로 쓴다. 객체를 다시 만들지 않는다.
- 이름이 같은 객체가 여럿이면 다른 어댑터가 수집하는 객체를 먼저 쓴다.
- 객체 이름은 `--name` 으로 지정한다. 생략하면 `hostname -s` 값이다.
- 객체 조회가 실패하거나 Operations 가 객체 생성을 거부하면 수집기는 객체를 만들지 않고 종료한다. 계정에 객체를 만들 권한이 있어야 한다.
- 만든 객체에는 이 수집기가 보낸 지표만 있다. 다른 어댑터가 수집하는 항목은 없다.
- `--target vm`(기본값)과 `--target any` 는 객체를 만들지 않는다. VM 이름을 잘못 적었을 때 새 객체가 생기지 않게 하기 위해서다.

```
nohup bash ops_metric_push.sh --target bm >& /tmp/ops_push.log &                 # csh, tcsh
nohup bash ops_metric_push.sh --target bm > /tmp/ops_push.log 2>&1 &             # bash
nohup bash ops_metric_push.sh --target bm --name bm-node01 --perf-fit >& /tmp/ops_push.log &
nohup bash gpu_metric_push.sh --target bm >& /tmp/gpu_metric_push.log &          # GPU 가 있는 BM 호스트
bash ops_metric_push.sh --stop
```

객체 생성에는 VCF Operations API 의 `POST /suite-api/api/resources/adapterkinds/{adapterKindKey}` 를 쓴다. 지정한 adapter kind 와 object type 이 Operations 에 없으면 Operations 가 함께 만든다. 만든 객체의 지표는 `POST /suite-api/api/resources/{id}/stats/adapterkinds/{adapterKind}` 로, GPU 수집기의 구성 정보는 `POST /suite-api/api/resources/{id}/properties/adapterkinds/{adapterKind}` 로 보낸다. 이미 있던 객체에는 VM 과 같은 경로(`/stats`, `/properties`)로 보낸다.

### AMD 호스트의 L3 경합 확인 (L1D fill 출처 지표)

ESXi 의 AMD 호스트에서는 LLC occupancy 를 읽을 수 없다. 그래서 L1 data cache 를 채운 데이터가 어디에서 왔는지를 게스트 안에서 센다. 게스트 수집기 4.6 에 이벤트 `dc_fill_l3` 와 지표 세 개를 추가했다.

| 지표 | 계산 | 내용 |
| :-- | :-- | :-- |
| `L1D_Fill_L3` | `dc_fill_l3` 횟수 | 같은 CCX 의 L3 또는 다른 코어의 L2 에서 온 L1D fill 횟수 |
| `L1D_Fill_L3_PTI` | `dc_fill_l3` / instructions × 1000 | 명령어 1000개당 횟수 |
| `L1D_Fill_L3_Pct` | `dc_fill_l3` / `dc_fill_all` × 100 | 전체 L1D fill 중 비율(%) |

- CCX(core complex)는 L3 cache 하나를 함께 쓰는 코어의 묶음이다.
- 이벤트 코드는 PMCx044, unit mask 0x02 이다. Zen 4 와 Zen 5 목록의 이름은 `ls_any_fills_from_sys.local_ccx`, Zen 3 목록의 이름은 `ls_any_fills_from_sys.int_cache` 이다.
- 대상은 Zen 3, Zen 4, Zen 5 이다. Zen 2 에는 넣지 않았다. Zen 2 의 PMCx043 unit mask 0x02 는 같은 die 에 있는 다른 CCX 의 cache 에서 온 fill 도 함께 세기 때문이다. Zen 1 목록에는 출처별 fill 이벤트가 없다.
- L3 경합이 있을 때 예상하는 변화는 다음과 같다. 다른 VM 이 L3 를 사용하는 동안 이 VM 의 `L1D_Fill_L3` 가 줄고, `L1D_Fill_Mem`(DRAM 에서 온 fill)이 비슷한 횟수만큼 늘어난다. 실제 장비에서는 아직 확인하지 않았다.

세 지표는 이름을 지정할 때만 수집하는 줄이다(4.7 부터). `--collect` 없이 실행하거나 `--collect both`, `--collect perf` 로 실행하면 수집하지 않고, 그 실행이 요청하는 이벤트는 4.5 와 같은 여덟 개다. L3 경합을 확인할 때는 아래와 같이 지표 이름을 지정해 실행한다. 이 목록이 요청하는 이벤트는 여섯 개(instructions, cycles, l2_dtlb_miss, dc_fill_mem, l2_miss, dc_fill_l3)다. Zen 코어의 카운터도 여섯 개이므로 multiplexing 이 발생하지 않는다.

```
nohup bash ops_metric_push.sh --collect IPC_Ratio,Instructions,Cycles,L2_DTLB_Miss_PTI,L1D_Fill_Mem_PTI,L2_Miss_PTI,L2_DTLB_Miss,L1D_Fill_Mem,L2_Miss,L1D_Fill_L3_PTI,L1D_Fill_L3 >& /tmp/ops_push.log &          # csh, tcsh
nohup bash ops_metric_push.sh --collect IPC_Ratio,Instructions,Cycles,L2_DTLB_Miss_PTI,L1D_Fill_Mem_PTI,L2_Miss_PTI,L2_DTLB_Miss,L1D_Fill_Mem,L2_Miss,L1D_Fill_L3_PTI,L1D_Fill_L3 > /tmp/ops_push.log 2>&1 &      # bash
```

- 이 실행에는 `--perf-fit` 을 넣지 않는다. `--perf-fit` 은 지표 표에서 뒤에 있는 이벤트부터 제외하므로 `dc_fill_l3` 가 가장 먼저 빠진다.
- 이 목록은 `dc_fill_all` 을 세지 않는다. 그래서 `L1D_Fill_Mem_Pct`, `L1D_Fill_L3_Pct`, `L1D_Fill_All` 은 이 실행에서 비어 있다. 비율이 필요하면 page walk 지표 두 개(`L2_DTLB_Miss_PTI`, `L2_DTLB_Miss`) 대신 `L1D_Fill_All`, `L1D_Fill_Mem_Pct`, `L1D_Fill_L3_Pct` 를 넣는다.
- 로그의 `perf run` 이 100 보다 작으면 VM 이 쓸 수 있는 카운터가 여섯 개보다 적은 것이다. NMI watchdog 이 카운터 하나를 쓰는 경우가 그 예다. 먼저 `sudo sysctl -w kernel.nmi_watchdog=0` 으로 NMI watchdog 을 끈다. 이 설정은 재부팅하면 원래 값으로 돌아간다.
- NMI watchdog 을 끌 수 없으면 목록에서 `L2_DTLB_Miss_PTI` 와 `L2_DTLB_Miss` 를 빼서 이벤트를 다섯 개로 줄인다. `L2_Miss` 는 남긴다. L2 miss 는 L3 로 넘어간 요청 수이므로 두 실행의 조건이 같은지 비교하는 데 쓴다.
- CSV 로도 저장하려면 `--mode both --out 경로` 를 함께 지정한다. Operations 없이 CSV 만 저장하려면 `--mode file --out 경로` 를 지정한다.

호스트 수집기 1.4 에도 같은 이벤트와 지표를 넣었다. 이벤트 파일에서 `dc_fill_l3` 는 맨 끝에 있다. `--events` 없이 시작하면 1.3 과 같은 여섯 이벤트만 시작하고 `L1D_Fill_L3` 지표 세 개는 비어 있다. 호스트에서 세려면 이벤트 키를 여섯 개 이하로 지정한다.

```
nohup python3 vmkperf_ops_push.py start --events cycles,instr,l2_dtlb_miss,dc_fill_mem,l2_miss,dc_fill_l3 > /dev/null 2>&1 &
```

이 지정에서는 `dc_fill_all` 을 시작하지 않으므로 `L1D_Fill_L3_Pct` 는 비어 있다. 비율이 필요하면 `l2_dtlb_miss` 대신 `dc_fill_all` 을 지정한다.

### Intel 호스트의 L3 경합 영향 측정 (게스트 지표)

VM 이 단독으로 실행될 때와 다른 VM 과 함께 실행될 때의 L3 miss 와 대기 시간을 게스트 안에서 비교하기 위한 지표다. 게스트 수집기 4.7 에 perf 이벤트 네 개와 지표 열 개(그룹 `Guest Perf Intel`)를 추가했다. 대상 CPU 는 아래 다섯 세대다. 그 밖의 CPU 에서는 이 지표를 수집하지 않는다.

| CPU 구분 | CPUID family-model | CPU |
| :-- | :-- | :-- |
| `intel_skx` | 6-85 (55h) | Skylake-SP, Cascade Lake-SP, Cooper Lake-SP |
| `intel_icx` | 6-106, 6-108 (6Ah, 6Ch) | Ice Lake-SP, Ice Lake-D |
| `intel_spr` | 6-143 (8Fh) | Sapphire Rapids |
| `intel_emr` | 6-207 (CFh) | Emerald Rapids |
| `intel_gnr` | 6-173, 6-174 (ADh, AEh) | Granite Rapids, Granite Rapids-D |

- CPU 구분은 수집기가 `/proc/cpuinfo` 의 family 와 model 로 정하고 시작 화면의 `CPU class` 줄에 표시한다. model 번호의 출처는 Linux 커널의 `arch/x86/include/asm/intel-family.h` 다.
- 4.6 까지는 모든 Intel CPU 의 구분이 `intel` 이었다. 4.7 부터 위 다섯 세대는 세대 구분으로 표시되고, 그 밖의 Intel CPU 는 종전대로 `intel` 이다. 지표 표의 `cpu=intel` 은 종전대로 모든 Intel CPU 에 적용된다.

| 지표 | 계산 | 내용 |
| :-- | :-- | :-- |
| `LLC_Miss_PTI` | `cache-misses` / instructions × 1000 | 명령어 1000개당 L3 miss 횟수. 코어가 L3 로 보낸 요청 기준 |
| `L3_Load_Miss_PTI` | `l3_load_miss` / instructions × 1000 | 명령어 1000개당, retire 된 load 중 L3 miss 횟수. retire 는 명령의 실행 결과가 확정되는 단계다 |
| `L3_Load_Miss` | `l3_load_miss` 횟수 | 위 지표의 원본 횟수 |
| `L3_Miss_Stall_Pct` | `l3_miss_stall` / cycles × 100 | L3 miss load 를 기다리며 실행이 멈춘 cycle 의 비율(%) |
| `L3_Miss_Stall` | `l3_miss_stall` cycle 수 | 위 지표의 원본 cycle 수 |
| `L3_Miss_Stall_Per_Miss` | `l3_miss_stall` / `l3_load_miss` | L3 miss load 1회당 대기 cycle |
| `DTLB_Walk_Cycles` | `walk_pending` / `dTLB-load-misses` | load 의 page walk 1회당 cycle |
| `DTLB_Walk_Pending` | `walk_pending` 값 | 진행 중인 page walk 수를 cycle 마다 더한 값 |
| `Cycles_Per_RefCycle` | cycles / `ref-cycles` | reference cycle 1개당 core cycle. 두 실행의 동작 주파수가 같은지 확인하는 값 |
| `Ref_Cycles` | `ref-cycles` 값 | 위 지표의 원본 값 |

이 지표가 쓰는 이벤트는 다음과 같다. 코드와 카운터 제약의 출처는 Intel 의 이벤트 목록(github.com/intel/perfmon 의 skylakex 1.37, cascadelakex 1.25, icelakex 1.31, sapphirerapids 1.40, emeraldrapids 1.25, graniterapids 1.21)이다.

| 수집기의 이벤트 이름 | Intel 이벤트 | SKX, ICX 의 코드 | SPR, EMR, GNR 의 코드 | 카운터 |
| :-- | :-- | :-- | :-- | :-- |
| `l3_load_miss` (4.7 추가) | MEM_LOAD_RETIRED.L3_MISS | event 0xd1, umask 0x20 | 같음 | 범용 0~3 |
| `l3_miss_stall` (4.7 추가) | SKX, ICX 는 CYCLE_ACTIVITY.STALLS_L3_MISS. SPR, EMR, GNR 은 MEMORY_ACTIVITY.STALLS_L3_MISS | event 0xa3, umask 0x06, cmask 6 | event 0x47, umask 0x09, cmask 9 | 범용 0~3 |
| `walk_pending` (4.7 추가) | DTLB_LOAD_MISSES.WALK_PENDING | event 0x08, umask 0x10 | event 0x12, umask 0x10 | 범용 0~3 |
| `ref-cycles` (4.7 추가) | CPU_CLK_UNHALTED.REF_TSC | perf 의 일반 이름 | 같음 | 고정 카운터 2 |
| `dTLB-load-misses` | DTLB_LOAD_MISSES.WALK_COMPLETED | event 0x08, umask 0x0e | event 0x12, umask 0x0e | 범용 0~3 |
| `cache-references`, `cache-misses` | LONGEST_LAT_CACHE.REFERENCE, LONGEST_LAT_CACHE.MISS | event 0x2e, umask 0x4f 와 0x41 | 같음 | SKX 는 범용 0~3, ICX 이후는 범용 0~7 |

- model 55h 는 skylakex 목록과 cascadelakex 목록에 나뉘어 있고, 위 코드는 두 목록에서 같다.
- `dTLB-load-misses`, `cache-references`, `cache-misses` 는 perf 의 일반 이름이고 커널이 위 Intel 이벤트로 연결한다(`arch/x86/events/intel/core.c`). `dTLB-load-misses` 의 연결은 게스트 커널이 그 CPU model 을 인식할 때 성립한다. 인식하지 못하는 커널에서는 지원 로그에 unsupported 로 기록되고 `DTLB_Load_Miss` 와 `DTLB_Walk_Cycles` 가 제외된다.
- SPR, EMR, GNR 의 `l3_miss_stall` 은 호스트 수집기의 `l3_stall` 과 같은 이벤트다.
- skylakex 목록은 `walk_pending` 이 EPT page walk 시간을 포함하지 않는다고 적고 있다. 그래서 SKX 게스트의 `DTLB_Walk_Cycles` 는 다른 세대의 값과 비교할 수 없다.
- 범용 카운터 0~3 에서만 계수되는 이벤트가 네 개(`l3_load_miss`, `l3_miss_stall`, `walk_pending`, `dTLB-load-misses`)다. 네 자리를 모두 쓰기 때문에 DTLB_LOAD_MISSES.WALK_ACTIVE 와 MEM_LOAD_RETIRED.L3_HIT 은 넣지 않았다.

열 지표는 이름을 지정할 때만 수집하는 줄이다. `--collect` 없이 실행하면 수집하지 않고, 그 실행이 요청하는 이벤트는 4.6 과 같다. L3 경합 영향을 측정할 때는 아래와 같이 지표 이름을 지정해 실행한다. Operations 에서는 객체의 `Custom Metrics` 아래 `Guest Perf Intel` 그룹에 표시된다(기존 지표는 `Guest Perf Generic` 그룹).

```
nohup bash ops_metric_push.sh --collect IPC_Ratio,Instructions,Cycles,Cache_MissRate_Pct,Cache_Ref,Cache_Miss,LLC_Miss_PTI,L3_Load_Miss_PTI,L3_Load_Miss,L3_Miss_Stall_Pct,L3_Miss_Stall,L3_Miss_Stall_Per_Miss,DTLB_Load_Miss,DTLB_Walk_Pending,DTLB_Walk_Cycles,Ref_Cycles,Cycles_Per_RefCycle >& /tmp/ops_push.log &          # csh, tcsh
nohup bash ops_metric_push.sh --collect IPC_Ratio,Instructions,Cycles,Cache_MissRate_Pct,Cache_Ref,Cache_Miss,LLC_Miss_PTI,L3_Load_Miss_PTI,L3_Load_Miss,L3_Miss_Stall_Pct,L3_Miss_Stall,L3_Miss_Stall_Per_Miss,DTLB_Load_Miss,DTLB_Walk_Pending,DTLB_Walk_Cycles,Ref_Cycles,Cycles_Per_RefCycle > /tmp/ops_push.log 2>&1 &      # bash
```

- 이 목록이 요청하는 이벤트는 고정 카운터를 쓰는 세 개(instructions, cycles, ref-cycles)와 범용 카운터를 쓰는 여섯 개(cache-references, cache-misses, l3_load_miss, l3_miss_stall, dTLB-load-misses, walk_pending)다.
- 이 실행에는 `--perf-fit` 을 넣지 않는다. `--perf-fit` 은 지표 표에서 뒤에 있는 이벤트부터 제외하므로 4.7 에서 추가한 이벤트가 먼저 빠진다.
- multiplexing 여부는 시작 화면의 `multiplexing` 줄과 로그의 `perf run` 값으로 판정한다. `none` 과 `100.00%` 이면 multiplexing 이 없는 것이다.
- 범용 카운터가 네 개뿐인 게스트에서는 LLC 지표 네 개(`Cache_MissRate_Pct`, `Cache_Ref`, `Cache_Miss`, `LLC_Miss_PTI`)를 목록에서 뺀다. 그러면 범용 카운터를 쓰는 이벤트가 네 개가 된다.
- NMI watchdog 은 CPU 마다 cycles 이벤트 하나를 계속 사용한다(커널 `kernel/watchdog_perf.c`). Intel 에서 cycles 이벤트는 고정 카운터 1 을 먼저 배정받고, 그 카운터가 사용 중이면 범용 카운터를 배정받는다(커널 `arch/x86/events/core.c`, `arch/x86/events/intel/core.c`). 그래서 NMI watchdog 이 켜져 있으면 cycles 이벤트 둘 중 하나가 범용 카운터를 쓴다. `perf run` 이 100 보다 작으면 `sudo sysctl -w kernel.nmi_watchdog=0` 으로 NMI watchdog 을 끄고 다시 실행한다. 이 설정은 재부팅하면 원래 값으로 돌아간다.
- 이 실행 시간에는 호스트 수집기(vmkperf)를 시작하지 않는다. 호스트가 사용 중인 물리 카운터는 게스트에서 쓸 수 없다(Broadcom KB 344161).
- KB 344161 은 호스트가 고정 cycle 카운터를 사용 중이면 게스트의 cycles 가 reference cycle 을 셀 수 있다고 적고 있다. 그 경우 `Cycles_Per_RefCycle` 이 부하와 관계없이 1.00 근처로 나온다.
- 목록의 지표 가운데 이 CPU 에 해당하지 않는 것이 있으면 수집기가 시작할 때 `[WARN]` 줄로 이름을 알리고 그 CSV 칸을 비워 둔다. 해당하는 지표가 하나도 없으면 `[ERROR]` 를 출력하고 종료한다.
- L3 경합이 있을 때 예상하는 변화는 다음과 같다. 단독 실행보다 2대 실행에서 `L3_Load_Miss_PTI`, `LLC_Miss_PTI`, `L3_Miss_Stall_Pct` 가 늘어난다. `L3_Miss_Stall_Per_Miss` 만 늘면 miss 횟수가 아니라 miss 1회의 대기 시간이 늘어난 것이다. 실제 장비에서는 아직 확인하지 않았다.
- ESXi 게스트의 가상 카운터에서 4.7 의 이벤트 네 개가 계수되는지, 게스트에 범용 카운터가 몇 개 보이는지는 실제 게스트에서 확인해야 한다. 지원 로그(`/tmp/ops_metric_push_support.log`)의 `supported` 줄에 이벤트별 0.2초 시험의 계수 값이 기록된다.

## 3. 버전 관리

- 파일 이름에 버전을 넣지 않는다. 버전은 스크립트 안의 `SCRIPT_VERSION`(셸)과 `VERSION`(Python)에 있고 시작 화면에 표시된다.
- 변경할 때마다 그 값을 올리고 아래 표에 한 줄을 추가한 뒤 커밋한다.
- 릴리스 커밋에는 `ops_metric_push-v4.4` 형식의 Git 태그를 지정한다. 예전 판은 `git checkout <태그> -- <파일>` 로 꺼낸다. 예: `git checkout ops_metric_push-v4.4 -- ops_metric_push.sh`

| 날짜 | 수집기 | 버전 | 변경 내용 |
| :-- | :-- | :-- | :-- |
| 2026-11-12 | `ops_metric_push.sh` | 4.4 | 접속 설정을 `ops_local.conf` 로 분리. 수집 동작은 4.3 과 같음 |
| 2026-11-12 | `gpu_metric_push.sh` | 1.1 | 접속 설정을 `ops_local.conf` 로 분리. 수집 동작은 1.0 과 같음 |
| 2026-11-12 | `vmkperf_ops_push.py` | 1.3 | 접속 설정을 `ops_local.conf` 로 분리. `--cred-from` 삭제. `OPS_HOST` 에 `http(s)://` 주소 허용. 수집 동작은 1.2 와 같음 |
| 2026-11-12 | `ops_metric_push.sh` | 4.5 | BM 호스트 대상 `--target bm` 추가. Operations 에 객체가 없으면 객체를 만들고 전송. `--adapter-kind`, `--resource-kind` 추가. `--target vm`, `--target any` 와 파일 모드 동작은 4.4 와 같음 |
| 2026-11-12 | `gpu_metric_push.sh` | 1.2 | `--target`(vm, bm), `--name`, `--adapter-kind`, `--resource-kind` 추가. BM 호스트에서 객체가 없으면 객체를 만들고 지표와 구성 정보를 전송. 시작 화면의 target 줄 형식 변경. 수집 동작은 1.1 과 같음 |
| 2026-11-12 | `ops_metric_push.sh` | 4.6 | AMD Zen 3, Zen 4, Zen 5 용 이벤트 `dc_fill_l3`(PMCx044 unit mask 0x02)와 지표 `L1D_Fill_L3_PTI`, `L1D_Fill_L3_Pct`, `L1D_Fill_L3` 추가. 지표 표의 맨 끝에 추가해 4.5 의 CSV 열 위치와 `--perf-fit` 결과는 그대로임. `--perf-fit` 없이 실행하면 Zen 3, Zen 4, Zen 5 에서 요청 이벤트가 8개에서 9개로 늘어남. 그 밖의 동작은 4.5 와 같음 |
| 2026-11-12 | `ops_metric_push.sh` | 4.7 | Intel 게스트의 L3 경합 영향 지표 추가: 이벤트 `l3_load_miss`, `l3_miss_stall`, `walk_pending`, `ref-cycles` 와 그룹 `Guest Perf Intel` 의 지표 10개. Intel CPU 구분 `intel_skx`, `intel_icx`, `intel_spr`, `intel_emr`, `intel_gnr` 추가(이 다섯 세대에서 시작 화면과 지원 로그의 CPU class 표시가 `intel` 에서 세대 구분으로 바뀜. `cpu=intel` 은 종전대로 모든 Intel CPU). 이름을 지정할 때만 수집하는 줄(`collect=named`) 추가: 새 Intel 지표 10개와 4.6 의 `L1D_Fill_L3` 지표 3개가 해당. `--collect` 없이 실행할 때의 요청 이벤트는 Intel 에서 4.6 과 같고, AMD Zen 3, Zen 4, Zen 5 에서는 4.5 와 같은 8개임(4.6 은 9개). `--collect` 에 다른 CPU 의 지표 이름을 적으면 경고를 출력하고, 해당하는 지표가 하나도 없으면 오류로 종료. CSV 는 4.6 의 열 뒤에 10열 추가. 시작 화면의 collect 줄과 metrics 줄의 개수 표시가 바뀜 |
| 2026-11-12 | `vmkperf_ops_push.py` | 1.4 | AMD Zen 3, Zen 4, Zen 5 이벤트 파일(`milan.json`, `genoa.json`, `turin.json`)의 맨 끝에 `dc_fill_l3` 추가. `metrics_amd.json` 의 맨 끝에 `L1D_Fill_L3`, `L1D_Fill_L3_PTI`, `L1D_Fill_L3_Pct` 추가. `--events` 없이 시작하는 이벤트는 1.3 과 같음. Zen 1, Zen 2, Intel 의 이벤트 파일은 그대로임 |

Git 에 올리기 전의 판은 이 저장소에 없다. 게스트 수집기 4.2 에서 perf 를 한 번만 실행하는 방식과 multiplexing 표시, `--perf-fit` 을 넣었고, 4.3 과 호스트 수집기 1.2 에서 AMD Zen 1~5 이벤트를 넣었다.

## 4. 수집 지표 목록

수집기별로 어떤 지표를 수집하는지는 `METRICS.md` 에 있다. 이 파일은 `tools/gen_metrics.py` 가 수집기 코드에서 만든다.

- 수집기의 지표 표나 `events/*.json` 을 바꾼 커밋에서는 `python3 tools/gen_metrics.py` 를 실행하고 `METRICS.md` 를 함께 커밋한다.
- `python3 tools/gen_metrics.py --check` 는 `METRICS.md` 가 코드와 같은지만 확인한다.
- 호스트 수집기 항목의 수집 여부는 수집기의 카운터 배치 함수로 계산한 값이다. 실제 호스트에서는 `check` 결과와 시작 로그의 `SKIPPED` 줄로 확인한다.

## 5. 로컬 시험

`tests/` 에는 실제 perf, vmkperf 없이 수집기의 처리 흐름을 확인하는 도구(가짜 perf, ESXi 명령 흉내, Operations 흉내 서버)가 있다. 사용법은 `tests/README.md` 에 있다.

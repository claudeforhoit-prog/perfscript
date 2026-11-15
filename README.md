# Ops 수집기 (ops_push)

> 수집기를 고치거나 AI 로 다시 만들 때는 `DEVELOPER.md`(구조, 설계 규칙, 시험)를 먼저 읽는다.

VCF Operations 로 사용자 지표를 전송하는 수집기 세 개를 관리하는 폴더다. 접속 주소와 계정, 비밀번호는 스크립트에 넣지 않고 설정 파일 `ops_local.conf` 에서 읽는다.

| 파일 | 실행 위치 | 수집 내용 | 버전 |
| :-- | :-- | :-- | :-- |
| `ops_metric_push.sh` | 게스트 OS, BM 호스트 | perf 지표와 THP 지표 | 4.8 |
| `gpu_metric_push.sh` | GPU 를 DirectPath I/O 로 할당받은 게스트 OS, GPU 가 있는 BM 호스트 | nvidia-smi 지표 | 1.2 |
| `vmkperf_ops_push/vmkperf_ops_push.py` | ESXi 호스트 | vmkperf 지표 | 1.5 |

## 0. 저장소 구성

| 폴더 · 파일 | 내용 | 설명 문서 |
| :-- | :-- | :-- |
| `ops_metric_push.sh`, `gpu_metric_push.sh`, `vmkperf_ops_push/` | Ops 수집기 3종 | 이 문서, `METRICS.md` |
| `vm_config/` | VM 실행 설정, VM 순차 기동, CAT 설정 | `SCRIPTS.md` |
| `cpu_affinity/` | VM 배포 계획, vCPU affinity, vCPU 배치 수집 | `SCRIPTS.md` |
| `collection_etc/` | 구성 스냅샷, 게스트 구성 기록, phase 추출, 메모리 맵 수집 | `SCRIPTS.md` |
| `common/`, `mmap_align/` | 접속 정보 일괄 설정, mmap 정렬 라이브러리 | `SCRIPTS.md` |
| `DEVELOPER.md`, `tests/`, `tools/` | 개발 지침, 시험 도구, 지표 목록 생성 | `DEVELOPER.md` |

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

### 수집 지표와 AMD CPU 에서의 동작

게스트 수집기 4.8 과 호스트 수집기 1.5 가 수집하는 지표는 처음 설계한 판(게스트 수집기 4.1, 호스트 수집기 1.0)과 같다.

| 수집기 | 지표 수 | 구성 | 정의 위치 |
| :-- | :-- | :-- | :-- |
| `ops_metric_push.sh` | 26 | Guest Perf Generic 12개, Guest Perf Extended 5개, Guest THP 9개 | 스크립트의 지표 표(METRIC TABLE) |
| `vmkperf_ops_push.py` | 15 | LLC 지표, L3 지표, Cycles, Instructions, IPC | `events/metrics.json` |

- 지표 이름과 계산식 전체는 `METRICS.md` 에 있다.
- 게스트 수집기 4.2 부터 4.7 까지와 호스트 수집기 1.1 부터 1.4 까지에는 AMD 전용 지표와 Intel L3 지표가 더 있었다. 4.8 과 1.5 에서 이 지표를 모두 뺐다. 그 판들은 Git 태그로 남아 있다.

게스트 수집기는 지표 표에 적힌 perf 이벤트 이름 12개를 CPU 종류와 관계없이 그대로 요청한다. AMD CPU 에서는 게스트의 커널이 그 이름을 AMD 이벤트로 연결하고, 연결되는 이벤트가 Intel 과 다르다. 아래 표는 Linux 커널 `arch/x86/events/amd/core.c` 의 family 17h 이상용 표에서 확인한 내용이다.

| perf 이벤트 이름 | AMD 에서 연결되는 이벤트 | 이 이벤트를 쓰는 지표 |
| :-- | :-- | :-- |
| `cycles`, `instructions` | PMCx076, PMCx0C0 | `IPC_Ratio`, `Cycles`, `Instructions`. Intel 과 뜻이 같음 |
| `cache-references` | PMCx060, unit mask 0xff. L2 cache 요청 | `Cache_Ref`, `Cache_MissRate_Pct` |
| `cache-misses` | PMCx064, unit mask 0x09. L2 cache miss | `Cache_Miss`, `Cache_MissRate_Pct` |
| `L1-dcache-loads` | PMCx040. data cache 접근 | `L1D_Loads`, `L1D_MissRate_Pct` |
| `L1-dcache-load-misses` | PMCx060, unit mask 0xc8. data cache miss 로 생긴 L2 접근 | `L1D_Load_Miss`, `L1D_MissRate_Pct` |
| `dTLB-loads` | PMCx045, unit mask 0xff. L1 DTLB miss | `DTLB_Loads`, `DTLB_MissRate_Pct` |
| `dTLB-load-misses` | PMCx045, unit mask 0xf0. L2 DTLB miss(page walk) | `DTLB_Load_Miss`, `DTLB_MissRate_Pct` |
| `iTLB-loads` | PMCx084. L1 ITLB miss 가운데 L2 ITLB hit | `ITLB_Loads`, `ITLB_MissRate_Pct` |
| `iTLB-load-misses` | PMCx085, unit mask 0xff. L1 ITLB miss 가운데 L2 ITLB miss | `ITLB_Load_Miss`, `ITLB_MissRate_Pct` |
| `LLC-load-misses`, `LLC-store-misses` | 연결 없음 | `LLC_Load_Miss`, `LLC_Store_Miss`. 시작할 때 지원 판정에서 빠짐 |

- AMD 게스트의 `Cache_Ref`, `Cache_Miss`, `Cache_MissRate_Pct` 는 L2 cache 값이다. `DTLB_Loads` 와 `ITLB_Loads` 는 첫 단계 TLB 의 miss 횟수다. 같은 이름의 Intel 값과 비교할 수 없다.
- 실제 AMD 게스트에서 어느 이벤트가 지원되는지는 지원 로그(`/tmp/ops_metric_push_support.log`)에 기록된다. 실제 게스트에서는 아직 확인하지 않았다.
- AMD Zen 코어에는 카운터가 6개 있고 고정 카운터가 없다. 요청 이벤트가 카운터보다 많으므로 `--perf-fit` 없이 실행하면 multiplexing 이 발생한다. Intel 에서도 범용 카운터를 쓰는 이벤트가 10개여서 multiplexing 이 발생한다. 두 경우 모두 4.1 과 같다.

호스트 수집기의 지표 15개는 이벤트 키 9개를 쓴다. 이 가운데 AMD core 카운터에 있는 것은 `cycles` 와 `instr` 두 개다. LLC 이벤트와 L3 이벤트는 AMD 에서 core 카운터가 아닌 L3 PMU 에 있다. 그래서 AMD 호스트의 이벤트 파일(`naples.json`, `rome.json`, `milan.json`, `genoa.json`, `turin.json`)에는 이 두 이벤트만 있다.

- AMD 호스트에서는 `Cycles`, `Instructions`, `IPC` 만 값이 있다. 나머지 12개는 입력 이벤트가 없어 CSV 칸이 비어 있고 Operations 로 전송되지 않는다.
- `check` 와 시작 로그가 입력 이벤트가 없는 지표의 이름을 표시한다.
- 실제 AMD 호스트의 vmkperf 에서는 아직 확인하지 않았다.

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
| 2026-11-12 | `ops_metric_push.sh` | 4.8 | 수집 지표를 설계 판(4.1)의 26개로 되돌림. 지표 표가 4.1 과 같음. 4.2 부터 4.7 까지 추가한 `Guest Perf AMD` 지표 19개와 `Guest Perf Intel` 지표 10개, 캐시와 TLB 지표 14개에 있던 AMD 제외 조건, 이벤트 코드 표의 줄을 모두 뺌. 모든 CPU 에서 perf 이벤트 이름 12개를 요청함(AMD 게스트 포함). CSV 의 지표 열은 26개. 구간 로그 요약 줄에서 `L2_DTLB_Miss_PTI` 를 뺌. perf 상주 방식, multiplexing 표시, `--perf-fit`, 설정 파일, `--target bm`, CPU class 표시는 4.7 과 같음 |
| 2026-11-12 | `vmkperf_ops_push.py` | 1.5 | 수집 지표를 설계 판(1.0)의 15개로 되돌림. 지표 파일은 `events/metrics.json` 하나이고 `metrics_amd.json`, `metrics_amd_zen2.json` 을 뺌. AMD 이벤트 파일 5개에는 설계 판의 이벤트 키 가운데 AMD core 카운터에 있는 `cycles`, `instr` 만 둠. AMD 호스트에서는 `Cycles`, `Instructions`, `IPC` 만 값이 있고 나머지 12개는 비어 있음. `probe`, `worldprobe` 는 다른 이벤트가 없는 이벤트 파일에서 `cycles`, `instr` 을 사용. Intel 호스트의 동작과 설정 파일 방식은 1.4 와 같음 |

Git 에 올리기 전의 판은 이 저장소에 없다. 게스트 수집기 4.2 에서 perf 를 한 번만 실행하는 방식과 multiplexing 표시, `--perf-fit` 을 넣었다. 4.2 와 4.3, 호스트 수집기 1.1 과 1.2 에서 넣은 AMD 전용 지표는 4.8 과 1.5 에서 뺐다. 설계 판인 게스트 수집기 4.1 과 호스트 수집기 1.0 도 이 저장소에 없다.

## 4. 수집 지표 목록

수집기별로 어떤 지표를 수집하는지는 `METRICS.md` 에 있다. 이 파일은 `tools/gen_metrics.py` 가 수집기 코드에서 만든다.

- 수집기의 지표 표나 `events/*.json` 을 바꾼 커밋에서는 `python3 tools/gen_metrics.py` 를 실행하고 `METRICS.md` 를 함께 커밋한다.
- `python3 tools/gen_metrics.py --check` 는 `METRICS.md` 가 코드와 같은지만 확인한다.
- 호스트 수집기 항목의 수집 여부는 수집기의 카운터 배치 함수로 계산한 값이다. 실제 호스트에서는 `check` 결과와 시작 로그의 `SKIPPED` 줄로 확인한다.

## 5. 로컬 시험

`tests/` 에는 실제 perf, vmkperf 없이 수집기의 처리 흐름을 확인하는 도구(가짜 perf, ESXi 명령 흉내, Operations 흉내 서버)가 있다. 사용법은 `tests/README.md` 에 있다.

# 수집기 로컬 시험 도구

실제 perf, vmkperf 없이 수집기의 동작을 Mac 이나 Linux(bash 3.2 이상)에서 확인할 때 쓴다. `tests/` 폴더에서 실행한다.

| 파일 | 용도 |
| :-- | :-- |
| `fake_perf_bin/perf` | 가짜 `perf stat`. perf-stat 설명서의 `-x` 출력 형식과 `-I` 구간 출력을 재현한다. 환경 변수로 카운터 수(`FAKE_PERF_GP`), 고정 카운터 이벤트(`FAKE_PERF_FIXED`), 미지원 이벤트, 옛 출력 형식, `-I` 미지원, 종료, 무응답, 지연을 만든다. 파일 첫머리에 변수 목록이 있다 |
| `proc_intel/`, `proc_amd/` | `/proc` 대신 쓰는 폴더(cpuinfo, meminfo, vmstat). `OPS_PUSH_PROC_ROOT` 로 지정한다. `proc_amd` 는 family 26, model 2(Zen 5)이다 |
| `mkproc.sh` | 원하는 CPUID family, model 의 `/proc` 대용 폴더를 새로 만든다. `./mkproc.sh AuthenticAMD 25 17 /tmp/opstest/proc_25-17` 처럼 쓴다. AMD 세대별(Zen 1~5) 시험에 사용한다 |
| `run_guest.sh` | 게스트 수집기를 가짜 perf 로 N초 실행하고 중지한 뒤 로그와 CSV 를 보여 준다. 출력 폴더는 `/tmp/opstest/<이름>_<시각>`. 시험할 수집기 파일은 환경 변수 `COLLECTOR` 로 지정한다(기본값 `../ops_metric_push.sh`) |
| `fake_ops.py` | VCF Operations suite-api 흉내 서버(토큰, 객체 조회와 생성, stats 와 properties 수신). `python3 fake_ops.py <기록 폴더> <포트>`. 기록 폴더에 `preset.json` 을 두면 그 안의 객체가 미리 있는 것으로 동작하고, 없으면 VirtualMachine `testvm` 하나만 있다. 빈 파일 `fail_create` 를 두면 객체 생성을 거부(403)하고, `fail_lookup` 을 두면 객체 조회가 실패(500)한다. 받은 요청은 `requests.jsonl`, 지표는 `stats.jsonl`, 전송 경로는 `stats_paths.jsonl` 과 `props_paths.jsonl`, 만든 객체는 `created.jsonl` 에 기록한다 |
| `run_guest_config.sh` | `collection_etc/guest_config_push.sh` 를 `fake_ops.py` 에 연결해 실행하고 흉내 서버가 받은 내용을 확인한다: VM 대상, BM 대상(객체 사용과 생성), `--target auto`, `--check`, `--dry-run`, 설정 파일, 실패 경우, jq 경로. `bash run_guest_config.sh [포트]`. 확인 항목마다 한 줄을 출력하고 실패가 있으면 종료 코드가 1 이다. `/sys`, `/proc` 대신 읽을 폴더는 환경 변수 `GCP_ROOT` 로 지정한다(시험 전용) |
| `stub_esxi_bin/vmkperf`, `esxcli` | ESXi 의 vmkperf, esxcli 흉내. `STUB_VENDOR`, `STUB_GP`, `STUB_FAMILY`, `STUB_MODEL` 로 호스트 종류를 정한다 |
| `cpu_affinity_model.py` | `cpu_affinity/` 의 PowerShell 스크립트 2개(`SetVcpuAffinityProfile_v3_10.ps1`, `VmDeployPlan_v1_1.ps1`)의 계산부를 Python 으로 옮긴 모델과 점검. `python3 cpu_affinity_model.py` 로 실행하고 마지막 줄이 `RESULT: 전체 통과` 이면 정상이다. 테스트 플랜 시트의 기록 값, 이전 판(3.9)과 값이 달라지는 조건, 계획표와 적용 스크립트의 값 일치, `Test-VmDeployPlan` 사례의 기대값을 점검한다. PowerShell 스크립트 자체를 실행하지는 않으므로, 스크립트를 고치면 PowerShell 이 있는 PC 에서 `Test-VmDeployPlan` 도 실행한다 |

예:

```
mkdir -p /tmp/opstest/c1
./run_guest.sh intel_fit 36 FAKE_PERF_GP=4 -- --mode file --out /tmp/opstest/c1 --interval 10 --perf-fit
PROC=$PWD/proc_amd ./run_guest.sh amd 36 FAKE_PERF_GP=6 FAKE_PERF_FIXED= -- --mode file --out /tmp/opstest/c1 --interval 10
env PATH=$PWD/stub_esxi_bin:$PATH STUB_STATE=/tmp/vktest/s1 STUB_VENDOR=amd STUB_GP=6 STUB_FAMILY=26 STUB_MODEL=2 \
    python3 ../vmkperf_ops_push/vmkperf_ops_push.py check --mode file
./mkproc.sh AuthenticAMD 23 49 /tmp/opstest/proc_23-49
PROC=/tmp/opstest/proc_23-49 ./run_guest.sh zen2 36 FAKE_PERF_GP=6 FAKE_PERF_FIXED= -- --mode file --out /tmp/opstest/c1 --interval 10
```

`proc_intel` 은 family 6, model 143(Sapphire Rapids)이다. 다른 CPU 는 `mkproc.sh` 로 만든다(예: Granite Rapids 6-173, AMD Zen 4 는 AuthenticAMD 25-17). 4.8 의 지표 표는 CPU 와 관계없이 perf 이벤트 이름 12개를 요청하므로, 어느 `/proc` 대용 폴더로 실행해도 요청 이벤트가 같다.

```
./mkproc.sh GenuineIntel 6 173 /tmp/opstest/proc_6-173
PROC=/tmp/opstest/proc_6-173 ./run_guest.sh gnr 36 FAKE_PERF_GP=8 -- --mode file --out /tmp/opstest/c1 --interval 10 \
    --collect IPC_Ratio,Instructions,Cycles,Cache_MissRate_Pct,DTLB_Load_Miss
```

- 가짜 perf 가 고정 카운터로 처리하는 이벤트의 기본값은 `cycles,instructions,ref-cycles` 다(4.7 부터 `ref-cycles` 포함). AMD 시험에서는 `FAKE_PERF_FIXED=` 로 비운다.
- 가짜 perf 는 범용 카운터의 개수만 흉내 낸다. 이벤트마다 쓸 수 있는 카운터가 정해져 있는 제약은 흉내 내지 않으므로, 그 제약 때문에 생기는 multiplexing 은 이 도구로 확인되지 않는다.
- 가짜 perf 는 이벤트 이름을 CPU 에 따라 다르게 처리하지 않는다. AMD 커널이 지원하지 않는 이름(`LLC-load-misses`, `LLC-store-misses`)을 흉내 내려면 `FAKE_PERF_UNSUP=LLC-load-misses,LLC-store-misses` 를 지정한다.
- 수집기를 멈추는 시각이 수집 간격의 경계와 겹치면 `perf is not running any more` 경고와 perf 값이 빈 행이 하나 기록된다. 중지 과정에서 perf 가 먼저 끝나기 때문이다. 시험 결과를 비교할 때는 실행 시간을 바꿔 다시 실행한다.

BM 대상(`--target bm`) 시험 예. `test.conf` 는 `OPS_HOST=http://127.0.0.1:18097` 과 시험용 계정, 키, 암호문을 넣은 설정 파일이다.

```
mkdir -p /tmp/opstest/ops1
python3 fake_ops.py /tmp/opstest/ops1 18097 &
./run_guest.sh bm 40 -- --config /tmp/opstest/test.conf --target bm --name bm-node01 --interval 10
cat /tmp/opstest/ops1/created.jsonl /tmp/opstest/ops1/stats_paths.jsonl
```

이 도구로 확인되는 것은 수집기의 처리 흐름과 계산이다. 실제 perf 의 출력, 게스트 vPMU, 실제 vmkperf 의 동작은 장비에서 확인해야 한다.

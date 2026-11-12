# 수집기 로컬 시험 도구

실제 perf, vmkperf 없이 수집기의 동작을 Mac 이나 Linux(bash 3.2 이상)에서 확인할 때 쓴다. `tests/` 폴더에서 실행한다.

| 파일 | 용도 |
| :-- | :-- |
| `fake_perf_bin/perf` | 가짜 `perf stat`. perf-stat 설명서의 `-x` 출력 형식과 `-I` 구간 출력을 재현한다. 환경 변수로 카운터 수(`FAKE_PERF_GP`), 고정 카운터 이벤트(`FAKE_PERF_FIXED`), 미지원 이벤트, 옛 출력 형식, `-I` 미지원, 종료, 무응답, 지연을 만든다. 파일 첫머리에 변수 목록이 있다 |
| `proc_intel/`, `proc_amd/` | `/proc` 대신 쓰는 폴더(cpuinfo, meminfo, vmstat). `OPS_PUSH_PROC_ROOT` 로 지정한다. `proc_amd` 는 family 26, model 2(Zen 5)이다 |
| `mkproc.sh` | 원하는 CPUID family, model 의 `/proc` 대용 폴더를 새로 만든다. `./mkproc.sh AuthenticAMD 25 17 /tmp/opstest/proc_25-17` 처럼 쓴다. AMD 세대별(Zen 1~5) 시험에 사용한다 |
| `run_guest.sh` | 게스트 수집기를 가짜 perf 로 N초 실행하고 중지한 뒤 로그와 CSV 를 보여 준다. 출력 폴더는 `/tmp/opstest/<이름>_<시각>`. 시험할 수집기 파일은 환경 변수 `COLLECTOR` 로 지정한다(기본값 `../ops_metric_push.sh`) |
| `fake_ops.py` | VCF Operations suite-api 흉내 서버(토큰, 객체 조회와 생성, stats 와 properties 수신). `python3 fake_ops.py <기록 폴더> <포트>`. 기록 폴더에 `preset.json` 을 두면 그 안의 객체가 미리 있는 것으로 동작하고, 없으면 VirtualMachine `testvm` 하나만 있다. 빈 파일 `fail_create` 를 두면 객체 생성을 거부(403)하고, `fail_lookup` 을 두면 객체 조회가 실패(500)한다. 받은 요청은 `requests.jsonl`, 지표는 `stats.jsonl`, 전송 경로는 `stats_paths.jsonl` 과 `props_paths.jsonl`, 만든 객체는 `created.jsonl` 에 기록한다 |
| `stub_esxi_bin/vmkperf`, `esxcli` | ESXi 의 vmkperf, esxcli 흉내. `STUB_VENDOR`, `STUB_GP`, `STUB_FAMILY`, `STUB_MODEL` 로 호스트 종류를 정한다 |

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

BM 대상(`--target bm`) 시험 예. `test.conf` 는 `OPS_HOST=http://127.0.0.1:18097` 과 시험용 계정, 키, 암호문을 넣은 설정 파일이다.

```
mkdir -p /tmp/opstest/ops1
python3 fake_ops.py /tmp/opstest/ops1 18097 &
./run_guest.sh bm 40 -- --config /tmp/opstest/test.conf --target bm --name bm-node01 --interval 10
cat /tmp/opstest/ops1/created.jsonl /tmp/opstest/ops1/stats_paths.jsonl
```

이 도구로 확인되는 것은 수집기의 처리 흐름과 계산이다. 실제 perf 의 출력, 게스트 vPMU, 실제 vmkperf 의 동작은 장비에서 확인해야 한다.

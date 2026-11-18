# 스크립트 명세 (Ops 수집기 외)

이 문서는 Ops 수집기 3종(`README.md`) 외의 스크립트를 폴더별로 정리한 명세다. 스크립트마다 용도, 실행 위치, 실행 방법, 옵션과 기본값을 적는다.
옵션과 기본값은 각 스크립트의 옵션 처리 코드(`param`, `getopts`, `case`)에서 뽑았다. 옵션의 자세한 동작은 각 스크립트 첫머리 설명에 있다.

- 파일은 2026-10-27 도구 패키지 v1.5 와 그 뒤 작업 폴더의 최신 판이다. 파일 이름의 판 번호는 원래 이름 그대로 두었다.
- 접속 주소, 계정, 장비 이름은 예시 값(`esx01`, `ops.example.com`, `user01`, `192.0.2.50`)으로 바꿔 올렸다. 실제 값은 실행 환경에서 넣는다.
- `.ps1` 은 Windows PowerShell 에서 `Connect-VIServer` 로 vCenter 에 연결한 뒤 `. .\파일.ps1` 로 불러와 함수를 실행한다(예외는 표에 적음).

## 1. 전체 목록

| 폴더 | 파일 | 판 | 실행 위치 | 용도 |
| :-- | :-- | :-- | :-- | :-- |
| `common/` | `set_credentials.sh` | 도구 패키지 v1.5 | 패키지 폴더가 있는 Linux, ESXi 셸 | 패키지 안 스크립트의 Operations 주소, 계정, 암호문, 암호화 키 일괄 설정 |
| `vm_config/` | `SetVmProfile_v1_1.ps1` | 1.1 | PowerCLI | VM 실행 설정 적용과 점검(VM_TYPE 태그, 1GB large page, 메모리 예약, shares, 토폴로지) |
| `vm_config/` | `StartVmsSequential_v1_4.ps1` | 1.4 | PowerCLI | 호스트별로 VM 을 하나씩 순서대로 켬(전원 켜기 작업 완료 기준) |
| `vm_config/` | `StartVmsWithBackingGate_v1_3.ps1` | 1.3 (이전 판) | PowerCLI + ESXi SSH | VM 을 하나씩 켜고 1GB page backing 완료를 확인한 뒤 다음 VM 으로 진행 |
| `vm_config/` | `start_vms_lpage_gate_v1_0.sh` | 1.0 | ESXi 셸 | 위와 같은 일을 ESXi 안에서만 수행(vsish 로 1GB backing 확인) |
| `vm_config/` | `CheckVmRunSettings_v2_0.ps1` | 2.0 | PowerCLI | 호스트의 VM 실행 설정을 그룹별 표로 조회(스펙, affinity, 메모리 등) |
| `vm_config/` | `set_cat_qos_v1_10.sh` | 1.10 | ESXi 셸 | CAT(LLC way 분할) 프로파일 적용과 Operations 기록 |
| `cpu_affinity/` | `VmDeployPlan_v1_0.ps1` | 1.0 | PowerShell (vCenter 불필요) | 호스트 사양과 VM 크기를 입력받아 VM 스펙, 고급 설정, CPU affinity 값을 표로 산출 |
| `cpu_affinity/` | `SetVcpuAffinityProfile_v3_9.ps1` | 3.9 | PowerCLI | vCPU affinity 프로파일 적용 |
| `cpu_affinity/` | `collect_vcpu_placement_v1_0.sh` | 1.0 | ESXi 셸 | vCPU 가 실행되는 pCPU 와 NUMA locality 기록(읽기 전용) |
| `cpu_affinity/` | `taskset_pin_primesim.sh` | 판 표기 없음 | 게스트 OS | PrimeSim 프로세스를 잡 단위 또는 스레드 단위로 vCPU 에 고정 |
| `collection_etc/` | `config_snapshot_v1_1.ps1` | 1.1 | PowerCLI | 테스트 전 구성 스냅샷(호스트 고급 설정, VM 스펙, ExtraConfig, 게스트 값, CAT 값) |
| `collection_etc/` | `guest_config_push.sh` | 1.1 | 게스트 OS, BM 호스트 | OS 구성값을 Operations 의 VM 속성 또는 BM 호스트 객체의 속성으로 기록 |
| `collection_etc/` | `Export-EsxiSettingsReference_v1_0.ps1` | 1.0 | PowerCLI | ESXi Advanced Settings 와 Kernel Settings 전체를 md, csv 로 내보냄 |
| `collection_etc/` | `primesim_phase_syslog_v4.4.sh` | 4.4 | 게스트 OS | PrimeSim output 로그에서 단계별 elapsed 를 뽑아 syslog 전송 또는 CSV 저장 |
| `collection_etc/` | `prs_maps_monitor_v1.03.sh` | 1.03 | 게스트 OS | 프로세스의 maps, smaps, numa_maps 주기 수집 |
| `collection_etc/` | `jemalloc_check.sh` | 판 표기 없음 | 게스트 OS | 실행 중인 잡 프로세스에 jemalloc 이 적용됐는지 점검 |
| `mmap_align/` | `mmap_align.c`, `build_and_test.sh` | 판 표기 없음 | 게스트 OS | 큰 익명 mmap 을 2 MB 경계로 정렬하는 LD_PRELOAD 라이브러리. 설명은 `mmap_align/README.md` |

## 2. common

### set_credentials.sh

- 실행: `sh set_credentials.sh [옵션]`. 지정하지 않은 값은 대화형으로 입력받는다.
- 대상: 패키지 폴더 안 `.sh`, `.py`, `.ps1` 의 접속 변수 대입 줄. Ops 수집기 3종은 `ops_local.conf` 를 쓰므로 대상이 아니다.

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `-d DIR` | 스크립트가 있는 폴더 | 패키지 폴더 |
| `--ops-host H` | 입력받음 | Operations 주소 |
| `--ops-user U` | 입력받음 | Operations LOCAL 계정 |
| `--enc-key K` | 입력받음 | 암호화 키 |
| `--pass-enc ENC` | 없음 | 이미 만든 암호문 사용 |
| `--check` | 꺼짐 | 변경 없이 파일별 현재 상태만 출력 |
| `--no-backup` | 꺼짐 | 교체 전 `.bak` 백업 생략 |

## 3. vm_config

### SetVmProfile_v1_1.ps1

함수 세 개를 쓴다. 대상은 `-VMHostName`(호스트) 또는 `-VMName`(VM)으로 지정한다. affinity 키는 바꾸지 않는다.

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Set-VmType` | `-VMHostName`, `-VMName`, `-Type`(필수), `-Dept`(빈 값이면 설정 블록 기본값), `-Purpose`(같음), `-TypeOnly`, `-CreateAttributes` |
| `Set-VmProfile` | `-VMHostName`, `-VMName`, `-Default`, `-Role`, `-Sockets`(0), `-CoresPerSocket`(0), `-Cpu`(0), `-MemoryGB`(0), `-ShareRatio`, `-CpuShares`(-1), `-MemShares`(-1), `-SharesLevel`, `-MemFullReservation`, `-ExtraConfig`(@{}), `-Lpage1GB`, `-RemoveExtraConfig`, `-ResetAdvanced`, `-Dept`, `-Purpose`, `-AttributesOnly`, `-TagPvm`, `-TagSvm`, `-CreateAttributes`, `-ShowUnchanged`, `-PassThru`, `-Detail` |
| `Test-VmProfile` | `-VMHostName`, `-VMName`, `-PassThru` |

숫자 옵션의 0 과 -1 은 '지정하지 않음' 이다. 지정한 항목만 적용한다.

### StartVmsSequential_v1_4.ps1

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Start-VmsSequential` | `-VMHostName`(필수), `-VMName`, `-All`, `-NamePattern`(`*`), `-Exclude`, `-Gate`(`PowerOn`), `-PollSeconds`(5), `-TaskTimeoutMinutes`(90), `-ToolsTimeoutMinutes`(20), `-ContinueOnIncomplete`, `-Require1GPage`, `-PassThru` |
| `Get-VmHostMemStatus` | `-VMHostName`(필수), `-VMName`, `-PassThru` |

### StartVmsWithBackingGate_v1_3.ps1 (이전 판)

`StartVmsSequential` 의 이전 이름이다. ESXi 에 SSH 로 접속해 1GB backing 수를 확인하는 방식이 필요할 때만 쓴다.

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Start-VmsWithBackingGate` | `-VMHostName`(필수), `-VMName`, `-All`, `-NamePattern`(`*`), `-Exclude`, `-Gate`(`Lpage`), `-ToolsTimeoutMinutes`(20), `-LpageCompletePercent`(100), `-LpageStallSamples`(6), `-EsxiSshHost`, `-EsxiSshUser`(`root`), `-EsxiSshKey`, `-EsxiSshCredential`, `-CompletePercent`(99), `-PollSeconds`(20), `-StableSamples`(2), `-NoFastComplete`, `-StallSamples`(15), `-TimeoutMinutes`(90), `-Require1GPage`, `-ContinueOnIncomplete`, `-LogCsv`, `-EmitHostCheckScript` |
| `Get-VmLpageStatus` | `-VMHostName`(필수), `-VMName`, `-EsxiSshHost`, `-EsxiSshUser`(`root`), `-EsxiSshKey`, `-EsxiSshCredential`, `-Quiet` |
| `Get-VmBackingStatus` | `-VMName`(필수), `-VMHostName` |

### start_vms_lpage_gate_v1_0.sh

- 실행: `sh start_vms_lpage_gate_v1_0.sh [옵션] [VM ...]`. VM 이름을 주지 않으면 호스트의 모든 VM 을 이름순으로 켠다.

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `-n` | 꺼짐 | 점검만: 켜진 VM 의 1GB backing 표 출력, 전원 조작 없음 |
| `-i SEC` | 15 | 확인 간격 |
| `-t MIN` | 90 | VM 당 제한 시간 |
| `-s N` | 6 | 증가 없는 확인이 N 회 이어지면 중지 |
| `-p PCT` | 100 | 목표 대비 완료 비율 |
| `-c` | 꺼짐 | 실패해도 다음 VM 으로 진행 |
| `-v` | 꺼짐 | VM 마다 vsish 원본 출력 1회 |
| `-x PATTERN` | 없음 | 이름이 맞는 VM 제외(여러 번 지정 가능) |

### CheckVmRunSettings_v2_0.ps1

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Get-VmRunSettings` | `-VMHostName`(필수, 여러 개와 와일드카드 가능), `-VMName`(`*`), `-AffinityDetail`, `-OutCsv` |

### set_cat_qos_v1_10.sh

- 실행: `sh set_cat_qos_v1_10.sh catp<P>s<S>[h<H>|e<H>] [PVM1] [PVM2|+|-] [SVM|none] [옵션]`
- 첫 인자는 CAT 프로파일 이름이다. 적용 뒤 결과를 Operations 의 호스트 속성과 지표 1개로 기록한다(기본 켜짐).

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `--no-ops` | 꺼짐 | Operations 기록 전체 생략 |
| `--no-ops-metrics` | 꺼짐 | 지표 기록만 생략 |
| `--ops`, `--ops-metrics` | 기본 동작 | 받아들이지만 기본 동작과 같음 |
| `--ops-check` | 꺼짐 | Operations 접속과 객체 조회만 점검 |
| `--ops-host H`, `--ops-user U` | 스크립트 설정 값 | Operations 주소, 계정 |
| `--ops-name N` | 호스트 이름 | Operations 의 호스트 객체 이름 |
| `--pass-file F` | 없음 | 비밀번호 파일 |

## 4. cpu_affinity

### VmDeployPlan_v1_0.ps1

PowerShell 만 있으면 된다. vCenter 연결과 PowerCLI 가 필요 없다.

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `New-VmDeployPlan` | `-Profile`(필수), `-HostSockets`(2), `-HostCoresPerSocket`(0), `-HostHT`(`on`), `-HostSnc`(1), `-EsxiReserveCores`(-1), `-PvmCount`(0), `-PvmVcpu`, `-PvmMemoryGB`, `-SvmVcpu`(0), `-SvmMemoryGB`(0), `-PvmVSockets`(0), `-SvmVSockets`(0), `-PvmNames`, `-SvmName`, `-NamePrefix`, `-ShareRatio`, `-Lpage1GB`, `-Vpmc`, `-OutDir`, `-PassThru`, `-Quiet` |
| `Test-VmDeployPlan` | 배치 규칙 자체 점검. 옵션은 스크립트 첫머리 설명 참조 |

### SetVcpuAffinityProfile_v3_9.ps1

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Set-VcpuAffinityProfile` | `-ProfileName`(필수), `-VMHostName`(필수), `-pvm`, `-pvm2`, `-pvms`, `-PvmCount`(0), `-svm`, `-NumaNodesPerSocket`(0), `-EsxiReserveCores`(-1), `-SkipTopologyKeys`, `-PvmOnly`, `-SvmOnly` |

### collect_vcpu_placement_v1_0.sh

- 실행: `sh collect_vcpu_placement_v1_0.sh [옵션] [VM ...]`. VM 이름을 주지 않으면 켜진 VM 전부를 본다. 설정을 바꾸지 않는다.
- 결과: `<DIR>/<호스트>_<라벨>_<UTC 시각>/` 아래 `topology.csv`, `placement.csv`, `numa_clients.csv` 등.

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `-p` | 꺼짐 | 점검만: 토폴로지와 읽기 경로 확인, 수집 없음 |
| `-i SEC` | 10 | 수집 간격 |
| `-t SEC` | 600 | 전체 시간. 0 이면 Ctrl-C 까지 |
| `-o DIR` | `/tmp/vcpuplace` | 결과 폴더 |
| `-L LABEL` | 없음 | 모든 행에 적을 실행 라벨 |
| `-e N` | 없음 | esxtop batch 를 N 회 함께 저장 |
| `-v` | 꺼짐 | 수집마다 명령 원본 출력을 `raw/` 에 보관 |
| `-N PATH` | 자동 탐색 | vCPU 의 pCPU 번호를 읽을 vsish 경로 직접 지정 |

### taskset_pin_primesim.sh

- 실행: `./taskset_pin_primesim.sh apply | verify | reset`. 옵션은 환경 변수로 준다.

| 환경 변수 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `MODE` | `job` | `job` = 잡 단위 마스크, `thread` = 스레드 1:1 |
| `INTERVAL` | 30 | 감시 간격(초) |
| `CPUS_PER_JOB` | 4 | 잡 하나에 줄 vCPU 수 |
| `ONCE` | 0 | 1 이면 한 번만 적용 |
| `DRYRUN` | 0 | 1 이면 명령만 출력 |
| `NCPU` | `nproc` 값 | vCPU 수 |
| `LOG` | `/var/tmp/taskset_pin_primesim.log` | 로그 파일 |

## 5. collection_etc

### config_snapshot_v1_1.ps1

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `New-ConfigSnapshot` | `-VMHostName`(필수), `-VMName`, `-Exclude`(`vCLS*`), `-OutDir`, `-Format`, `-NoOps`, `-OpsHost`, `-OpsUser`, `-PassFile`, `-Quiet` |
| `Test-ConfigSnapshot` | `-VMHostName`(필수), `-OpsHost`, `-OpsUser`, `-PassFile` |

`-NoOps` 를 주면 Operations 기록을 생략한다. 빈 값인 옵션은 스크립트 설정 블록의 값을 쓴다.

### guest_config_push.sh

OS 구성값 10개(THP enabled, THP defrag, khugepaged scan_sleep_millisecs, khugepaged pages_to_scan, kernel.numa_balancing, hugepages 2MB 와 1GB nr_hugepages, default_hugepagesz, kernel, Collected At)를 읽어 Operations 객체의 속성 `Custom Configuration|Guest|*` 로 기록한다. 한 번 실행하고 끝난다. 테스트 전과 설정을 변경한 뒤에 실행한다.

- 실행: `bash guest_config_push.sh [옵션]`. 필요한 명령: curl, openssl, 그리고 python3 또는 jq.
- 판: 1.1 (2026-11-18). 파일 이름에 판 번호를 넣지 않는다. `--version` 이 판을 출력한다.
- 접속 설정(1.1): 수집기와 같은 `ops_local.conf`(`OPS_HOST`, `OPS_USER`, `OPS_ENC_KEY`, `OPS_PASS_ENC`)를 읽는다. 스크립트가 있는 폴더에서 먼저 찾고, 없으면 한 폴더 위에서 찾는다. 다른 위치는 `--config` 나 환경 변수 `OPS_PUSH_CONFIG` 로 지정한다. 값의 우선순위는 옵션, 환경 변수(`OPS_HOST`, `OPS_USER`, `OPS_PASSWORD`), 설정 파일, 스크립트 안의 값(1.1 전에 값을 직접 적어 둔 사본용. 저장소에서는 비어 있음) 순서다.

기록할 객체(`--target`, 1.1):

| 값 | 대상 | 동작 |
| :-- | :-- | :-- |
| `vm` (기본값) | VM 의 게스트 OS | 이름이 같은 VMWARE VirtualMachine 객체에 기록한다. 객체가 없으면 오류로 끝나고 객체를 만들지 않는다 |
| `bm` | BM 호스트 | 이름이 같은 객체를 모든 adapter kind 에서 찾는다. 있으면 그 객체에 기록한다. 없으면 객체를 만든 뒤 기록한다(adapter kind `BareMetalPush`, object type `BareMetalServer`). `ops_metric_push.sh --target bm` 과 같은 객체를 쓰므로 지표와 구성값이 한 객체에 모인다 |
| `auto` | VM 과 BM 호스트가 섞인 경우 | 이 장비가 가상 머신이면 `vm`, 아니면 `bm` 으로 동작한다. DMI 의 제조사, 제품 이름(VMware 등)과 CPU 플래그 `hypervisor` 로 구분한다. 같은 명령 한 줄을 양쪽에서 쓸 때 지정한다 |

- `--target bm` 에서 이름이 같은 객체가 여럿이면 다른 어댑터가 수집하는 객체를 먼저 쓴다. 객체 조회가 실패하거나 Operations 가 객체 생성을 거부하면 객체를 만들지 않고 오류로 끝난다. 계정에 객체를 만들 권한이 있어야 한다.
- 객체 이름은 `--name` 으로 지정한다. 생략하면 `hostname -s` 값이다.
- 마지막 출력 줄이 결과다: `[OPS] <이름> Guest properties 10 recorded <시각> [<객체 설명>]` 또는 `[ERROR] ...`.
- BM 호스트에서도 속성 이름은 `Custom Configuration|Guest|*` 그대로다(VM 과 같은 이름으로 비교하기 위해서다).

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `--target vm\|bm\|auto` | `vm` | 기록할 객체(위 표) |
| `--name NAME`, `--vm NAME` | `hostname -s` | Operations 의 객체 이름 |
| `--dry-run` | 꺼짐 | 값만 출력, 전송 없음 |
| `--check` | 꺼짐 | 토큰, 인증, 객체 조회 점검. 아무것도 만들지 않는다 |
| `--out FILE` | 없음 | key,value CSV 도 저장 |
| `--config FILE` | 스크립트 폴더 또는 한 폴더 위의 `ops_local.conf` | 접속 설정 파일 |
| `--ops-host H`, `--ops-user U` | 설정 파일의 값 | Operations 주소, 계정 |
| `--pass-file F` | 없음 | 비밀번호 파일 |
| `--adapter-kind K`, `--resource-kind K` | `BareMetalPush`, `BareMetalServer` | `--target bm` 이 만드는 객체의 종류 |
| `--insecure`, `--verify-tls`, `--cacert F` | 인증서 확인 안 함 | TLS 인증서 확인 방식 |
| `--version` | | 판 출력 |

```
bash guest_config_push.sh                     # VM
bash guest_config_push.sh --target bm         # BM 호스트 (객체가 없으면 만든다)
bash guest_config_push.sh --target auto       # VM 과 BM 호스트에 같은 명령
bash guest_config_push.sh --target bm --check # 접속과 객체 조회만 확인
```

| 날짜 | 판 | 변경 내용 |
| :-- | :-- | :-- |
| 2026-10-19 | 1.0 | 첫 판. VM 객체에 기록 |
| 2026-11-18 | 1.1 | BM 호스트 대상 `--target bm`, `--target auto` 추가. 객체가 없으면 만들고 기록. `--name`, `--config`, `--adapter-kind`, `--resource-kind`, `--version` 추가. 접속 설정을 `ops_local.conf` 에서 읽음. `OPS_HOST` 에 `http(s)://` 주소 허용. `--target vm`(기본값)의 동작과 기록하는 10개 항목은 1.0 과 같음. 시험 `tests/run_guest_config.sh` |

### Export-EsxiSettingsReference_v1_0.ps1

| 함수 | 옵션 (기본값) |
| :-- | :-- |
| `Export-EsxiSettingsReference` | `-VMHostName`(필수), `-OutDir`, `-Tag`, `-NoKernel`, `-Quiet` |

### primesim_phase_syslog_v4.4.sh

- 실행: `./primesim_phase_syslog_v4.4.sh <필터문자열> [옵션]`. 필터문자열이 들어간 output 로그 파일 1개가 syslog 1줄, CSV 1행이 된다.
- 스크립트 위쪽 설정 블록: `LOG_DIR`(로그 폴더), `OUTPUT_MODE`(`syslog`), `SYSLOG_SERVER`, `SYSLOG_PORT`(514), `SYSLOG_TAG`(`primesim-phase-<계정>`), `OUTPUT_DIR`(`/tmp`), `FIND_DEPTH`(1).
- 이 CSV 가 성능 리포트 생성기의 phase 소요 시간 입력이다.

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `--dry-run` | 꺼짐 | 추출 결과만 출력, 전송과 저장 없음 |
| `--mode syslog\|file\|both` | `OUTPUT_MODE` 값 | 출력 방식 |
| `--out FILE` | 자동 이름 | CSV 파일 경로 |
| `--dir DIR` | `LOG_DIR` 값 | output 로그 폴더 |

### prs_maps_monitor_v1.03.sh

- 실행: `nohup /bin/bash ./prs_maps_monitor_v1.03.sh > /tmp/prs_maps.log 2>&1 &`
- 결과: `smaps_vma_*.csv`, `smaps_summary_*.csv`, `numa_*.csv`, 원본 `*.txt.gz`.

| 옵션 | 기본값 | 내용 |
| :-- | :-- | :-- |
| `--interval SEC` | 600 | 수집이 끝난 뒤 다음 수집까지 대기 시간 |
| `--pattern STR` | `primesim` | 프로세스 이름 패턴(대소문자 무시) |
| `--outdir DIR` | `/tmp` | 저장 폴더(이미 있는 폴더) |
| `--min-rss-kb N` | 0 | RSS 가 이 값 미만인 프로세스 제외 |
| `--once` | 꺼짐 | 한 번만 수집 |
| `--label STR` | 없음 | 수집 라벨 |
| `--pid PID` | 없음 | 이 프로세스만 수집 |
| `--start-at HH:MM` | 없음 | 이 시각까지 기다린 뒤 시작 |

### jemalloc_check.sh

- 실행: `bash jemalloc_check.sh`. 옵션 없음. 프로세스마다 libjemalloc 로드 여부, LD_PRELOAD 전달 여부, 3 MB 익명 매핑 수를 출력한다.

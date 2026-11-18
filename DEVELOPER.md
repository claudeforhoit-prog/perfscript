# 개발 지침 (수집기를 고치거나 다시 만드는 사람과 AI 용)

이 문서는 Ops 수집기 세 개를 고치는 사람과 AI 코딩 도구가 맨 먼저 읽는 문서다.
사용 방법은 `README.md`, 수집 지표 목록은 `METRICS.md`, 시험 도구 사용법은 `tests/README.md` 에 있다.

## 1. AI 에게 시킬 때

```
DEVELOPER.md, README.md, METRICS.md 를 먼저 읽어라.
3절의 설계 규칙은 사용자가 정한 것이므로 요청 없이 바꾸지 마라. 특히 수집 지표는 사용자 확인 없이 추가, 삭제, 교체하지 마라.
고친 뒤 4절의 시험을 실행하고, python3 tools/gen_metrics.py --check 가 통과하는지 확인해라.
```

## 2. 구조

| 파일 | 실행 위치 | 하는 일 |
| :-- | :-- | :-- |
| `ops_metric_push.sh` | 게스트 OS, BM 호스트 | perf 지표와 THP 지표 수집 후 VCF Operations 로 전송 또는 CSV 저장. 지표 정의는 파일 안의 `METRIC_TABLE`, 버전은 `SCRIPT_VERSION` |
| `gpu_metric_push.sh` | GPU 가 있는 게스트 OS, BM 호스트 | nvidia-smi 지표와 구성 정보 |
| `vmkperf_ops_push/vmkperf_ops_push.py` | ESXi 호스트 | vmkperf 지표. 지표 정의는 `events/metrics.json`, CPU 별 이벤트는 `events/<CPU>.json`, CPU 판별은 `events/cpu_map.json`, 버전은 `VERSION` |
| `vmkperf_ops_push/make_event_json*.py` | 개발 PC | 공개 이벤트 목록에서 `events/<CPU>.json` 생성 |
| `collection_etc/guest_config_push.sh` | 게스트 OS, BM 호스트 | OS 구성값 10개를 Operations 객체의 속성으로 기록(수집기는 아님. 한 번 실행하고 끝남). `--target bm` 은 수집기와 같은 BM 호스트 객체를 쓴다. 버전은 `SCRIPT_VERSION`, 설명은 `SCRIPTS.md` |
| `ops_local.conf` | 수집기 옆 | 접속 설정 양식(키만 있고 값은 빈 파일) |
| `tools/gen_metrics.py` | 개발 PC | 수집기 코드에서 `METRICS.md` 생성 |
| `tests/` | 개발 PC | 가짜 perf, ESXi 명령 흉내, Operations 흉내 서버 |

## 3. 설계 규칙 (사용자가 정한 것. 요청 없이 바꾸지 않는다)

### 3.1 수집 지표

- 수집 지표는 사용자가 설계해 확정한 것이 기준이다: 게스트 26개(`METRIC_TABLE`), 호스트 15개(`events/metrics.json`). 목록은 `METRICS.md`.
- 지표의 추가, 삭제, 교체, 정의 변경, CPU 종류에 따른 수집 조건 변경은 사용자 확인이 있을 때만 한다.
- 새 CPU 나 새 목적 때문에 지표가 필요하면 먼저 대응표(같은 지표, 대체 지표, 수집 불가)와 추가 후보를 사용자에게 보이고, 확정된 뒤에 고친다.
- 지표 값의 뜻이 달라지는 변경(계수 시간, 수집 시점 등)은 변경 내용에 그 사실을 적는다.

### 3.2 접속 정보

- 주소, 계정, 비밀번호, 암호화 키를 스크립트에 넣지 않는다. `ops_local.conf` 에서 읽는다.
- 저장소에는 값이 빈 `ops_local.conf` 만 둔다. 값을 채운 파일, 실제 주소 · 계정 · 암호문 · 키 문자열을 커밋하지 않는다.
- 설정 파일은 글자로만 읽고 실행하지 않는다. 값의 우선순위는 명령행 옵션, 환경 변수, 설정 파일 순이다.

### 3.3 동작

- 게스트 수집기는 bash 3.2 이상에서 동작해야 한다(연관 배열을 쓰지 않는다). 게스트의 기본 셸이 csh 여도 `bash 스크립트` 로 실행된다.
- perf 는 한 번 실행해 계속 두는 방식이다. multiplexing 이 생기면 로그에 표시한다. `--perf-fit` 은 카운터 수에 맞게 이벤트를 줄인다.
- 전송 대상: 기본은 VM 객체, `--target bm` 은 BM 호스트 객체(없으면 생성).
- ESXi 수집기는 ESXi 에 있는 Python 과 표준 라이브러리만 쓴다.
- `--mode file`(CSV 저장)은 접속 설정 없이 동작해야 한다.

### 3.4 버전

- 파일 이름에 버전을 넣지 않는다. 변경할 때마다 스크립트 안의 버전 값을 올리고 `README.md` 3절 표에 한 줄을 추가한다.
- 릴리스 커밋에 `<수집기>-v<버전>` 태그를 지정한다. 되돌릴 때는 이력을 지우지 않고 새 커밋으로 한다.
- 지표 표나 `events/*.json` 을 바꾼 커밋, 버전을 올린 커밋에서는 `python3 tools/gen_metrics.py` 로 `METRICS.md` 를 다시 만든다.

## 4. 고치는 절차와 시험

1. 고친다. 3.1 에 해당하는 변경이면 먼저 사용자 확인을 받는다.
2. 게스트 수집기: `tests/run_guest.sh` 로 가짜 perf 에서 실행해 로그와 CSV 머리글을 본다(Intel · AMD 의 `/proc` 대용 폴더 각각). 이전 판과 비교할 때는 `git show <이전 커밋>:ops_metric_push.sh` 로 꺼내 `COLLECTOR=<그 파일>` 로 같은 조건에서 실행한다.
3. 호스트 수집기: `tests/stub_esxi_bin` 을 PATH 앞에 두고 `python3 vmkperf_ops_push/vmkperf_ops_push.py check --mode file` 을 실행한다.
4. 전송: `tests/fake_ops.py` 흉내 서버로 객체 조회, 생성, 지표 수신을 본다. 구성값 기록 스크립트는 `bash tests/run_guest_config.sh` 로 확인한다.
5. `python3 tools/gen_metrics.py --check` 로 `METRICS.md` 가 코드와 같은지 본다.
6. 커밋 전에 실제 주소, 계정, 암호문, 키 문자열이 없는지 검색한다.

가짜 도구는 처리 흐름만 확인한다. 실제 게스트와 호스트에서의 값은 따로 확인해야 한다.

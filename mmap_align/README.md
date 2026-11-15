# mmap_align — 2 MB 정렬 인터포저 (PrimeSim mp alloc 대응)

PrimeSim의 자체 풀 할당자(`mp alloc`)가 3 MB 청크를 `mmap()` 직접 호출로 확보하는데,
커널 4.18은 mmap을 4 KB 정렬만 보장해 절반이 `THPeligible=0`이 된다.
이 라이브러리는 **큰 익명 mmap을 2 MB 경계로 강제 정렬**해 THP 후보로 만든다.
앱 바이너리·소스 수정 없음. `LD_PRELOAD` 한 줄로 켜고 끈다.

## 원리

```
mp alloc: mmap(NULL, 3MB, ...)            ← 앱이 부름
   ↓ 인터포저가 가로챔
실제로는: mmap(NULL, 3MB+2MB, ...)         ← 여유분 붙여 크게 잡음
   ↓ 커널이 아무 데나 배치 (4KB 정렬)
   ↓ 시작주소를 2MB 경계로 올림
   ↓ 앞쪽 잉여 munmap + 뒤쪽 잉여 munmap
반환:     2MB 정렬된 3MB 영역만            ← THPeligible=1
```
커널 6.1의 `thp_get_unmapped_area`가 커널 안에서 하는 일을 사용자 공간에서 흉내낸 것.

## 빌드·자체시험 (게스트에서)

```bash
bash scripts/mmap_align/build_and_test.sh
```
자체시험 마지막 줄이 `ALIGNED (offset 0 KB)`이면 정상.

## 실제 사용 (잡 실행 셸)

```bash
export MMAP_ALIGN_MIN=2097152                 # 2MB 이상만 정렬 (기본값)
export LD_PRELOAD=/절대경로/mmap_align.so
python3 .../bench-eda-cae.py run primesim LP5_VL_21 -n 4
```

여러 잡이 뜨면 환경변수가 상속되므로 4잡 전부 적용된다.

## 검증 (판정 창: 잡 시작 +26분, elaboration 진입)

```bash
PID=$(ps -eo pid,comm,rss --sort=-rss | awk '$2=="primesim"{print $1;exit}')

# 3MB VMA 는 여전히 ~7,795개일 것 (인터포저는 크기가 아니라 정렬만 바꿈)
grep -c '^Size: *3072 kB' /proc/$PID/smaps

# ★핵심: 그 3MB VMA 들의 THPeligible 이 0 → 1 로 바뀌었는지
awk '/^Size:/{s=$2} /^Anonymous:/{a=$2} /^THPeligible:/{if(s==3072&&a>0) e[$2]++}
     END{print "THPeligible=0:", e["0"]+0, " THPeligible=1:", e["1"]+0}' /proc/$PID/smaps

# coverage (기준 71% → 85%+ 기대)
# push ops metric 의 THP_Coverage_Pct 로 확인
```

## 판정

| 확인 | 기준(무적용) | 인터포저 적용 시 기대 |
| :--- | :--- | :--- |
| 3MB VMA 개수 | 7,795 | 7,795 (불변 — 크기는 그대로) |
| 그중 THPeligible=0 | ~3,894 | **≈ 0** ← 성공 판정 |
| 익명 VMA 2MB 정렬 | 0 / 10,971 | 대부분 정렬 |
| elaboration coverage | 71% | 85~95% [추정] |
| ★DTLB MPI | 0.2 (EMON) | 줄면 성능 연결 · 안 줄면 coverage만 |

## 주의 / 한계

- **정렬만 바꾼다** — VMA 크기·개수는 그대로다. coverage(정렬 판정)만 오른다.
- 익명·비-FIXED·`MMAP_ALIGN_MIN` 이상만 건드린다. 파일 매핑·고정 매핑·소형은 그대로 통과.
- 실패 시 평범한 mmap으로 폴백 — 기준보다 나빠지지 않는다.
- 3MB가 여전히 3MB라 정렬돼도 그 안 2MB만 huge, 나머지 ~1MB는 4KB (기준의 eligible 그룹 84.2%와 같은 상한).
  → 커버리지 상한을 더 올리려면 `MMAP_ALIGN_MIN`은 그대로 두되 청크 자체가 2MB 배수여야 하는데 그건 앱 영역.
- ★검증 필요한 커스텀 코드다. 먼저 자체시험 통과 확인 → 짧은 잡으로 THPeligible 전환 확인 → 정식 런.
- **RHEL 9 이관 시 폐기** — 커널이 같은 일을 하므로 불필요해진다.

## 파일

- `mmap_align.c` — 인터포저 본체
- `build_and_test.sh` — 빌드 + 자체시험
- `README.md` — 이 문서

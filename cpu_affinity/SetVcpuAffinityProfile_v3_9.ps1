function Set-VcpuAffinityProfile {
    # ==========================================================================
    # v3.9  (2026-10-27)
    #
    #   v3.7 -> v3.9 : Multi VM rev12/rev11 PVM 순차 고정, vm4d 만 노드 라운드로빈,
    #                  VmDeployPlan v1.0 배치 규칙과 일치
    #     PVM 고정 (rev12, rev11)
    #       PVM 1대  : 변경 없음. 호스트 코어 0 부터.
    #       PVM 2대  : 변경 없음 (Two VM). PVM1 = 소켓0, PVM2 = 소켓1 의 앞 코어부터.
    #                  배정 가능 코어 = 소켓당 코어 수 (vCPU 가 더 많으면 중단).
    #       PVM 3대+ : 소켓 번갈아 배정 제거. 호스트 코어 0 부터 PVM 번호 순서로 순차 고정
    #                  (PVM1 코어 0-3, PVM2 코어 4-7 ...). 소켓 경계에서 끊지 않는다.
    #                  전체 코어보다 vCPU 합이 많으면 중단.
    #       소켓 1개 호스트의 PVM 2대 : 코어 0 부터 순차 (결과 변경 없음).
    #       Multi VM 에서 vNUMA 1노드 PVM 의 고정 코어가 NUMA 노드 경계에 걸치면 주의 문구 (값 변경 없음).
    #     SVM float, 예약 코어, rev11 HT 짝 스레드, SNC, HT Off, clear : 변경 없음 (VmDeployPlan 과 동일).
    #     vm4d (sched.nodeN.affinity)
    #       PVM 키 수 = VM 의 vNUMA 노드 수 (가상 소켓 수 = ceil(vCPU / 소켓당 코어), VM 설정에서 판독).
    #       소켓당 코어 미판독(전원 인가 시 자동 배정) 시 배치 규칙 자동값
    #         ceil(vCPU / 호스트 NUMA 노드당 코어), 최대 호스트 노드 수.
    #       PVM 1대 : 호스트 노드 0 부터 vNUMA 노드 수만큼 1:1.
    #       SVM : 변경 없음. 전 호스트 노드 1:1 (node0..nodeN-1 = 호스트 노드 0..N-1), VM 판독값과 무관.
    #             VM 가상 소켓 수가 호스트 노드 수와 다르면 값은 그대로 두고 주의 문구만 출력.
    #       PVM 2대 (Two VM) : 자기 소켓의 첫 노드부터.
    #       PVM 3대+ (또는 소켓 1개 호스트의 PVM 2대) : PVM 번호 순서로 호스트 노드 라운드로빈.
    #         시작 노드 = (PVM 순번 x vNUMA 노드 수) mod 호스트 노드 수. 번갈아 배정은 vm4d 에만 해당.
    #     vNUMA 정합 주의 문구 : 기준을 소켓 span 에서 배치 규칙 자동값(NUMA 노드 기준, SNC 반영)으로 변경.
    #       vm4d 의 SVM 도 대상 (기준 = 호스트 노드 수).
    #
    # v3.7  (2026-09-21)
    #
    #   v3.6 -> v3.7 : PVM 여러 대 (3대 이상) 구조 지원 - Multi VM / Multi Dual VM
    #     SVM 없이 PVM 만 여러 대 (예: PVM 6대, 8대) 를 배치한다.
    #     지정 방법 (둘 중 하나)
    #       -pvm esx01ev01 -PvmCount 8      : -pvm 이름 끝 숫자를 시작 번호로
    #                                            N 개 이름 생성 (ev01..ev08, 자릿수 유지)
    #       -pvms esx01ev01,esx01ev02,…  : 이름 목록 직접 지정
    #       (-pvm/-pvm2 = PVM 2대 는 그대로. -svm 은 있어도 되고 없어도 된다)
    #     배치 규칙 (PVM 2대 이상 공통 - Two VM 의 확장)
    #       PVM k -> 소켓 (k mod 소켓수) 에 번갈아 배정 (라운드로빈),
    #       같은 소켓 안에서는 앞선 PVM 이 쓴 코어 다음부터 순차로 채운다.
    #       각 PVM 의 vCPU 수는 VM 에서 읽는다 (대수마다 달라도 됨).
    #       PVM 2대면 v3.6 Two VM 과 결과가 같다 (PVM1=소켓0 코어 0.., PVM2=소켓1 코어 0..).
    #       예) 2소켓 8코어, PVM 8대 × 2vCPU : 소켓0 = PVM1, 3, 5, 7 (코어 0-7),
    #                                            소켓1 = PVM2, 4, 6, 8 (코어 8-15)
    #           2소켓 8코어, PVM 6대 × 2vCPU : 소켓0 = PVM1, 3, 5 (코어 0-5), 소켓1 = PVM2, 4, 6
    #       소켓에 남은 코어보다 vCPU 가 많으면 중단한다 (겹쳐 핀하지 않는다).
    #       소켓이 1개면 중단하지 않고 같은 소켓에 순차 배치한다 (v3.6 의 Two VM 1소켓
    #       중단은 이 규칙으로 대체 - 참고 문구 출력).
    #     vNUMA 자동 반영 : 각 PVM 의 vCPU 수, 소켓당 코어를 VM 에서 읽어 배치와 경고에
    #       반영한다. VM 의 소켓당 코어 설정 자체는 바꾸지 않는다 (전원 끈 상태에서 VM
    #       설정으로 바꿔야 하는 값 - 이 스크립트는 affinity 키만 만진다).
    #     vm4d : PVM k -> 배정된 소켓의 노드만, SVM -> 전 노드 1:1.
    #     라벨 : PVM 3대 이상 = "Multi VM (PVM N대)" / SVM 있으면 "Multi Dual VM".
    #
    #   v3.5 -> v3.6 : 토폴로지 명칭 확정 - 동작 변경 없음
    #     Dual VM     = PVM 1대 + SVM 1대            (구 표기 DualVM+SVM)
    #     Two VM      = PVM 2대, SVM 없음
    #     Two Dual VM = Two VM 에 Dual VM 의 SVM 구조를 합친 것
    #                   = PVM 2대 + SVM 1대           (구 표기 TwoVM+SVM)
    #     그 밖: clear 프로파일에서 vNUMA 정합 경고 생략(핀 계획이 없어 무의미),
    #            토폴로지 라벨 산출을 단문 if 로 재작성.
    #
    #   정본 : 테스트 계획서 시트 "CPU Affinity" (§1~§10)
    #
    #   v3.4 -> v3.5 : DualVM+SVM / TwoVM+SVM 토폴로지 지원
    #     VM 2대 = DualVM+SVM (PVM 1 + SVM 1) - 기존 동작 그대로.
    #     VM 3대 = TwoVM+SVM  (PVM 2 + SVM 1) - -pvm2 를 주면 이 구조.
    #     전제 : set_cat_qos 의 CAT 배치 - PVM1 = NUMA node0 안, PVM2 = node1 안,
    #            SVM 은 양 노드 span. 피닝은 VM 쪽(이 스크립트) 몫.
    #     TwoVM 규칙:
    #       PVM1 : vcpu i -> 소켓0 의 코어 i   (코어 단위 - HT On/Off 자동 반영)
    #       PVM2 : vcpu i -> 소켓1 의 코어 i
    #       SVM  : DualVM 과 동일 (노드별 예약 제외 후 float - 양 소켓 span)
    #       vm4d : PVM1 -> 소켓0 노드만, PVM2 -> 소켓1 노드만, SVM -> 전 노드
    #     SVM 없는 구조 : -svm 을 생략하면 PVM(1대든 2대든)만 적용한다.
    #       SVM 관련 계산, 키는 전부 생략되고 확인 표에도 PVM 쪽만 나온다.
    #     소켓 수 커버리지 :
    #       1소켓  - DualVM 동작(노드 1개로 계산). TwoVM 은 PVM 2대를 소켓별로
    #                나눌 수 없어 중단한다.
    #       4소켓+ - DualVM 은 전 소켓 사용. TwoVM 은 PVM1=소켓0, PVM2=소켓1 만
    #                쓰고 SVM 은 전 노드에 걸친다(소켓 2, 3 은 PVM 미사용).
    #       SNC-2/4 - 노드 분할, 예약 분배는 소켓 수와 무관하게 자동 반영.
    #     부분 적용 스위치:
    #       -SvmOnly - SVM 쪽 키만 적용. PVM 은 계획, 사전 제거에서 빠지고
    #                  마지막 결과 리포트에는 현재 상태 그대로 나온다.
    #       -PvmOnly - 반대. 결과 리포트는 항상 이름을 준 VM 전부를 보여준다.
    #     PVM vNUMA 정합 경고: VM 의 소켓당 코어 설정에서 나오는
    #       vNUMA 노드 수가 이 스크립트의 물리 배치(소켓 span)와 다르면
    #       적용 전 경고를 띄운다 (중단 아님). SVM 은 정본(§6)이 원래
    #       vNUMA 1노드 + 물리 2노드 float 라 경고 대상이 아니다.
    #
    #   v3.3 -> v3.4 : 하드웨어별 프로파일을 없애고 정책 하나로 합침
    #     _htoff / _snc2 는 별개 정책이 아니라 같은 정책이 다른 하드웨어에서 나온
    #     결과값이었다. 시트 값이 그것을 보여준다 -
    #       §2 rev12       소켓당 8코어, 소켓당 4코어 제외
    #       §7 rev12_snc2  노드당 4코어, 노드당 2코어 제외 = 소켓당 4코어 제외 (동일)
    #       §8 rev12_htoff 코어당 스레드가 1개일 뿐, 코어 배정은 §2 와 동일
    #     그래서 v3.4 는 프로파일을 정책 단위로만 둔다. HT On/Off 와 SNC 는
    #     호스트에서 읽어 자동 반영한다. 이름은 하나, 결과는 하드웨어에 맞춰 달라진다.
    #
    #       v3.3 까지                     v3.4
    #       rev12 / rev12_htoff / rev12_snc  ->  rev12   (하드웨어 자동 반영)
    #       rev11 / rev11_snc                ->  rev11
    #       vm4d / clear                     ->  그대로
    #     옛 이름은 전부 별칭으로 계속 받는다.
    #
    #   정책 (rev12 / rev11 공통)
    #     PVM : vcpu i -> 물리 코어 i 의 전체 스레드
    #           HT On  "0,1" "2,3" ... / HT Off  "0" "1" ...
    #     SVM : 메모리 도메인(= 호스트 NUMA 노드. SNC 를 끄면 소켓 하나가 노드 하나)마다
    #           앞쪽 코어를 ESXi 몫으로 빼고, 남은 코어에 float 시킨다.
    #           - 제외량은 소켓당 4 물리 코어(HT 스레드까지 세면 8개)로 고정.
    #             소켓 안에 노드가 여럿이면 그 4코어를 노드에 균등 분배한다
    #             (SNC-2, 소켓당 8코어면 노드당 2코어 - 제외 총량은 그대로 4코어/소켓).
    #           - SVM vCPU 는 노드 수만큼 균등하게 묶어 같은 affinity 를 준다.
    #             묶음 크기 = SVM vCPU 수 / 노드 수.
    #               2소켓(노드2) SVM 8 vCPU -> 4개씩, SVM 4 vCPU -> 2개씩
    #               SNC-2 2소켓(노드4) SVM 4 vCPU -> 1개씩
    #           - 묶음은 마지막 노드부터 역순으로 배정한다(뒤 소켓 우선).
    #     rev12 와 rev11 의 차이는 SVM 이 코어의 스레드를 다 쓰느냐(rev12),
    #     HT 짝꿍 스레드만 쓰느냐(rev11) 뿐이다.
    #
    #   [주의 - 시트 기록과 달라지는 부분]
    #     rev11 의 제외량을 소켓당 4코어로 두었다 (rev12 와 같은 기준:
    #     SVM 은 소켓당 물리 CPU 4개 제외). 시트 기록값은
    #     §3 이 소켓당 2코어 제외, §9 가 0코어 제외로 서로 다르고 둘 다 4가 아니다.
    #     기록값을 그대로 재현하려면 -EsxiReserveCores 2 (§3) / 0 (§9) 를 준다.
    #     rev12 계열(§2, §7, §8)은 4코어 제외로 시트와 일치한다.
    #
    #   토폴로지 판별
    #     소켓, 코어, 스레드 수와 NUMA 노드별 pCPU 목록을 호스트에서 읽는다
    #     (Hardware.CpuInfo / Hardware.NumaInfo). VM 을 몇 소켓 몇 코어로 만들었든
    #     스크립트가 그에 맞춰 계산하므로 프로파일 이름은 바꾸지 않는다.
    #     NumaInfo 가 SNC 노드를 보고하지 않는 펌웨어라면 -NumaNodesPerSocket 로
    #     소켓당 노드 수를 직접 준다.
    #
    #   변경 대상 : sched.vcpuN.affinity / sched.nodeN.affinity 키.
    #     예외 하나 - HT Off 호스트에서 SvmScope 가 host 인 프로파일은 SVM 에 affinity 대신
    #     NUMA 토폴로지 키를 준다. 확인 표에 별도 구획으로 표시되며
    #     -SkipTopologyKeys 로 뺄 수 있다.
    #     그 외 advanced setting 은 일절 조회/변경/삭제하지 않는다.
    #   공통 동작 : 적용 전 대상 VM 의 기존 vcpu/node affinity 키를 먼저 제거.
    #   전제 : pCPU 열거가 코어 인접 (코어 k = pCPU k*T .. k*T+T-1, T = 코어당 스레드).
    #          esxcli hardware cpu list 로 확인할 것.
    # ==========================================================================
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, HelpMessage="프로파일 (rev12 | rev11 | vm4d | clear)")]
        [string]$ProfileName,

        [Parameter(Mandatory=$false, HelpMessage="Primary VM 이름 (선택)")]
        [string]$pvm = "",

        [Parameter(Mandatory=$false, HelpMessage="두 번째 Primary VM 이름 (지정 시 Two VM / Two Dual VM = PVM 2대 구조)")]
        [string]$pvm2 = "",

        [Parameter(Mandatory=$false, HelpMessage="PVM 이름 목록 (여러 대). -pvm/-pvm2/-PvmCount 대신 사용")]
        [string[]]$pvms = @(),

        [Parameter(Mandatory=$false, HelpMessage="PVM 대수. -pvm 이름의 끝 숫자를 시작 번호로 N 개 이름을 만든다 (예: -pvm esx01ev01 -PvmCount 8 -> ev01..ev08)")]
        [int]$PvmCount = 0,

        [Parameter(Mandatory=$false, HelpMessage="Secondary VM 이름 (선택)")]
        [string]$svm = "",

        [Parameter(Mandatory=$true, HelpMessage="기준이 될 ESXi 호스트 이름")]
        [string]$VMHostName,

        [Parameter(Mandatory=$false, HelpMessage="호스트가 SNC 노드를 보고하지 않을 때 소켓당 NUMA 노드 수를 직접 지정 (0 = 호스트에서 자동 판별)")]
        [int]$NumaNodesPerSocket = 0,

        [Parameter(Mandatory=$false, HelpMessage="소켓당 ESXi 예약 물리 코어 수 (기본 4)")]
        [int]$EsxiReserveCores = -1,

        [Parameter(Mandatory=$false, HelpMessage="HT Off 호스트에서 SVM NUMA 토폴로지 키를 적용하지 않음")]
        [switch]$SkipTopologyKeys,

        [Parameter(Mandatory=$false, HelpMessage="PVM 쪽 키만 적용 - SVM 은 건드리지 않고 결과 리포트에만 표시")]
        [switch]$PvmOnly,

        [Parameter(Mandatory=$false, HelpMessage="SVM 쪽 키만 적용 - PVM 은 건드리지 않고 결과 리포트에만 표시")]
        [switch]$SvmOnly
    )

    if (-not [string]::IsNullOrWhiteSpace($pvm2) -and [string]::IsNullOrWhiteSpace($pvm)) {
        Write-Error "pvm2 는 pvm 과 함께 지정해야 합니다 (Two VM / Two Dual VM = PVM 2대 구조)."
        return
    }
    $PvmListGiven = (@($pvms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
    if ($PvmListGiven -and (-not [string]::IsNullOrWhiteSpace($pvm2) -or $PvmCount -gt 0)) {
        Write-Error "-pvms 는 -pvm2 / -PvmCount 와 같이 쓸 수 없습니다."
        return
    }
    if ($PvmCount -gt 0 -and [string]::IsNullOrWhiteSpace($pvm)) {
        Write-Error "-PvmCount 는 -pvm (시작 이름) 이 있어야 합니다. 예: -pvm esx01ev01 -PvmCount 8"
        return
    }
    if ($PvmCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($pvm2)) {
        Write-Error "-PvmCount 와 -pvm2 는 같이 쓸 수 없습니다."
        return
    }

    # PVM 이름 목록 확정
    $PvmNames = @()
    if ($PvmListGiven) {
        $PvmNames = @($pvms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    }
    elseif ($PvmCount -gt 0) {
        if ($pvm -notmatch '^(.*?)(\d+)$') {
            Write-Error "-PvmCount 를 쓰려면 -pvm 이름이 숫자로 끝나야 합니다 (예: esx01ev01). 아니면 -pvms 로 목록을 주세요."
            return
        }
        $NamePrefix = $Matches[1]; $NameStart = [int]$Matches[2]; $NameWidth = $Matches[2].Length
        for ($k = 0; $k -lt $PvmCount; $k++) {
            $PvmNames += ($NamePrefix + ([string]($NameStart + $k)).PadLeft($NameWidth, '0'))
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($pvm)) {
        $PvmNames = @($pvm)
        if (-not [string]::IsNullOrWhiteSpace($pvm2)) { $PvmNames += $pvm2 }
    }
    if ($PvmNames.Count -eq 0 -and [string]::IsNullOrWhiteSpace($svm)) {
        Write-Error "PVM(-pvm / -pvms / -PvmCount) 또는 -svm 중 최소 하나는 대상 VM 으로 입력해야 합니다."
        return
    }
    if ((@($PvmNames | Sort-Object -Unique)).Count -ne $PvmNames.Count) {
        Write-Error "PVM 이름 목록에 중복이 있습니다: $($PvmNames -join ', ')"
        return
    }
    if ($PvmOnly -and $SvmOnly) {
        Write-Error "-PvmOnly 와 -SvmOnly 는 동시에 줄 수 없습니다."
        return
    }
    if ($PvmOnly -and [string]::IsNullOrWhiteSpace($pvm)) {
        Write-Error "-PvmOnly 는 -pvm 이 있어야 의미가 있습니다."
        return
    }
    if ($SvmOnly -and [string]::IsNullOrWhiteSpace($svm)) {
        Write-Error "-SvmOnly 는 -svm 이 있어야 의미가 있습니다."
        return
    }
    $ApplyPvm = -not $SvmOnly
    $ApplySvm = -not $PvmOnly

    # ==============================================================================
    # 0. 프로파일 정의 - 정책 단위. 하드웨어 조건은 여기에 넣지 않는다.
    # ==============================================================================
    $ProfileSpec = @{
        # PvmRule    : core-all (코어의 전체 스레드) | core-first (코어의 첫 스레드) | none
        # SvmScope   : node (도메인별 배정) | host (전 vCPU 가 호스트 전체 동일 목록) | none
        # SvmThreads : all (코어의 전체 스레드) | sibling (첫 스레드를 뺀 HT 짝꿍만)
        # SvmOrder   : desc (스레드인덱스 내림 -> 코어 내림) | asc (코어 오름 -> 스레드 오름)
        # Reserve    : 소켓당 ESXi 예약 물리 코어 수
        "rev12"   = @{ Sheet="§2, §7, §8 vm4b_rev12";  PvmRule="core-all";   SvmScope="node"; SvmThreads="all";     SvmOrder="desc"; Reserve=4 }
        "rev11"   = @{ Sheet="§3, §9 vm4b_rev11";     PvmRule="core-all";   SvmScope="node"; SvmThreads="sibling"; SvmOrder="desc"; Reserve=4 }
        "rnd_aff" = @{ Sheet="§5, §10 R&D Affinity";  PvmRule="core-first"; SvmScope="host"; SvmThreads="sibling"; SvmOrder="asc";  Reserve=0 }
        "vm4d"    = @{ Sheet="§4 vm4d";              PvmRule="none";       SvmScope="none"; SvmThreads="all";     SvmOrder="asc";  Reserve=0 }
        "clear"   = @{ Sheet="§6 free float";        PvmRule="none";       SvmScope="none"; SvmThreads="all";     SvmOrder="asc";  Reserve=0 }
    }

    # 시트 구성명과 v3.3 까지의 하드웨어별 프로파일 이름을 그대로 받는다
    $Aliases = @{
        "vm4b_rev12" = "rev12";      "vm4brev12" = "rev12"
        "rev12_htoff" = "rev12";     "vm4b_rev12_htoff" = "rev12";  "htoff" = "rev12"
        "rev12_snc" = "rev12";       "rev12_snc2" = "rev12";        "vm4b_rev12_snc2" = "rev12"
        "snc2" = "rev12"
        "vm4b_rev11" = "rev11";      "rev11_2s8c" = "rev11"
        "rev11_snc" = "rev11";       "rev11_snc2" = "rev11";        "rev11_4s4c" = "rev11"
        "numa" = "vm4d"
        "rndaff" = "rnd_aff";        "r&d affinity" = "rnd_aff";    "rnd affinity" = "rnd_aff"
        "rnd_aff_htoff" = "rnd_aff"; "rnd aff_htoff" = "rnd_aff";   "rndaffhtoff" = "rnd_aff"
        "free float" = "clear";      "freefloat" = "clear";         "free_float" = "clear"
    }

    $Raw = $ProfileName.Trim().ToLower()
    $ProfileKey = if ($Aliases.ContainsKey($Raw)) { $Aliases[$Raw] } else { $Raw }

    if (-not $ProfileSpec.ContainsKey($ProfileKey)) {
        Write-Error "입력하신 프로파일('$ProfileName')은 정의되어 있지 않습니다. (사용 가능: $(($ProfileSpec.Keys | Sort-Object) -join ', '))"
        return
    }
    if ($ProfileKey -ne $Raw) {
        Write-Host "▶ '$ProfileName' -> '$ProfileKey' - 하드웨어 조건(HT, SNC)은 호스트에서 읽어 반영하므로 프로파일이 하나로 합쳐졌습니다." -ForegroundColor DarkGray
    }

    $Spec = $ProfileSpec[$ProfileKey]

    # ==============================================================================
    # 1. 대상 객체 조회 및 상태 검증
    # ==============================================================================
    Write-Host "`n[시스템] 호스트 및 VM 정보를 수집 중입니다..." -ForegroundColor Yellow

    $TargetHost = Get-VMHost -Name $VMHostName -ErrorAction Stop | Select-Object -First 1

    if ($TargetHost.ConnectionState -ne "Connected") {
        Write-Error "호스트('$VMHostName')가 vCenter에 정상적으로 연결(Connected)되어 있지 않습니다. 현재 상태: $($TargetHost.ConnectionState)"
        return
    }

    # ==============================================================================
    # 2. 호스트 CPU 토폴로지 - 소켓/코어/스레드
    # ==============================================================================
    $NumSockets   = [int]$TargetHost.ExtensionData.Hardware.CpuInfo.NumCpuPackages
    $TotalCores   = [int]$TargetHost.ExtensionData.Hardware.CpuInfo.NumCpuCores
    $TotalThreads = [int]$TargetHost.ExtensionData.Hardware.CpuInfo.NumCpuThreads

    if ($NumSockets -lt 1 -or $TotalCores -lt 1 -or $TotalThreads -lt 1) {
        Write-Error "호스트 CPU 정보를 읽지 못했습니다. (소켓 $NumSockets / 코어 $TotalCores / 스레드 $TotalThreads)"
        return
    }
    if ($TotalCores % $NumSockets -ne 0) {
        Write-Error "물리 코어 수($TotalCores)가 소켓 수($NumSockets)로 나누어떨어지지 않습니다. 코어 인접 열거 전제가 성립하지 않습니다. 중단합니다."
        return
    }
    if ($TotalThreads % $TotalCores -ne 0) {
        Write-Error "논리 프로세서 수($TotalThreads)가 물리 코어 수($TotalCores)로 나누어떨어지지 않습니다. 중단합니다."
        return
    }

    $ThreadsPerSocket = [int]($TotalThreads / $NumSockets)
    $CoresPerSocket   = [int]($TotalCores / $NumSockets)
    $ThreadsPerCore   = [int]($TotalThreads / $TotalCores)   # HT On = 2, HT Off = 1
    $HTEnabled        = ($ThreadsPerCore -gt 1)

    $HTText = if ($HTEnabled) { "HT On (코어당 $ThreadsPerCore 스레드)" } else { "HT Off (코어당 1 스레드)" }
    Write-Host "▶ 호스트 CPU : $NumSockets 소켓, $TotalCores 물리 코어, $TotalThreads 논리 프로세서 (소켓당 $CoresPerSocket 코어 / $ThreadsPerSocket pCPU) - $HTText" -ForegroundColor Cyan

    # ==============================================================================
    # 2-1. 호스트 NUMA 노드 판별 - SNC 를 켜면 소켓 하나가 노드 여럿으로 쪼개진다
    #      Hardware.NumaInfo 가 노드별 pCPU 목록을 준다. 없거나 소켓 수와 같으면
    #      소켓 = 노드로 본다. -NumaNodesPerSocket 를 주면 그 값이 우선한다.
    # ==============================================================================
    $NodeCoreSets = @()      # 노드별 물리 코어 인덱스 배열 (노드 번호 오름차순)
    $NumaSource   = ""

    if ($NumaNodesPerSocket -gt 0) {
        if ($CoresPerSocket % $NumaNodesPerSocket -ne 0) {
            Write-Error "소켓당 코어 수($CoresPerSocket)가 -NumaNodesPerSocket($NumaNodesPerSocket)로 나누어떨어지지 않습니다. 값을 확인하세요."
            return
        }
        $CoresPerNode = [int]($CoresPerSocket / $NumaNodesPerSocket)
        $NumNodes     = [int]($NumSockets * $NumaNodesPerSocket)
        for ($n = 0; $n -lt $NumNodes; $n++) {
            $NodeCoreSets += ,@(($n * $CoresPerNode)..(($n + 1) * $CoresPerNode - 1))
        }
        $NumaSource = "-NumaNodesPerSocket $NumaNodesPerSocket (수동 지정)"
    }
    else {
        $NumaNodes = $null
        try { $NumaNodes = $TargetHost.ExtensionData.Hardware.NumaInfo.NumaNode } catch { $NumaNodes = $null }
        $NumaNodes = @($NumaNodes | Where-Object { $_ -and $_.CpuID })

        if ($NumaNodes.Count -gt 0) {
            foreach ($Nd in $NumaNodes) {
                $Cores = @($Nd.CpuID | ForEach-Object { [int]([math]::Floor([int]$_ / $ThreadsPerCore)) } | Sort-Object -Unique)
                $NodeCoreSets += ,$Cores
            }
            # 노드 번호를 코어 번호 순으로 정렬 (열거 순서가 뒤섞여 오는 경우 대비)
            $NodeCoreSets = @($NodeCoreSets | Sort-Object { $_[0] })
            $NumaSource = "호스트 Hardware.NumaInfo (노드 $($NodeCoreSets.Count)개)"
        }
        else {
            for ($s = 0; $s -lt $NumSockets; $s++) {
                $NodeCoreSets += ,@(($s * $CoresPerSocket)..(($s + 1) * $CoresPerSocket - 1))
            }
            $NumaSource = "NumaInfo 미보고 - 소켓을 노드로 간주"
        }
    }

    $NumNodes = $NodeCoreSets.Count
    if ($NumNodes -lt 1) {
        Write-Error "NUMA 노드를 하나도 산출하지 못했습니다. 중단합니다."
        return
    }
    if ($NumNodes % $NumSockets -ne 0) {
        Write-Error "NUMA 노드 수($NumNodes)가 소켓 수($NumSockets)로 나누어떨어지지 않습니다. -NumaNodesPerSocket 로 직접 지정하세요."
        return
    }

    $NodesPerSocket = [int]($NumNodes / $NumSockets)
    $NodeDesc = ($NodeCoreSets | ForEach-Object { "코어 $($_[0])-$($_[-1])" }) -join ", "
    Write-Host "▶ 호스트 NUMA : $NumNodes 노드 (소켓당 $NodesPerSocket) - $NodeDesc" -ForegroundColor Cyan
    Write-Host "                출처: $NumaSource" -ForegroundColor DarkGray
    if ($NodesPerSocket -gt 1) {
        Write-Host "▶ 적용 전 호스트에서 'vsish -e ls /hardware/numa' 로 노드 수와 열거 순서를 확인하세요." -ForegroundColor Yellow
    }

    # ==============================================================================
    # 2-2. 노드당 ESXi 예약 코어 - 소켓당 예약을 소켓 안 노드에 균등 분배
    # ==============================================================================
    $ReservePerSocket = if ($EsxiReserveCores -ge 0) { [int]$EsxiReserveCores } else { [int]$Spec.Reserve }
    if ($EsxiReserveCores -ge 0) {
        Write-Host "▶ -EsxiReserveCores $EsxiReserveCores 지정 - 프로파일 기본값($($Spec.Reserve))을 덮어씁니다." -ForegroundColor Yellow
    }
    if ($ReservePerSocket % $NodesPerSocket -ne 0) {
        Write-Error "소켓당 예약 코어($ReservePerSocket)를 소켓당 노드 수($NodesPerSocket)로 균등 분배할 수 없습니다. -EsxiReserveCores 로 조정하세요."
        return
    }
    $ReservePerNode = [int]($ReservePerSocket / $NodesPerSocket)

    # ==============================================================================
    # 3. 대상 VM - vCPU 수와 vCPU 토폴로지를 읽는다
    # ==============================================================================
    $PriVMs = @()
    $SecVM  = $null

    $ShowVM = {
        param($VMObj, $Tag)
        $Cps = $null
        try { $Cps = [int]$VMObj.ExtensionData.Config.Hardware.NumCoresPerSocket } catch { $Cps = 0 }
        $TopoText = if ($Cps -gt 0) {
            $VmSockets = [int][math]::Ceiling([int]$VMObj.NumCpu / $Cps)
            "vCPU $($VMObj.NumCpu), 소켓당 코어 $Cps, vNUMA 소켓 $VmSockets"
        } else {
            "vCPU $($VMObj.NumCpu), 소켓당 코어 = 전원 인가 시 자동 배정"
        }
        Write-Host "▶ $Tag : $($VMObj.Name) : $($VMObj.PowerState) : $TopoText" -ForegroundColor Cyan
    }

    $k = 0
    foreach ($Nm in $PvmNames) {
        $k++
        $Obj = Get-VM -Name $Nm -ErrorAction Stop | Select-Object -First 1
        $PriVMs += $Obj
        $ShowTag = if ($PvmNames.Count -gt 1) { "pvm$k" } else { "pvm" }
        & $ShowVM $Obj $ShowTag
    }
    $PriVM    = if ($PriVMs.Count -gt 0) { $PriVMs[0] } else { $null }
    $NumPvm   = $PriVMs.Count
    $MultiPvm = ($NumPvm -ge 2)
    if (-not [string]::IsNullOrWhiteSpace($svm)) {
        $SecVM = Get-VM -Name $svm -ErrorAction Stop | Select-Object -First 1
        & $ShowVM $SecVM "svm"
    }

    $TopoLabel = "SVM 단독 (PVM 없음)"
    if ($NumPvm -eq 1)                 { $TopoLabel = "PVM 단독 (SVM 없음)" }
    if ($NumPvm -eq 1 -and $SecVM)     { $TopoLabel = "Dual VM (PVM 1대 + SVM 1대)" }
    if ($NumPvm -eq 2)                 { $TopoLabel = "Two VM (PVM 2대 - SVM 없음)" }
    if ($NumPvm -eq 2 -and $SecVM)     { $TopoLabel = "Two Dual VM (PVM 2대 + SVM 1대)" }
    if ($NumPvm -ge 3)                 { $TopoLabel = "Multi VM (PVM $NumPvm 대 - SVM 없음)" }
    if ($NumPvm -ge 3 -and $SecVM)     { $TopoLabel = "Multi Dual VM (PVM $NumPvm 대 + SVM 1대)" }
    Write-Host "▶ 토폴로지 : $TopoLabel" -ForegroundColor Cyan
    if ($PvmOnly) { Write-Host "▶ -PvmOnly - PVM 쪽 affinity 만 적용합니다. SVM 은 변경 없이 결과 리포트에만 나옵니다." -ForegroundColor Yellow }
    if ($SvmOnly) { Write-Host "▶ -SvmOnly - SVM 쪽 affinity 만 적용합니다. PVM 은 변경 없이 결과 리포트에만 나옵니다." -ForegroundColor Yellow }
    if ($MultiPvm) {
        if ($ProfileKey -eq "rnd_aff") {
            Write-Error "이 프로파일은 PVM 2대 이상 구조에서는 정의되지 않았습니다. Dual VM 구조에서 쓰세요."
            return
        }
        if ($NumSockets -lt 2) {
            Write-Host "▶ [참고] 소켓 1개 호스트 - PVM $NumPvm 대를 같은 소켓에 앞 코어부터 순차 배치합니다 (소켓 분리 불가)." -ForegroundColor Yellow
        }
    }
    Write-Host "▶ 프로파일 '$ProfileKey' (시트 $($Spec.Sheet)) - 소켓당 예약 $ReservePerSocket 코어 = 노드당 $ReservePerNode 코어" -ForegroundColor Cyan

    # ==============================================================================
    # 3-0. VM 가상 소켓 수 (= vNUMA 노드 수, VS). VmDeployPlan 과 같은 기준.
    #      VM 소켓당 코어 판독 시 ceil(vCPU / 소켓당 코어), 미판독 시 배치 규칙 자동값.
    #      자동값 PVM = ceil(vCPU / 호스트 NUMA 노드당 코어), 최대 호스트 노드 수
    #             SVM = 호스트 노드 수 (vm4d, HT Off 의 SvmScope host) / 그 밖 1
    # ==============================================================================
    $CoresPerNodeRule = [int]($TotalCores / $NumNodes)
    $GetVmVs = {
        param($VMObj, $Role)
        $CpuN = [int]$VMObj.NumCpu
        $Auto = 1
        if ($Role -eq "SVM") {
            if ($ProfileKey -eq "vm4d") { $Auto = $NumNodes }
            if ($Spec.SvmScope -eq "host" -and -not $HTEnabled) { $Auto = $NumNodes }
        }
        else {
            $Auto = [int][math]::Min([math]::Ceiling($CpuN / $CoresPerNodeRule), $NumNodes)
            if ($Auto -lt 1) { $Auto = 1 }
        }
        $CpsN = 0
        try { $CpsN = [int]$VMObj.ExtensionData.Config.Hardware.NumCoresPerSocket } catch { $CpsN = 0 }
        $VsN = $Auto
        if ($CpsN -gt 0) { $VsN = [int][math]::Ceiling($CpuN / $CpsN) }
        if ($VsN -lt 1) { $VsN = 1 }
        return @{ VS = $VsN; Auto = $Auto; Cps = $CpsN }
    }

    # ==============================================================================
    # 3-1. 공용 헬퍼 - 코어 인덱스 <-> pCPU 목록
    #      전제: pCPU = 코어인덱스 * ThreadsPerCore + 스레드인덱스 (코어 인접 열거)
    # ==============================================================================
    $CoreThreadsAsc = {
        param($CoreIndex)
        $out = @()
        for ($t = 0; $t -lt $ThreadsPerCore; $t++) { $out += [int]($CoreIndex * $ThreadsPerCore + $t) }
        return $out
    }

    $CoresToPcpuList = {
        param($CoreList, $ThreadMode, $Order)
        $tStart = if ($ThreadMode -eq "sibling") { 1 } else { 0 }
        $out = @()
        if ($Order -eq "desc") {
            for ($t = $ThreadsPerCore - 1; $t -ge $tStart; $t--) {
                foreach ($c in ($CoreList | Sort-Object -Descending)) { $out += [int]($c * $ThreadsPerCore + $t) }
            }
        } else {
            foreach ($c in ($CoreList | Sort-Object)) {
                for ($t = $tStart; $t -lt $ThreadsPerCore; $t++) { $out += [int]($c * $ThreadsPerCore + $t) }
            }
        }
        return $out
    }

    $PlannedSettings = @()   # affinity 키
    $PlannedExtras   = @()   # affinity 외 키 (HT Off SvmScope host 의 NUMA 토폴로지)

    # ==============================================================================
    # 4. PVM - PVM 1대 : vcpu i -> 물리 코어 i (호스트 전체 코어 0..)
    #          PVM 2대 (소켓 2개 이상, Two VM) : PVM k -> 소켓 k 의 코어 0 부터
    #          PVM 3대+ 또는 소켓 1개 호스트의 PVM 2대 : 호스트 코어 0 부터 PVM 번호 순서로 순차
    #          (Socket = -1 은 호스트 전체 span. 순차 배정의 Socket 은 시작 코어의 소켓)
    # ==============================================================================
    $PvmTargets = @()
    $TwoVmSocketSplit = ($NumPvm -eq 2 -and $NumSockets -ge 2)
    if ($NumPvm -eq 1) {
        $PvmTargets += ,@{ VM = $PriVM; CoreBase = 0; Cap = $TotalCores; Tag = "PVM"; Socket = -1; Index = 0; VsInfo = (& $GetVmVs $PriVM "PVM") }
    }
    elseif ($TwoVmSocketSplit) {
        for ($k = 0; $k -lt 2; $k++) {
            $s    = $k
            $Need = [int]$PriVMs[$k].NumCpu
            if ($Spec.PvmRule -ne "none" -and $Need -gt $CoresPerSocket) {
                Write-Error "PVM$($k+1) ($($PriVMs[$k].Name)) vCPU $Need 개가 소켓당 코어 수($CoresPerSocket) 초과. Two VM 은 PVM 하나를 소켓 하나에 고정. vCPU 수 조정 필요. 중단합니다."
                return
            }
            $PvmTargets += ,@{ VM = $PriVMs[$k]; CoreBase = ($s * $CoresPerSocket); Cap = $CoresPerSocket; Tag = "PVM$($k+1)(소켓$s)"; Socket = $s; Index = $k; VsInfo = (& $GetVmVs $PriVMs[$k] "PVM") }
        }
    }
    elseif ($NumPvm -ge 2) {
        $Cursor = 0
        for ($k = 0; $k -lt $NumPvm; $k++) {
            $Need = [int]$PriVMs[$k].NumCpu
            if ($Spec.PvmRule -ne "none" -and ($Cursor + $Need) -gt $TotalCores) {
                Write-Error "PVM$($k+1) ($($PriVMs[$k].Name)) vCPU $Need 개를 고정할 코어 부족. 전체 $TotalCores 코어 중 앞선 PVM 사용 $Cursor 코어, 남은 코어 $($TotalCores - $Cursor). PVM 수나 vCPU 수 조정 필요. 중단합니다."
                return
            }
            $PvmTargets += ,@{ VM = $PriVMs[$k]; CoreBase = $Cursor; Cap = $Need; Tag = "PVM$($k+1)"; Socket = [int][math]::Floor($Cursor / $CoresPerSocket); Index = $k; VsInfo = (& $GetVmVs $PriVMs[$k] "PVM") }
            $Cursor += $Need
        }
    }
    if ($MultiPvm -and $Spec.PvmRule -ne "none") {
        $PlanText = ($PvmTargets | ForEach-Object {
            $a  = [int]$_.CoreBase
            $b  = $a + [int]$_.VM.NumCpu - 1
            $sa = [int][math]::Floor($a / $CoresPerSocket)
            $sb = [int][math]::Floor($b / $CoresPerSocket)
            $SockText = if ($sa -eq $sb) { "소켓 $sa" } else { "소켓 $sa-$sb" }
            "$($_.Tag) 코어 $a-$b ($SockText)"
        }) -join ", "
        Write-Host "▶ PVM 배치 : $PlanText" -ForegroundColor DarkGray
    }

    # PVM vNUMA 정합 주의: VM 가상 소켓 수가 배치 규칙 자동값(NUMA 노드 기준)과 다르면 알린다 (중단 아님)
    # clear 는 핀 계획이 없으므로 대상에서 뺀다.
    $VnumaCheckTargets = if ($ProfileKey -eq "clear") { @() } else { $PvmTargets }
    foreach ($P in $VnumaCheckTargets) {
        $Vi = $P.VsInfo
        if ($Vi.Cps -gt 0 -and $Vi.VS -ne $Vi.Auto) {
            Write-Host "▶ [주의] $($P.Tag) $($P.VM.Name): VM 가상 소켓 수 $($Vi.VS) (소켓당 코어 $($Vi.Cps)), 배치 규칙 자동값 $($Vi.Auto) (NUMA 노드당 코어 $CoresPerNodeRule 기준) 과 불일치. 게스트 NUMA 인식 어긋남 가능. VM 설정 확인 필요." -ForegroundColor Yellow
        }
    }

    # Multi VM 순차 고정: vNUMA 1노드 PVM 의 고정 코어가 NUMA 노드 경계에 걸치면 알린다 (값 변경 없음)
    if ($NumPvm -ge 3 -and $Spec.PvmRule -ne "none") {
        foreach ($P in $PvmTargets) {
            $a  = [int]$P.CoreBase
            $b  = $a + [int]$P.VM.NumCpu - 1
            $na = [int][math]::Floor($a / $CoresPerNodeRule)
            $nb = [int][math]::Floor($b / $CoresPerNodeRule)
            if ($na -ne $nb -and [int]$P.VsInfo.VS -eq 1) {
                Write-Host "▶ [주의] $($P.Tag) $($P.VM.Name): 고정 코어 $a-$b 가 NUMA 노드 $na/$nb 경계에 걸침. vNUMA 1노드라 메모리 지역성 저하. PVM vCPU 수나 순서 조정 권장." -ForegroundColor Yellow
            }
        }
    }

    if ($ApplyPvm -and $Spec.PvmRule -ne "none") {
        foreach ($P in $PvmTargets) {
            $TgtVM   = $P.VM
            $NumCpuP = [int]$TgtVM.NumCpu
            if ($NumCpuP -gt $P.Cap) {
                Write-Error "$($P.Tag) ($($TgtVM.Name)) vCPU 수($NumCpuP)가 배정 가능한 물리 코어 수($($P.Cap))보다 많습니다. 코어당 vCPU 1개 규칙을 지킬 수 없습니다. 중단합니다."
                return
            }
            if ($NumCpuP -lt $P.Cap) {
                Write-Host "▶ [참고] $($P.Tag) vCPU 수($NumCpuP) < 배정 가능 코어 수($($P.Cap)) - 코어 $($P.CoreBase)..$($P.CoreBase + $NumCpuP - 1) 만 사용합니다." -ForegroundColor DarkGray
            }

            for ($i = 0; $i -lt $NumCpuP; $i++) {
                $Core  = [int]($P.CoreBase + $i)
                $Value = if ($Spec.PvmRule -eq "core-all") {
                    ((& $CoreThreadsAsc $Core) -join ",")
                } else {
                    "$([int]($Core * $ThreadsPerCore))"
                }
                $PlannedSettings += [PSCustomObject]@{
                    VMName = $TgtVM.Name; VMObject = $TgtVM
                    Key    = "sched.vcpu$i.affinity"; Value = $Value
                }
            }
        }
    }

    # ==============================================================================
    # 5. SVM
    # ==============================================================================
    if ($ApplySvm -and $SecVM -and $Spec.SvmScope -ne "none") {
        $SecNumCpu = [int]$SecVM.NumCpu

        if ($Spec.SvmScope -eq "host") {
            # SvmScope host - 전 vCPU 가 호스트 전체 sibling 스레드에 float.
            # HT Off 면 sibling 이 없으므로 시트 §10 대로 affinity 대신 NUMA 토폴로지를 준다.
            $Pcpus = @(& $CoresToPcpuList @(0..($TotalCores - 1)) $Spec.SvmThreads $Spec.SvmOrder)

            if ($Pcpus.Count -gt 0) {
                $SvmValue = $Pcpus -join ","
                for ($v = 0; $v -lt $SecNumCpu; $v++) {
                    $PlannedSettings += [PSCustomObject]@{
                        VMName = $SecVM.Name; VMObject = $SecVM
                        Key    = "sched.vcpu$v.affinity"; Value = $SvmValue
                    }
                }
            }
            else {
                Write-Host "▶ HT Off - SVM 에 줄 HT 짝꿍 스레드가 없습니다. 시트 §10 대로 affinity 없이 NUMA 토폴로지만 지정합니다." -ForegroundColor Yellow
                if ($SkipTopologyKeys) {
                    Write-Host "▶ -SkipTopologyKeys 지정 - NUMA 토폴로지 키도 적용하지 않습니다 (SVM 은 affinity, 토폴로지 모두 없음)." -ForegroundColor Yellow
                }
                elseif ($SecNumCpu % $NumNodes -ne 0) {
                    Write-Error "SVM vCPU 수($SecNumCpu)가 호스트 NUMA 노드 수($NumNodes)로 나누어떨어지지 않아 노드당 코어 수를 정할 수 없습니다. -SkipTopologyKeys 로 건너뛰거나 vCPU 수를 조정하세요."
                    return
                }
                else {
                    # 시트 §10: 4 vCPU, 2노드 -> 노드당 2코어. 일반화하면 vCPU 수 / 노드 수.
                    $CoresPerNodeSvm = [int]($SecNumCpu / $NumNodes)
                    $TopoKeys = [ordered]@{
                        "cpuid.coresPerSocket"                 = "$CoresPerNodeSvm"
                        "numa.vcpu.coresPerNode"               = "$CoresPerNodeSvm"
                        "numa.autosize.vcpu.maxPerVirtualNode" = "$CoresPerNodeSvm"
                        "numa.autosize.cookie"                 = "0"
                    }
                    foreach ($k in $TopoKeys.Keys) {
                        $PlannedExtras += [PSCustomObject]@{
                            VMName = $SecVM.Name; VMObject = $SecVM
                            Key    = $k; Value = $TopoKeys[$k]
                        }
                    }
                }
            }
        }
        else {
            # rev12 / rev11 - 노드마다 예약 코어를 빼고, vCPU 를 노드 수만큼 묶어 배정
            $ThreadMode = $Spec.SvmThreads
            if ($ThreadMode -eq "sibling" -and -not $HTEnabled) {
                Write-Host "▶ HT Off - '$ProfileKey' 의 SVM 은 HT 짝꿍 스레드만 쓰는 정책이나 짝꿍이 없습니다. 코어의 유일한 스레드를 씁니다(rev12 와 동일 결과)." -ForegroundColor Yellow
                $ThreadMode = "all"
            }

            $UsableCoreSets = @()
            for ($n = 0; $n -lt $NumNodes; $n++) {
                $Cores = @($NodeCoreSets[$n])
                if ($Cores.Count -le $ReservePerNode) {
                    Write-Error "NUMA 노드 $n 의 코어 수($($Cores.Count))가 노드당 예약분($ReservePerNode)보다 많아야 합니다. -EsxiReserveCores 로 조정하세요. 중단합니다."
                    return
                }
                $UsableCoreSets += ,@($Cores[$ReservePerNode..($Cores.Count - 1)])
            }

            $VcpusPerNode = [int][math]::Ceiling($SecNumCpu / $NumNodes)
            if ($VcpusPerNode -lt 1) { $VcpusPerNode = 1 }
            if ($SecNumCpu -lt $NumNodes) {
                Write-Host "▶ [참고] SVM vCPU 수($SecNumCpu) < NUMA 노드 수($NumNodes) - 뒤쪽 $SecNumCpu 개 노드만 사용합니다." -ForegroundColor DarkGray
            } else {
                Write-Host "▶ SVM vCPU $SecNumCpu 개를 노드 $NumNodes 개에 $VcpusPerNode 개씩 묶어 배정합니다 (마지막 노드부터 역순)." -ForegroundColor DarkGray
            }

            for ($v = 0; $v -lt $SecNumCpu; $v++) {
                $TargetNode = [int](($NumNodes - 1) - [math]::Floor($v / $VcpusPerNode))
                if ($TargetNode -lt 0) { $TargetNode = 0 }

                $Pcpus = @(& $CoresToPcpuList $UsableCoreSets[$TargetNode] $ThreadMode $Spec.SvmOrder)
                if ($Pcpus.Count -eq 0) {
                    Write-Error "NUMA 노드 $TargetNode 에서 선택 가능한 pCPU 가 없습니다. 중단합니다."
                    return
                }

                $PlannedSettings += [PSCustomObject]@{
                    VMName = $SecVM.Name; VMObject = $SecVM
                    Key    = "sched.vcpu$v.affinity"; Value = ($Pcpus -join ",")
                }
            }
        }
    }

    # ==============================================================================
    # 6. vm4d - NUMA node level. per-vCPU 핀 없이 노드 단위로만 묶는다.
    #    VM 의 vNUMA 노드 j -> 호스트 노드 1:1 (sched.nodeJ.affinity)
    #    PVM 키 수 = VM 가상 소켓 수 (3-0) / SVM 키 수 = 호스트 노드 수
    # ==============================================================================
    if ($ProfileKey -eq "vm4d") {
        # PVM 1대 : 호스트 노드 0 부터
        # Two VM  : 자기 소켓의 첫 노드부터
        # PVM 3대+ (또는 소켓 1개 호스트의 PVM 2대) : 시작 노드 = (PVM 순번 x VS) mod 노드 수, 라운드로빈
        # SVM     : 전 호스트 노드 1:1 (VM 판독값과 무관)
        $Vm4dTargets = @()
        if ($ApplyPvm) {
            foreach ($P in $PvmTargets) {
                $VS = [int]$P.VsInfo.VS
                $Start = 0
                if ($TwoVmSocketSplit) { $Start = [int]$P.Socket * $NodesPerSocket }
                elseif ($NumPvm -ge 2) { $Start = ([int]$P.Index * $VS) % $NumNodes }
                $Nodes = @()
                for ($j = 0; $j -lt $VS; $j++) { $Nodes += [int](($Start + $j) % $NumNodes) }
                $Vm4dTargets += ,@{ VM = $P.VM; HostNodes = $Nodes; Tag = $P.Tag; VsInfo = $P.VsInfo }
            }
        }
        if ($ApplySvm -and $SecVM) {
            $SvmVs = & $GetVmVs $SecVM "SVM"
            if ($SvmVs.Cps -gt 0 -and $SvmVs.VS -ne $NumNodes) {
                Write-Host "▶ [주의] SVM $($SecVM.Name): VM 가상 소켓 수 $($SvmVs.VS) (소켓당 코어 $($SvmVs.Cps)), 호스트 NUMA 노드 수 $NumNodes 와 불일치. 노드 키는 전 노드($NumNodes 개) 그대로 적용. VM 가상 소켓 수를 호스트 노드 수에 맞추는 설정 변경 필요." -ForegroundColor Yellow
            }
            $Nodes = @()
            for ($j = 0; $j -lt $NumNodes; $j++) { $Nodes += [int]$j }
            $Vm4dTargets += ,@{ VM = $SecVM; HostNodes = $Nodes; Tag = "SVM"; VsInfo = $SvmVs }
        }
        foreach ($T in $Vm4dTargets) {
            if ($T.Tag -ne "SVM" -and $T.VsInfo.Cps -le 0) {
                Write-Host "▶ [참고] $($T.Tag) $($T.VM.Name): 소켓당 코어 미판독. vNUMA 노드 수 = 배치 규칙 자동값 $($T.VsInfo.VS) 적용." -ForegroundColor DarkGray
            }
            if ($T.HostNodes.Count -gt $NumNodes) {
                Write-Host "▶ [주의] $($T.Tag) $($T.VM.Name): vNUMA 노드 수 $($T.HostNodes.Count) > 호스트 노드 수 $NumNodes. 호스트 노드 순환 배정." -ForegroundColor Yellow
            }
        }
        $MapText = ($Vm4dTargets | ForEach-Object { "$($_.Tag) 노드 $($_.HostNodes -join ',')" }) -join ", "
        if ($MapText) { Write-Host "▶ vm4d 노드 배정 (vNUMA 0.. 순) : $MapText" -ForegroundColor DarkGray }
        foreach ($T in $Vm4dTargets) {
            for ($j = 0; $j -lt $T.HostNodes.Count; $j++) {
                $PlannedSettings += [PSCustomObject]@{
                    VMName = $T.VM.Name; VMObject = $T.VM
                    Key    = "sched.node$j.affinity"; Value = "$($T.HostNodes[$j])"
                }
            }
        }
    }

    # ==============================================================================
    # 7. 기존 affinity 키 수집 (사전 제거 대상) - vcpu/node affinity 키만
    # ==============================================================================
    $RemoveTargets = @()
    $RemoveScope = @()
    if ($ApplyPvm) { $RemoveScope += @($PriVMs) }
    if ($ApplySvm) { $RemoveScope += @($SecVM) }
    foreach ($TgtVM in $RemoveScope) {
        if ($TgtVM) {
            $Existing = @()
            $Existing += Get-AdvancedSetting -Entity $TgtVM -Name "sched.vcpu*.affinity" -ErrorAction SilentlyContinue
            $Existing += Get-AdvancedSetting -Entity $TgtVM -Name "sched.node*.affinity" -ErrorAction SilentlyContinue
            foreach ($E in $Existing) {
                if ($E) {
                    $RemoveTargets += [PSCustomObject]@{
                        VMName = $TgtVM.Name; Key = $E.Name; Value = $E.Value; Setting = $E
                    }
                }
            }
        }
    }

    # HT Off 호스트의 SvmScope host 프로파일로 들어온 NUMA 토폴로지 키가 다른 프로파일에서도 남아 있으면 알린다.
    # (이 스크립트는 affinity 외 키를 지우지 않는다 - 사람이 판단할 몫)
    if ($PlannedExtras.Count -eq 0) {
        foreach ($TgtVM in (@($PriVMs) + @($SecVM))) {
            if ($TgtVM) {
                $Leftover = @()
                $Leftover += Get-AdvancedSetting -Entity $TgtVM -Name "numa.vcpu.coresPerNode" -ErrorAction SilentlyContinue
                $Leftover += Get-AdvancedSetting -Entity $TgtVM -Name "numa.autosize.vcpu.maxPerVirtualNode" -ErrorAction SilentlyContinue
                $Leftover = @($Leftover | Where-Object { $_ })
                if ($Leftover.Count -gt 0) {
                    Write-Host "▶ [주의] $($TgtVM.Name) 에 NUMA 토폴로지 키가 남아 있습니다: $(($Leftover | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')" -ForegroundColor Yellow
                    Write-Host "         이 스크립트는 affinity 외 키를 지우지 않습니다. 필요하면 수동으로 제거하세요." -ForegroundColor Yellow
                }
            }
        }
    }

    # ==============================================================================
    # 8. 적용 전 확인 및 실행
    # ==============================================================================
    if ($RemoveTargets.Count -gt 0) {
        Write-Host "`n[사전 제거 대상 - 기존 affinity 키]" -ForegroundColor Magenta
        $RemoveTargets | Select-Object VMName, Key, Value | Format-Table -AutoSize
    } else {
        Write-Host "`n[사전 제거 대상 없음 - 기존 affinity 키 미존재]" -ForegroundColor Magenta
    }

    if ($PlannedSettings.Count -gt 0) {
        Write-Host "[적용 예정 프로파일: $ProfileKey - affinity 키]" -ForegroundColor Green
        $PlannedSettings | Select-Object VMName, Key, Value | Format-Table -AutoSize
    } else {
        Write-Host "[적용 예정 프로파일: $ProfileKey - 신규 affinity 설정 없음]" -ForegroundColor Green
    }

    if ($PlannedExtras.Count -gt 0) {
        Write-Host "[적용 예정 - affinity 외 키 (NUMA 토폴로지 / VM 재기동 후 반영)]" -ForegroundColor Yellow
        $PlannedExtras | Select-Object VMName, Key, Value | Format-Table -AutoSize
    }

    if ($RemoveTargets.Count -eq 0 -and $PlannedSettings.Count -eq 0 -and $PlannedExtras.Count -eq 0) {
        Write-Host "수행할 작업이 없습니다." -ForegroundColor Yellow
        return
    }

    $Confirmation = Read-Host "위 내용대로 진행하시겠습니까? (y/n)"
    if ($Confirmation -notmatch "^y") {
        Write-Host "작업이 취소되었습니다." -ForegroundColor Yellow
        return
    }

    if ($RemoveTargets.Count -gt 0) {
        Write-Host "`n[시스템] 기존 affinity 키를 제거하는 중입니다..." -ForegroundColor Yellow
        foreach ($R in $RemoveTargets) {
            Remove-AdvancedSetting -AdvancedSetting $R.Setting -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }

    if ($PlannedSettings.Count -gt 0 -or $PlannedExtras.Count -gt 0) {
        Write-Host "[시스템] 설정을 적용하는 중입니다..." -ForegroundColor Yellow
        foreach ($Setting in (@($PlannedSettings) + @($PlannedExtras))) {
            New-AdvancedSetting -Entity $Setting.VMObject -Name $Setting.Key -Value $Setting.Value -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # ==============================================================================
    # 9. 결과 리포트 - 노드별 그룹화
    # ==============================================================================
    Write-Host "[SUCCESS] 완료! 실제 적용된 결과값을 NUMA 노드별로 분석합니다.`n" -ForegroundColor Green

    if ($PlannedExtras.Count -gt 0) {
        Write-Host "※ NUMA 토폴로지 키는 VM 을 껐다 켜야 반영됩니다." -ForegroundColor Yellow
    }

    $GetApplied = {
        param($VMObj)
        if (-not $VMObj) { return $null }
        return @(Get-AdvancedSetting -Entity $VMObj -Name "sched.vcpu*.affinity" -ErrorAction SilentlyContinue) +
               @(Get-AdvancedSetting -Entity $VMObj -Name "sched.node*.affinity"  -ErrorAction SilentlyContinue) |
               Where-Object { $_ } | Sort-Object { [int]($_.Name -replace '\D','') }
    }

    $PvmAppliedList = @()
    foreach ($V in $PriVMs) { $PvmAppliedList += ,@(& $GetApplied $V) }
    $SvmApplied = & $GetApplied $SecVM

    $AnyApplied = (@($SvmApplied).Count -gt 0)
    foreach ($A in $PvmAppliedList) { if (@($A).Count -gt 0) { $AnyApplied = $true } }
    if (-not $AnyApplied) {
        Write-Host "현재 대상 VM에 affinity 키가 없습니다. (free float 상태)" -ForegroundColor DarkGray
        return
    }

    # pCPU -> 노드 번호 역인덱스
    $CoreToNode = @{}
    for ($n = 0; $n -lt $NumNodes; $n++) {
        foreach ($c in $NodeCoreSets[$n]) { $CoreToNode[[int]$c] = $n }
    }

    $MatchNode = {
        param($Setting, $NodeIdx)
        if ($Setting.Name -like "sched.node*") { return ([int]($Setting.Value) -eq $NodeIdx) }
        if ([string]::IsNullOrWhiteSpace($Setting.Value)) { return $false }
        $FirstPcpu = [int](($Setting.Value -split ',')[0].Trim())
        $Core = [int][math]::Floor($FirstPcpu / $ThreadsPerCore)
        return ($CoreToNode.ContainsKey($Core) -and $CoreToNode[$Core] -eq $NodeIdx)
    }

    $FinalReport = @()
    for ($n = 0; $n -lt $NumNodes; $n++) {
        $Socket = [int][math]::Floor($n / $NodesPerSocket)
        $Label  = if ($NodesPerSocket -gt 1) { "Node $n (Socket $Socket)" } else { "Socket $Socket" }
        $ReportRow = [ordered]@{ "NUMA" = $Label }

        $PairList = @()
        for ($k = 0; $k -lt $NumPvm; $k++) {
            $Tg = if ($NumPvm -gt 1) { "PVM$($k+1)" } else { "PVM" }
            $PairList += @{VM=$PriVMs[$k]; Applied=$PvmAppliedList[$k]; Tag=$Tg}
        }
        $PairList += @{VM=$SecVM; Applied=$SvmApplied; Tag="SVM"}
        foreach ($Pair in $PairList) {
            if ($Pair.VM) {
                $Match = @($Pair.Applied | Where-Object { & $MatchNode $_ $n })
                $Text  = ($Match | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join "`n"
                $ReportRow["$($Pair.Tag) ($($Pair.VM.Name))"] = if ($Text) { $Text } else { "-" }
            }
        }
        $FinalReport += [PSCustomObject]$ReportRow
    }

    return $FinalReport | Format-Table -Wrap -AutoSize
}

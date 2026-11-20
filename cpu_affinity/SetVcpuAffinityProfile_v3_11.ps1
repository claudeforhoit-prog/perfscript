function Set-VcpuAffinityProfile {
    # ==========================================================================
    # Set-VcpuAffinityProfile  v3.11 (2026-11-20)
    #
    # [용도]
    #   ESXi 호스트 한 대의 PVM, SVM 에 vCPU affinity 프로파일을 적용한다.
    #   VM 의 sched.vcpuN.affinity 키를 설정한다 (vm4d 프로파일은 sched.nodeN.affinity 키).
    #   호스트의 소켓 수, 코어 수, HT, NUMA 노드(SNC)와 VM 의 vCPU 수, 소켓당 코어는
    #   실행할 때 vCenter 에서 읽는다. 이 값들은 입력하지 않는다.
    #
    # [실행 방법]
    #   PowerCLI 에서 vCenter 에 연결하고, 이 파일을 불러온 뒤 함수를 실행한다.
    #     Connect-VIServer <vCenter 주소>
    #     . .\SetVcpuAffinityProfile_v3_11.ps1
    #     Set-VcpuAffinityProfile -ProfileName rev11 -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02
    #   실행하면 호스트와 VM 정보, 제거할 기존 affinity 키, 적용할 값을 차례로 표시하고 y/n 을 묻는다.
    #   y 를 입력하면 적용하고 NUMA 노드별 결과 표를 출력한다. n 을 입력하면 아무것도 변경하지 않는다.
    #
    # [옵션]
    #   -ProfileName <이름>       필수. rev12, rev11, rnd_aff, vm4d, clear 가운데 하나
    #   -VMHostName <이름>        필수. 대상 VM 이 실행되는 ESXi 호스트 이름 (vCenter 에 표시되는 이름).
    #                             이 호스트의 CPU 구성으로 값을 계산한다
    #   -pvm <VM 이름>            PVM 1대
    #   -pvm2 <VM 이름>           두 번째 PVM. -pvm 과 함께 쓴다 (PVM 2대)
    #   -PvmCount <n>             PVM n대. -pvm 이름의 끝 숫자부터 n개의 이름을 만든다
    #                             (-pvm esx01ev01 -PvmCount 8 은 esx01ev01 부터 esx01ev08 까지)
    #   -pvms <이름,이름,...>     PVM 이름을 직접 나열한다. -pvm2, -PvmCount 와 함께 쓸 수 없다
    #   -svm <VM 이름>            SVM 1대. 생략하면 PVM 에만 적용한다
    #   -PvmOnly                  PVM 의 키만 적용한다. SVM 은 변경하지 않고 결과 표에만 표시한다.
    #                             -pvm 과 함께 쓴다
    #   -SvmOnly                  SVM 의 키만 적용한다. PVM 은 변경하지 않고 결과 표에만 표시한다.
    #                             -svm 과 함께 쓴다
    #   -EsxiReserveCores <n>     SVM 배정에서 제외할 소켓당 앞쪽 물리 코어 수.
    #                             생략하면 프로파일 값 (rev12, rev11 은 4)
    #   -NumaNodesPerSocket <n>   소켓당 NUMA 노드 수. 호스트가 SNC 노드를 보고하지 않을 때만 지정한다
    #                             (생략하면 호스트에서 읽음)
    #   -SkipTopologyKeys         rnd_aff 를 HT Off 호스트에 적용할 때 SVM 의 NUMA 토폴로지 키를 넣지 않는다
    #   PVM(-pvm, -pvms)과 -svm 가운데 하나는 반드시 지정한다.
    #
    # [적용 예시]  esx01 은 호스트 이름, esx01ev01 등은 VM 이름의 예
    #   PVM 1대와 SVM 1대 (Dual VM)
    #     Set-VcpuAffinityProfile -ProfileName rev11 -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02
    #   SVM 의 값만 다시 적용 (PVM 은 그대로 둠)
    #     Set-VcpuAffinityProfile -ProfileName rev11 -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02 -SvmOnly
    #   PVM 2대와 SVM 1대 (Two Dual VM)
    #     Set-VcpuAffinityProfile -ProfileName rev12 -VMHostName esx01 -pvm esx01ev01 -pvm2 esx01ev02 -svm esx01ev03
    #   PVM 8대 (Multi VM, esx01ev01 부터 esx01ev08 까지)
    #     Set-VcpuAffinityProfile -ProfileName rev12 -VMHostName esx01 -pvm esx01ev01 -PvmCount 8
    #   PVM 이름을 나열하고 SVM 1대 추가
    #     Set-VcpuAffinityProfile -ProfileName rev12 -VMHostName esx01 -pvms esx01ev01,esx01ev03,esx01ev05 -svm esx01ev07
    #   SVM 배정에서 제외할 코어를 소켓당 2개로 지정 (테스트 플랜 CPU Affinity 시트 3절의 rev11 값과 같은 조건)
    #     Set-VcpuAffinityProfile -ProfileName rev11 -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02 -EsxiReserveCores 2
    #   NUMA 노드 단위 affinity (vm4d)
    #     Set-VcpuAffinityProfile -ProfileName vm4d -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02
    #   affinity 키 제거 (free float)
    #     Set-VcpuAffinityProfile -ProfileName clear -VMHostName esx01 -pvm esx01ev01 -svm esx01ev02
    #
    # [프로파일]
    #   rev12    PVM : vCPU i 를 물리 코어 i 의 전체 스레드에 고정한다
    #                  (HT On 은 "0,1" "2,3" ..., HT Off 는 "0" "1" ...)
    #            SVM : NUMA 노드마다 앞쪽 코어를 제외하고, 남은 코어의 전체 스레드를 준다
    #   rev11    PVM : rev12 와 같다
    #            SVM : 남은 코어의 HT sibling thread(같은 코어의 두 번째 스레드)만 준다.
    #                  HT Off 호스트에서는 rev12 와 같은 값이 된다
    #   rnd_aff  PVM : vCPU i 를 물리 코어 i 의 첫 번째 스레드에 고정한다. PVM 1대 구조에서만 쓴다
    #            SVM : 모든 vCPU 에 호스트 전체 코어의 HT sibling thread 를 준다.
    #                  HT Off 호스트에서는 affinity 대신 NUMA 토폴로지 키 4개를 넣는다 (VM 을 껐다 켜야 반영)
    #   vm4d     vCPU 단위로 고정하지 않고 VM 의 vNUMA 노드를 호스트 NUMA 노드에 1:1 로 지정한다
    #   clear    기존 affinity 키를 제거하고 새 키를 넣지 않는다
    #   이전 이름(vm4b_rev12, rev12_htoff, rev12_snc2, vm4b_rev11, rev11_snc, numa, free float 등)도 받는다.
    #
    # [PVM 배정]  rev12, rev11
    #   PVM 1대       호스트 코어 0 부터 배정한다
    #   PVM 2대       PVM1 은 소켓 0, PVM2 는 소켓 1 의 첫 코어부터 배정한다.
    #                 vCPU 수가 소켓당 코어 수보다 많으면 중단한다
    #   PVM 3대 이상  호스트 코어 0 부터 PVM 순서대로 이어서 배정한다 (소켓 1개 호스트의 PVM 2대도 같다)
    #
    # [SVM 배정]  rev12, rev11
    #   제외할 코어는 소켓당 4개(기본)다. 소켓 안에 NUMA 노드가 여럿이면(SNC) 노드마다 같은 수로 나눈다.
    #   값은 SVM 의 가상 소켓 수에 따라 정해진다. 가상 소켓 수 = vCPU 수 / 소켓당 코어.
    #   소켓당 코어는 VM 의 CPU 설정 Cores per Socket 값이고, 읽지 못하면 가상 소켓 1개로 본다.
    #   스크립트가 읽은 값은 실행 화면의 "svm : ..." 줄과 "SVM 가상 소켓 n개" 줄에 표시된다.
    #   같은 호스트와 같은 VM 설정에서는 실행할 때마다 값이 같다.
    #     가상 소켓 수가 호스트 NUMA 노드 수보다 적은 경우
    #       vCPU 를 호스트 노드별로 나누지 않는다.
    #       가상 소켓이 1개이면 모든 vCPU 가 모든 노드의 pCPU(제외하고 남은 코어)를 합친 같은 값을 받는다.
    #       가상 소켓이 2개 이상이면 호스트 노드를 가상 소켓 수와 같은 개수의 그룹으로 나누고(마지막 노드부터),
    #       가상 소켓마다 그룹 하나의 pCPU 를 합친 값을 받는다.
    #     가상 소켓 수가 호스트 NUMA 노드 수 이상인 경우
    #       vCPU 를 호스트 노드 수와 같은 개수의 그룹으로 나누고, 마지막 노드부터 그룹마다 노드 하나를 배정한다.
    #   값의 예 (2소켓, 소켓당 8코어, HT On, SNC 해제, 제외할 코어 소켓당 4개. 소켓 0 은 pCPU 0-15, 소켓 1 은 pCPU 16-31)
    #     rev11, SVM 2 vCPU 1소켓 (소켓당 코어 2)
    #       vcpu0 = vcpu1 = 31,29,27,25,15,13,11,9
    #     rev11, SVM 4 vCPU 2소켓 (소켓당 코어 2)
    #       vcpu0, vcpu1 = 31,29,27,25
    #       vcpu2, vcpu3 = 15,13,11,9
    #     rev12, SVM 2 vCPU 1소켓 (소켓당 코어 2)
    #       vcpu0 = vcpu1 = 31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8
    #     rev12, SVM 4 vCPU 2소켓 (소켓당 코어 2)
    #       vcpu0, vcpu1 = 31,29,27,25,30,28,26,24
    #       vcpu2, vcpu3 = 15,13,11,9,14,12,10,8
    #
    # [동작 범위와 전제]
    #   적용 전에 대상 VM 의 기존 sched.vcpuN.affinity, sched.nodeN.affinity 키를 제거한다.
    #   그 밖의 advanced setting 은 변경하지 않는다.
    #   예외는 rnd_aff 를 HT Off 호스트에 적용할 때 넣는 NUMA 토폴로지 키뿐이다.
    #   VM 의 vCPU 수와 소켓당 코어 설정은 변경하지 않는다.
    #   pCPU 번호가 코어 순서로 이어지는 호스트를 전제로 한다.
    #   (코어 k 의 스레드 = pCPU k*T 부터 k*T+T-1 까지, T 는 코어당 스레드 수. esxcli hardware cpu list 로 확인)
    #
    # [변경 이력]
    #   v3.11 (2026-11-20)  첫머리 설명을 용도, 옵션, 적용 예시 중심으로 다시 작성.
    #                       계산과 화면 출력은 v3.10 과 같다
    #   v3.10 (2026-11-20)  rev12, rev11 의 SVM 배정이 SVM 의 가상 소켓 수를 반영.
    #                       v3.9 까지는 가상 소켓 1개인 SVM 도 vCPU 를 호스트 NUMA 노드별로 나눠 배정했다
    #   v3.9 까지의 변경 내용은 저장소 태그 SetVcpuAffinityProfile-v3.10 의 파일 첫머리에 있다
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
            # rev12 / rev11 - 노드마다 예약 코어를 빼고, SVM 의 가상 소켓 수에 따라 배정 (v3.10)
            #   가상 소켓 수 >= 호스트 노드 수 : vCPU 를 노드 수만큼 묶어 마지막 노드부터 배정
            #   가상 소켓 수 <  호스트 노드 수 : 가상 소켓마다 호스트 노드 묶음의 pCPU 를 합친 같은 값
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

            # v3.10 : SVM 의 가상 소켓 수(vNUMA 노드 수)를 VM 에서 읽어 반영한다
            $SvmVs    = & $GetVmVs $SecVM "SVM"
            $SvmVsNum = [int]$SvmVs.VS
            $SvmVsSrc = if ([int]$SvmVs.Cps -gt 0) { "vCPU $SecNumCpu, 소켓당 코어 $($SvmVs.Cps)" } else { "소켓당 코어 미판독, 자동값" }
            if ($SvmVsNum -lt $NumNodes) {
                # 가상 소켓 수 < 호스트 노드 수 : vCPU 를 호스트 노드별로 나누지 않는다.
                # 호스트 노드를 가상 소켓 수만큼 묶고(뒤 노드부터), 가상 소켓 j 의 vCPU 는 묶음 j 의 pCPU 를 합친 같은 값을 받는다.
                $GroupSize = if ([int]$SvmVs.Cps -gt 0) { [int]$SvmVs.Cps } else { [int][math]::Ceiling($SecNumCpu / $SvmVsNum) }
                if ($GroupSize -lt 1) { $GroupSize = 1 }
                $GroupValues = @()
                $GroupNodes  = @()
                for ($g = 0; $g -lt $SvmVsNum; $g++) {
                    $NodeHi = [int]($NumNodes - [math]::Floor(($g * $NumNodes) / $SvmVsNum))
                    $NodeLo = [int]($NumNodes - [math]::Floor((($g + 1) * $NumNodes) / $SvmVsNum))
                    $Merged = @()
                    $Names  = @()
                    for ($nd = $NodeHi - 1; $nd -ge $NodeLo; $nd--) {
                        $Merged += @(& $CoresToPcpuList $UsableCoreSets[$nd] $ThreadMode $Spec.SvmOrder)
                        $Names  += "$nd"
                    }
                    if ($Merged.Count -eq 0) {
                        Write-Error "SVM 가상 소켓 $g 에 배정할 pCPU 가 없습니다. 중단합니다."
                        return
                    }
                    $GroupValues += ,($Merged -join ",")
                    $GroupNodes  += ,($Names -join ",")
                }
                if ($SvmVsNum -eq 1) {
                    Write-Host "▶ SVM 가상 소켓 1개 ($SvmVsSrc) - vCPU $SecNumCpu 개를 호스트 노드별로 나누지 않습니다. 전 노드($($GroupNodes[0]))의 SVM 실행 pCPU 를 합친 같은 값을 줍니다." -ForegroundColor DarkGray
                } else {
                    Write-Host "▶ SVM 가상 소켓 $SvmVsNum 개 ($SvmVsSrc) < 호스트 NUMA 노드 $NumNodes 개 - 가상 소켓마다 호스트 노드 묶음($($GroupNodes -join ' / '))의 pCPU 를 합친 값을 줍니다 (소켓당 vCPU $GroupSize 개, 뒤 노드부터)." -ForegroundColor DarkGray
                }
                for ($v = 0; $v -lt $SecNumCpu; $v++) {
                    $g = [int][math]::Floor($v / $GroupSize)
                    if ($g -gt ($SvmVsNum - 1)) { $g = $SvmVsNum - 1 }
                    $PlannedSettings += [PSCustomObject]@{
                        VMName = $SecVM.Name; VMObject = $SecVM
                        Key    = "sched.vcpu$v.affinity"; Value = $GroupValues[$g]
                    }
                }
            }
            else {
                # 가상 소켓 수 >= 호스트 노드 수 : v3.9 와 같다 (노드 수만큼 묶어 마지막 노드부터)
                $VcpusPerNode = [int][math]::Ceiling($SecNumCpu / $NumNodes)
                if ($VcpusPerNode -lt 1) { $VcpusPerNode = 1 }
                if ($SecNumCpu -lt $NumNodes) {
                    Write-Host "▶ [참고] SVM vCPU 수($SecNumCpu) < NUMA 노드 수($NumNodes) - 뒤쪽 $SecNumCpu 개 노드만 사용합니다." -ForegroundColor DarkGray
                } else {
                    Write-Host "▶ SVM 가상 소켓 $SvmVsNum 개 ($SvmVsSrc) - vCPU $SecNumCpu 개를 노드 $NumNodes 개에 $VcpusPerNode 개씩 묶어 배정합니다 (마지막 노드부터 역순)." -ForegroundColor DarkGray
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
        $RemoveTargets | Select-Object VMName, Key, Value | Format-Table -Wrap -AutoSize
    } else {
        Write-Host "`n[사전 제거 대상 없음 - 기존 affinity 키 미존재]" -ForegroundColor Magenta
    }

    if ($PlannedSettings.Count -gt 0) {
        Write-Host "[적용 예정 프로파일: $ProfileKey - affinity 키]" -ForegroundColor Green
        $PlannedSettings | Select-Object VMName, Key, Value | Format-Table -Wrap -AutoSize
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
        # v3.10 : 값의 pCPU 가운데 하나라도 그 노드에 있으면 그 노드 줄에 표시한다 (여러 노드에 걸친 값은 줄마다 표시)
        # 값의 항목은 pCPU 번호 하나(예: 9) 또는 범위(예: 8-15). 그 밖의 표기는 판정에서 뺀다.
        foreach ($Tok in ($Setting.Value -split ',')) {
            $TokText = "$Tok".Trim()
            $PcLo = -1
            $PcHi = -1
            if ($TokText -match '^(\d+)-(\d+)$') {
                $PcLo = [int]$Matches[1]
                $PcHi = [int]$Matches[2]
            }
            elseif ($TokText -match '^\d+$') {
                $PcLo = [int]$TokText
                $PcHi = $PcLo
            }
            if ($PcLo -lt 0) { continue }
            for ($Pc = $PcLo; $Pc -le $PcHi; $Pc++) {
                $Core = [int][math]::Floor($Pc / $ThreadsPerCore)
                if ($CoreToNode.ContainsKey($Core) -and $CoreToNode[$Core] -eq $NodeIdx) { return $true }
            }
        }
        return $false
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

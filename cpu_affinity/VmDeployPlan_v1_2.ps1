# ==============================================================================
# VmDeployPlan  v1.2 (2026-11-20)
#
# [용도]
#   호스트 사양과 VM 의 vCPU 수, 메모리를 입력받아 VM 배포 계획표를 산출한다.
#   계획표에는 VM 스펙, advanced config 값, CPU affinity 값이 들어간다.
#   실제 호스트와 vCenter 에 접속하지 않는다. PowerShell 만 있으면 된다 (PowerCLI 불필요).
#   affinity 값은 Set-VcpuAffinityProfile 과 같은 규칙으로 계산한다. 규칙을 고치면 두 스크립트를 같이 고친다.
#
# [실행 방법]
#   PowerShell 에서 이 파일을 불러온 뒤 함수를 실행한다.
#     . .\VmDeployPlan_v1_2.ps1
#     New-VmDeployPlan -Profile rev11 -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 16 -SvmVcpu 2
#   계획표를 화면에 출력한다. -OutDir 을 지정하면 같은 표를 csv 파일로 저장한다.
#   표를 출력한 뒤, VM 을 만든 다음 실제 호스트에서 실행할 명령(Set-VmProfile, Set-VcpuAffinityProfile)을 출력한다.
#
# [함수]
#   New-VmDeployPlan    계획표를 산출한다
#   Test-VmDeployPlan   계산 규칙을 점검한다. 마지막 줄이 RESULT: 전체 통과 (27건) 이면 정상이다
#
# [옵션]  New-VmDeployPlan
#   프로파일
#     -Profile <이름>                  필수. rev12, rev11, vm4d, clear 가운데 하나
#   호스트
#     -HostCoresPerSocket <n>          필수. 호스트의 소켓당 물리 코어 수
#     -HostSockets <n>                 호스트 소켓 수 (기본 2)
#     -HostHT on|off                   Hyper-Threading 사용 여부 (기본 on)
#     -HostSnc <n>                     소켓당 NUMA 노드 수. SNC 해제는 1(기본), SNC-2 는 2
#     -EsxiReserveCores <n>            SVM 배정에서 제외할 소켓당 앞쪽 물리 코어 수 (생략하면 rev12, rev11 은 4)
#   VM
#     -PvmVcpu <n> 또는 <n,n,...>      PVM 의 vCPU 수. 값이 하나면 모든 PVM 에 같은 값, 여러 값이면 PVM 마다 지정 (16,8)
#     -PvmCount <n>                    PVM 대수. 생략하면 -PvmVcpu 에 나열한 값의 개수
#     -PvmMemoryGB <n> 또는 <n,n,...>  PVM 메모리(GB). 생략하면 계획표에 '-' 로 표시한다
#     -SvmVcpu <n>                     SVM 의 vCPU 수. 생략하면 SVM 없음 (SVM 은 1대까지)
#     -SvmMemoryGB <n>                 SVM 메모리(GB)
#     -PvmVSockets <n>                 PVM 의 가상 소켓 수. 생략하면 자동 산출
#     -SvmVSockets <n>                 SVM 의 가상 소켓 수. 생략하면 1. vm4d 에서는 적용하지 않는다
#     -PvmNames <이름,이름,...>        PVM 이름. 생략하면 ev01 부터 번호 순서
#     -SvmName <이름>                  SVM 이름. 생략하면 PVM 다음 번호 (PVM 1대이면 ev02)
#     -NamePrefix <이름>               자동으로 정하는 VM 이름 앞에 넣을 호스트 이름. esx01 이면 esx01ev01
#   설정값
#     -ShareRatio <값>                 CPU 와 메모리 shares 의 PVM:SVM 비율. 10000:1(기본), 1:1 같은 정수 비율, normal
#     -Lpage1GB on|off                 1GB large page 관련 키 5개를 계획표에 넣을지 여부 (기본 on)
#     -Vpmc on|off                     on 이면 vpmc.enable = TRUE 를 계획표에 넣는다 (기본 off)
#   출력
#     -OutDir <폴더>                   계획표 csv 를 저장할 폴더. 생략하면 화면에만 출력한다
#     -PassThru                        계획표를 PowerShell 객체로도 반환한다
#     -Quiet                           화면 출력을 생략한다
#   PVM(-PvmVcpu)과 SVM(-SvmVcpu) 가운데 하나는 반드시 지정한다.
#   설정값과 -OutDir, -NamePrefix 의 기본값은 이 파일의 USER SETTINGS 구역에서 변경할 수 있다.
#
# [적용 예시]  2소켓, 소켓당 8코어 호스트 기준
#   PVM 1대(16 vCPU)와 SVM 1대(2 vCPU, 1소켓)에 rev11 적용 (Dual VM)
#     New-VmDeployPlan -Profile rev11 -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 16 -SvmVcpu 2
#   메모리와 VM 이름을 넣고 csv 로 저장
#     New-VmDeployPlan -Profile rev11 -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 16 -SvmVcpu 2 -PvmMemoryGB 512 -SvmMemoryGB 64 -NamePrefix esx01 -OutDir C:\perf\config
#   SVM 을 2소켓(4 vCPU, 소켓당 코어 2)으로 구성
#     New-VmDeployPlan -Profile rev12 -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 16 -SvmVcpu 4 -SvmVSockets 2
#   PVM 2대(각 8 vCPU)와 SVM 1대(4 vCPU) (Two Dual VM)
#     New-VmDeployPlan -Profile rev12 -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 8,8 -SvmVcpu 4
#   PVM 6대(각 2 vCPU) (Multi VM)
#     New-VmDeployPlan -Profile rev12 -HostSockets 2 -HostCoresPerSocket 8 -PvmCount 6 -PvmVcpu 2
#   NUMA 노드 단위 affinity (vm4d)
#     New-VmDeployPlan -Profile vm4d -HostSockets 2 -HostCoresPerSocket 8 -PvmVcpu 16 -SvmVcpu 4
#   SNC-2 호스트(소켓당 32코어)의 PVM 2대(각 32 vCPU), shares 1:1, 1GB large page 관련 키 제외
#     New-VmDeployPlan -Profile vm4d -HostSockets 2 -HostCoresPerSocket 32 -HostSnc 2 -PvmVcpu 32,32 -ShareRatio 1:1 -Lpage1GB off
#
# [계획표의 구성]
#   열은 VM, 행은 항목이다. 행은 호스트 전제, VM 기본 정보, vm advanced config, CPU affinity 의 네 구간이다.
#   값 '(없음)' 은 그 키를 설정하지 않는다는 뜻이다.
#   csv 파일 이름은 deploy_plan_<프로파일>_<소켓 수>s<코어 수>c_ht<on|off>_snc<n>_<시각>.csv 이다.
#
# [VM 구조]  PVM 대수와 SVM 유무로 스크립트가 판정한다
#   PVM 1대        PVM 단독. SVM 이 있으면 Dual VM
#   PVM 2대        Two VM. SVM 이 있으면 Two Dual VM
#   PVM 3대 이상   Multi VM. SVM 이 있으면 Multi Dual VM
#   SVM 만         SVM 단독
#
# [가상 소켓 수]
#   PVM  -PvmVSockets 를 생략하면 vCPU 수를 호스트 NUMA 노드당 코어 수로 나눈 값(올림)이고, 호스트 NUMA 노드 수를 넘지 않는다.
#        2소켓 8코어 호스트에서 16 vCPU 는 2, 8 vCPU 는 1 이다. SNC 호스트에서는 SNC 노드를 기준으로 계산한다.
#   SVM  -SvmVSockets 를 생략하면 1 이다. vm4d 에서는 호스트 NUMA 노드 수로 고정한다.
#   계획표의 cores per socket 은 vCPU 수를 가상 소켓 수로 나눈 값이다. numa.vcpu.maxPerVirtualNode 도 같은 값이다.
#
# [프로파일]
#   rev12  PVM : vCPU i 를 물리 코어 i 의 전체 스레드에 고정한다
#          SVM : NUMA 노드마다 앞쪽 코어를 제외하고, 남은 코어의 전체 스레드를 준다
#   rev11  PVM : rev12 와 같다
#          SVM : 남은 코어의 HT sibling thread(같은 코어의 두 번째 스레드)만 준다
#   vm4d   vCPU 단위로 고정하지 않고 VM 의 vNUMA 노드를 호스트 NUMA 노드에 1:1 로 지정한다 (sched.nodeN.affinity)
#   clear  affinity 키를 넣지 않는다
#
# [PVM 배정]  rev12, rev11
#   PVM 1대       호스트 코어 0 부터 배정한다
#   PVM 2대       PVM1 은 소켓 0, PVM2 는 소켓 1 의 첫 코어부터 배정한다
#   PVM 3대 이상  호스트 코어 0 부터 PVM 순서대로 이어서 배정한다 (소켓 1개 호스트의 PVM 2대도 같다)
#
# [SVM 배정]  rev12, rev11
#   제외할 코어는 소켓당 4개(기본)다. 소켓 안에 NUMA 노드가 여럿이면(SNC) 노드마다 같은 수로 나눈다.
#   값은 SVM 의 가상 소켓 수(-SvmVSockets, 생략하면 1)에 따라 정해진다.
#   적용된 가상 소켓 수는 계획표의 cores per socket / sockets 행에 표시된다. 같은 입력에서는 실행할 때마다 값이 같다.
#     가상 소켓 수가 호스트 NUMA 노드 수보다 적은 경우
#       vCPU 를 호스트 노드별로 나누지 않는다.
#       가상 소켓이 1개이면 모든 vCPU 가 모든 노드의 pCPU(제외하고 남은 코어)를 합친 같은 값을 받는다.
#       가상 소켓이 2개 이상이면 가상 소켓마다 호스트 노드 그룹 하나의 pCPU 를 합친 값을 받는다.
#     가상 소켓 수가 호스트 NUMA 노드 수 이상인 경우
#       vCPU 를 호스트 노드 수와 같은 개수의 그룹으로 나누고, 마지막 노드부터 그룹마다 노드 하나를 배정한다.
#   값의 예 (2소켓, 소켓당 8코어, HT On, SNC 해제, rev11, 제외할 코어 소켓당 4개)
#     -SvmVcpu 2 (가상 소켓 1개)
#       vcpu0 = vcpu1 = 31,29,27,25,15,13,11,9
#     -SvmVcpu 4 -SvmVSockets 2
#       vcpu0, vcpu1 = 31,29,27,25
#       vcpu2, vcpu3 = 15,13,11,9
#
# [변경 이력]
#   v1.2 (2026-11-20)  첫머리 설명을 용도, 옵션, 적용 예시 중심으로 다시 작성. 계산과 화면 출력은 v1.1 과 같다
#   v1.1 (2026-11-20)  rev12, rev11 의 SVM 배정이 SVM 의 가상 소켓 수를 반영.
#                      v1.0 은 가상 소켓 1개인 SVM 도 vCPU 를 호스트 NUMA 노드별로 나눠 배정했다
# ==============================================================================

# ==== USER SETTINGS - 여기만 고친다 ===========================================
$Global:VmPlan_OutDirDefault   = ""          # -OutDir 생략 시 저장 폴더 ("" = 화면만)
$Global:VmPlan_ShareRatio      = "10000:1"   # shares 기본값 PVM:SVM
$Global:VmPlan_Lpage1GB        = "on"        # 1GB page 키 5개 기본
$Global:VmPlan_Vpmc            = "off"       # vpmc.enable 기본 (off = 미설정)
$Global:VmPlan_NamePrefix      = ""          # VM 이름 앞에 붙는 호스트 이름 (예 "esx01" -> esx01ev01). "" = ev01
$Global:VmPlan_NameFormat      = "ev{0:00}"  # VM 번호 형식. PVM 은 1 부터, SVM 은 PVM 다음 번호 (Dual VM = ev01 PVM, ev02 SVM)
# 구조 이름 (판정 결과에 붙는 표시 이름. 바꿔도 동작은 같다)
$Global:VmPlan_StructureNames = @{ PvmOnly = "PVM 단독"; Dual = "Dual VM"; Two = "Two VM"; TwoDual = "Two Dual VM"; Multi = "Multi VM"; MultiDual = "Multi Dual VM"; SvmOnly = "SVM 단독" }
# ==== USER SETTINGS 끝 ========================================================

# 프로파일 정의 - 정책 단위. 하드웨어 조건은 넣지 않는다
#   PvmRule    : core-all (코어의 전체 스레드) | core-first (코어의 첫 스레드) | none
#   SvmScope   : node (노드별 배정) | host (전 vCPU 가 호스트 전체 동일 목록) | none
#   SvmThreads : all (코어의 전체 스레드) | sibling (첫 스레드를 뺀 HT 짝꿍만)
#   SvmOrder   : desc (스레드 인덱스 내림 -> 코어 내림) | asc (코어 오름 -> 스레드 오름)
#   Reserve    : 소켓당 ESXi 예약 물리 코어 수
$Global:VmPlan_ProfileSpec = @{
    "rev12"   = @{ PvmRule="core-all";   SvmScope="node"; SvmThreads="all";     SvmOrder="desc"; Reserve=4 }
    "rev11"   = @{ PvmRule="core-all";   SvmScope="node"; SvmThreads="sibling"; SvmOrder="desc"; Reserve=4 }
    "rnd_aff" = @{ PvmRule="core-first"; SvmScope="host"; SvmThreads="sibling"; SvmOrder="asc";  Reserve=0 }
    "vm4d"    = @{ PvmRule="none";       SvmScope="none"; SvmThreads="all";     SvmOrder="asc";  Reserve=0 }
    "clear"   = @{ PvmRule="none";       SvmScope="none"; SvmThreads="all";     SvmOrder="asc";  Reserve=0 }
}
$Global:VmPlan_Aliases = @{
    "vm4b_rev12" = "rev12"; "vm4brev12" = "rev12"; "rev12_htoff" = "rev12"; "rev12_snc" = "rev12"; "rev12_snc2" = "rev12"
    "vm4b_rev11" = "rev11"; "rev11_snc" = "rev11"; "rev11_snc2" = "rev11"
    "numa" = "vm4d"; "rndaff" = "rnd_aff"; "rnd affinity" = "rnd_aff"; "rnd_aff_htoff" = "rnd_aff"
    "free float" = "clear"; "freefloat" = "clear"; "free_float" = "clear"
}


function Get-VmPlanAffinity {
    # 배치 계산. 첫머리 설명의 [PVM 배정], [SVM 배정] 과 같은 계산.
    # 반환: @{ Settings = [(VMName, Key, Value)...]; Extras = [...]; PvmTargets = [...]; Error = ""; Notes = [...] }
    param (
        [hashtable]$Spec, [string]$ProfileKey,
        [int]$NumSockets, [int]$CoresPerSocket, [int]$ThreadsPerCore, [bool]$HTEnabled,
        [object[]]$NodeCoreSets, [int]$NumNodes, [int]$NodesPerSocket, [int]$CoresPerNode, [int]$ReservePerNode,
        [object[]]$PriVMs, $SecVM
    )
    $TotalCores = $NumSockets * $CoresPerSocket
    $NumPvm   = @($PriVMs).Count
    $Result   = @{ Settings = @(); Extras = @(); PvmTargets = @(); Error = ""; Notes = @() }

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

    # ---- PVM 배치 ----
    #   PVM 1대 : 코어 0 부터 / PVM 2대 (소켓 2개 이상) : 소켓 하나씩 / PVM 3대 이상 또는 소켓 1개 : 코어 0 부터 순차
    $PvmTargets = @()
    $TwoVmSocketSplit = ($NumPvm -eq 2 -and $NumSockets -ge 2)
    if ($NumPvm -eq 1) {
        $PvmTargets += ,@{ VM = $PriVMs[0]; CoreBase = 0; Cap = $TotalCores; Tag = "PVM"; Socket = -1; Index = 0 }
    }
    elseif ($TwoVmSocketSplit) {
        for ($k = 0; $k -lt 2; $k++) {
            $s    = $k % $NumSockets
            $Need = [int]$PriVMs[$k].NumCpu
            if ($Spec.PvmRule -ne "none" -and $Need -gt $CoresPerSocket) {
                $Result.Error = "PVM$($k+1) ($($PriVMs[$k].Name)) vCPU $Need 개가 소켓당 코어 수($CoresPerSocket)를 넘음. Two VM 은 PVM 하나를 소켓 하나에 고정. vCPU 수 조정 필요"
                return $Result
            }
            $PvmTargets += ,@{ VM = $PriVMs[$k]; CoreBase = ($s * $CoresPerSocket); Cap = $CoresPerSocket; Tag = "PVM$($k+1)(소켓$s)"; Socket = $s; Index = $k }
        }
    }
    elseif ($NumPvm -ge 2) {
        $Cursor = 0
        for ($k = 0; $k -lt $NumPvm; $k++) {
            $Need = [int]$PriVMs[$k].NumCpu
            if ($Spec.PvmRule -ne "none" -and ($Cursor + $Need) -gt $TotalCores) {
                $Result.Error = "PVM$($k+1) ($($PriVMs[$k].Name)) vCPU $Need 개를 고정할 코어가 부족. 전체 $TotalCores 코어 중 앞선 PVM 이 $Cursor 코어를 써서 $($TotalCores - $Cursor) 코어만 남음. PVM 수나 vCPU 수 조정 필요"
                return $Result
            }
            $PvmTargets += ,@{ VM = $PriVMs[$k]; CoreBase = $Cursor; Cap = $Need; Tag = "PVM$($k+1)"; Socket = [int][math]::Floor($Cursor / $CoresPerSocket); Index = $k }
            $Cursor += $Need
        }
    }
    $Result.PvmTargets = $PvmTargets

    if ($Spec.PvmRule -ne "none") {
        foreach ($P in $PvmTargets) {
            $TgtVM   = $P.VM
            $NumCpuP = [int]$TgtVM.NumCpu
            if ($NumCpuP -gt $P.Cap) {
                $Result.Error = "$($P.Tag) ($($TgtVM.Name)) vCPU 수($NumCpuP)가 배정 가능한 물리 코어 수($($P.Cap))보다 많음. 코어당 vCPU 1개 규칙 불가"
                return $Result
            }
            for ($i = 0; $i -lt $NumCpuP; $i++) {
                $Core  = [int]($P.CoreBase + $i)
                $Value = if ($Spec.PvmRule -eq "core-all") { ((& $CoreThreadsAsc $Core) -join ",") } else { "$([int]($Core * $ThreadsPerCore))" }
                $Result.Settings += [PSCustomObject]@{ VMName = $TgtVM.Name; Key = "sched.vcpu$i.affinity"; Value = $Value }
            }
        }
    }

    # ---- SVM 배치 ----
    if ($SecVM -and $Spec.SvmScope -ne "none") {
        $SecNumCpu = [int]$SecVM.NumCpu
        if ($Spec.SvmScope -eq "host") {
            $Pcpus = @(& $CoresToPcpuList @(0..($TotalCores - 1)) $Spec.SvmThreads $Spec.SvmOrder)
            if ($Pcpus.Count -gt 0) {
                $SvmValue = $Pcpus -join ","
                for ($v = 0; $v -lt $SecNumCpu; $v++) {
                    $Result.Settings += [PSCustomObject]@{ VMName = $SecVM.Name; Key = "sched.vcpu$v.affinity"; Value = $SvmValue }
                }
            }
            else {
                if ($SecNumCpu % $NumNodes -ne 0) {
                    $Result.Error = "SVM vCPU 수($SecNumCpu)가 호스트 NUMA 노드 수($NumNodes)로 나누어떨어지지 않아 노드당 코어 수를 정할 수 없음"
                    return $Result
                }
                $CoresPerNodeSvm = [int]($SecNumCpu / $NumNodes)
                foreach ($kv in @(@("cpuid.coresPerSocket", "$CoresPerNodeSvm"), @("numa.vcpu.coresPerNode", "$CoresPerNodeSvm"), @("numa.autosize.vcpu.maxPerVirtualNode", "$CoresPerNodeSvm"), @("numa.autosize.cookie", "0"))) {
                    $Result.Extras += [PSCustomObject]@{ VMName = $SecVM.Name; Key = $kv[0]; Value = $kv[1] }
                }
                $Result.Notes += "HT off: SVM 에 affinity 대신 NUMA 토폴로지 키 적용 (VM 재기동 후 반영)"
            }
        }
        else {
            $ThreadMode = $Spec.SvmThreads
            if ($ThreadMode -eq "sibling" -and -not $HTEnabled) {
                $Result.Notes += "HT off: SVM 은 코어의 유일한 스레드 사용 (rev12 와 같은 결과)"
                $ThreadMode = "all"
            }
            $UsableCoreSets = @()
            for ($n = 0; $n -lt $NumNodes; $n++) {
                $Cores = @($NodeCoreSets[$n])
                if ($Cores.Count -le $ReservePerNode) {
                    $Result.Error = "NUMA 노드 $n 의 코어 수($($Cores.Count))가 노드당 예약분($ReservePerNode) 이하. -EsxiReserveCores 조정 필요"
                    return $Result
                }
                $UsableCoreSets += ,@($Cores[$ReservePerNode..($Cores.Count - 1)])
            }
            # v1.1 : SVM 의 가상 소켓 수(vNUMA 노드 수)를 반영한다 (SetVcpuAffinityProfile v3.10 과 같은 계산)
            $SvmVsNum = [int]$SecVM.VS
            if ($SvmVsNum -lt 1) { $SvmVsNum = 1 }
            if ($SvmVsNum -lt $NumNodes) {
                # 가상 소켓 수 < 호스트 노드 수 : vCPU 를 호스트 노드별로 나누지 않는다.
                # 호스트 노드를 가상 소켓 수만큼 묶고(뒤 노드부터), 가상 소켓 j 의 vCPU 는 묶음 j 의 pCPU 를 합친 같은 값을 받는다.
                $GroupSize = [int][math]::Ceiling($SecNumCpu / $SvmVsNum)
                if ($GroupSize -lt 1) { $GroupSize = 1 }
                $GroupValues = @()
                for ($g = 0; $g -lt $SvmVsNum; $g++) {
                    $NodeHi = [int]($NumNodes - [math]::Floor(($g * $NumNodes) / $SvmVsNum))
                    $NodeLo = [int]($NumNodes - [math]::Floor((($g + 1) * $NumNodes) / $SvmVsNum))
                    $Merged = @()
                    for ($nd = $NodeHi - 1; $nd -ge $NodeLo; $nd--) {
                        $Merged += @(& $CoresToPcpuList $UsableCoreSets[$nd] $ThreadMode $Spec.SvmOrder)
                    }
                    if ($Merged.Count -eq 0) { $Result.Error = "SVM 가상 소켓 $g 에 배정할 pCPU 없음"; return $Result }
                    $GroupValues += ,($Merged -join ",")
                }
                for ($v = 0; $v -lt $SecNumCpu; $v++) {
                    $g = [int][math]::Floor($v / $GroupSize)
                    if ($g -gt ($SvmVsNum - 1)) { $g = $SvmVsNum - 1 }
                    $Result.Settings += [PSCustomObject]@{ VMName = $SecVM.Name; Key = "sched.vcpu$v.affinity"; Value = $GroupValues[$g] }
                }
                $Result.Notes += $(if ($SvmVsNum -eq 1) { "SVM 가상 소켓 1개: vCPU 를 호스트 노드별로 나누지 않고 전 노드의 SVM 실행 pCPU 를 합친 같은 값 (노드별로 나누려면 -SvmVSockets $NumNodes)" } else { "SVM 가상 소켓 $SvmVsNum 개 < 호스트 노드 $NumNodes 개: 가상 소켓마다 호스트 노드 묶음의 pCPU 를 합친 값" })
            }
            else {
                # 가상 소켓 수 >= 호스트 노드 수 : v1.0 과 같다 (노드 수만큼 묶어 마지막 노드부터)
                $VcpusPerNode = [int][math]::Ceiling($SecNumCpu / $NumNodes)
                if ($VcpusPerNode -lt 1) { $VcpusPerNode = 1 }
                for ($v = 0; $v -lt $SecNumCpu; $v++) {
                    $TargetNode = [int](($NumNodes - 1) - [math]::Floor($v / $VcpusPerNode))
                    if ($TargetNode -lt 0) { $TargetNode = 0 }
                    $Pcpus = @(& $CoresToPcpuList $UsableCoreSets[$TargetNode] $ThreadMode $Spec.SvmOrder)
                    if ($Pcpus.Count -eq 0) { $Result.Error = "NUMA 노드 $TargetNode 에서 선택 가능한 pCPU 없음"; return $Result }
                    $Result.Settings += [PSCustomObject]@{ VMName = $SecVM.Name; Key = "sched.vcpu$v.affinity"; Value = ($Pcpus -join ",") }
                }
            }
        }
    }

    # ---- vm4d: VM 의 vNUMA 노드 j (키 수 = 가상 소켓 수 VS) 를 호스트 노드에 1:1 ----
    if ($ProfileKey -eq "vm4d") {
        foreach ($P in $PvmTargets) {
            $VS = [int]$P.VM.VS
            if ($VS -lt 1) { $VS = 1 }
            $Start = 0
            if ($TwoVmSocketSplit) { $Start = [int]$P.Socket * $NodesPerSocket }
            elseif ($NumPvm -ge 2) { $Start = ([int]$P.Index * $VS) % $NumNodes }
            for ($j = 0; $j -lt $VS; $j++) {
                $Result.Settings += [PSCustomObject]@{ VMName = $P.VM.Name; Key = "sched.node$j.affinity"; Value = "$(($Start + $j) % $NumNodes)" }
            }
        }
        if ($SecVM) {
            $VS = [int]$SecVM.VS
            if ($VS -lt 1) { $VS = 1 }
            for ($j = 0; $j -lt $VS; $j++) {
                $Result.Settings += [PSCustomObject]@{ VMName = $SecVM.Name; Key = "sched.node$j.affinity"; Value = "$($j % $NumNodes)" }
            }
        }
    }
    return $Result
}


function New-VmDeployPlan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)] [Alias("ProfileName")] [string]$Profile,
        [Parameter(Mandatory=$false)] [int]$HostSockets = 2,
        [Parameter(Mandatory=$false)] [int]$HostCoresPerSocket = 0,
        [Parameter(Mandatory=$false)] [ValidateSet("on","off")] [string]$HostHT = "on",
        [Parameter(Mandatory=$false)] [Alias("HostNumaNodesPerSocket")] [int]$HostSnc = 1,
        [Parameter(Mandatory=$false)] [int]$EsxiReserveCores = -1,
        [Parameter(Mandatory=$false)] [int]$PvmCount = 0,
        [Parameter(Mandatory=$false)] [int[]]$PvmVcpu = @(),
        [Parameter(Mandatory=$false)] [int[]]$PvmMemoryGB = @(),
        [Parameter(Mandatory=$false)] [int]$SvmVcpu = 0,
        [Parameter(Mandatory=$false)] [int]$SvmMemoryGB = 0,
        [Parameter(Mandatory=$false)] [int]$PvmVSockets = 0,
        [Parameter(Mandatory=$false)] [int]$SvmVSockets = 0,
        [Parameter(Mandatory=$false)] [string[]]$PvmNames = @(),
        [Parameter(Mandatory=$false)] [string]$SvmName = "",
        [Parameter(Mandatory=$false)] [string]$NamePrefix = "",
        [Parameter(Mandatory=$false)] [string]$ShareRatio = "",
        [Parameter(Mandatory=$false)] [string]$Lpage1GB = "",
        [Parameter(Mandatory=$false)] [string]$Vpmc = "",
        [Parameter(Mandatory=$false)] [string]$OutDir = "",
        [Parameter(Mandatory=$false)] [switch]$PassThru,
        [Parameter(Mandatory=$false)] [switch]$Quiet
    )
    if ($ShareRatio -eq "") { $ShareRatio = $Global:VmPlan_ShareRatio }
    if ($Lpage1GB -eq "") { $Lpage1GB = $Global:VmPlan_Lpage1GB }
    if ($Vpmc -eq "") { $Vpmc = $Global:VmPlan_Vpmc }
    if ($OutDir -eq "") { $OutDir = $Global:VmPlan_OutDirDefault }
    $Lpage1GB = $Lpage1GB.Trim().ToLower(); $Vpmc = $Vpmc.Trim().ToLower()
    if ($Lpage1GB -notin @("on", "off")) { Write-Error "-Lpage1GB 는 on 또는 off"; return }
    if ($Vpmc -notin @("on", "off")) { Write-Error "-Vpmc 는 on 또는 off"; return }

    # ---- 프로파일 ----
    $Raw = $Profile.Trim().ToLower()
    $ProfileKey = if ($Global:VmPlan_Aliases.ContainsKey($Raw)) { $Global:VmPlan_Aliases[$Raw] } else { $Raw }
    if (-not $Global:VmPlan_ProfileSpec.ContainsKey($ProfileKey)) { Write-Error "프로파일 '$Profile' 미정의. 사용 가능: rev12, rev11, vm4d, clear"; return }
    $Spec = $Global:VmPlan_ProfileSpec[$ProfileKey]

    # ---- 입력 검증과 PVM 대수 ----
    if ($HostSockets -le 0) { Write-Error "-HostSockets 는 1 이상"; return }
    if ($HostCoresPerSocket -le 0) { Write-Error "-HostCoresPerSocket (호스트 소켓당 물리 코어 수) 필요"; return }
    if ($HostSnc -le 0) { Write-Error "-HostSnc 는 1 이상 (생략 = SNC 해제, 2 = SNC-2)"; return }
    if ($HostCoresPerSocket % $HostSnc -ne 0) { Write-Error "소켓당 코어($HostCoresPerSocket)가 소켓당 노드 수($HostSnc)로 나누어떨어지지 않음"; return }
    if ($SvmVcpu -lt 0) { Write-Error "-SvmVcpu 는 0 이상"; return }
    $NumPvm = if ($PvmCount -gt 0) { $PvmCount } else { $PvmVcpu.Count }
    if ($NumPvm -eq 0 -and $SvmVcpu -le 0) { Write-Error "-PvmVcpu (PVM vCPU 수) 또는 -SvmVcpu 중 하나 필요"; return }
    if ($NumPvm -gt 0 -and $PvmVcpu.Count -eq 0) { Write-Error "-PvmVcpu 필요 (하나면 전 PVM 공통)"; return }
    if ($PvmVcpu.Count -gt 1 -and $PvmVcpu.Count -ne $NumPvm) { Write-Error "-PvmVcpu 는 하나(공통) 또는 PVM 대수($NumPvm)만큼"; return }
    foreach ($n in $PvmVcpu) { if ($n -le 0) { Write-Error "-PvmVcpu 값은 1 이상"; return } }
    if ($PvmMemoryGB.Count -gt 1 -and $PvmMemoryGB.Count -ne $NumPvm) { Write-Error "-PvmMemoryGB 는 하나(공통) 또는 PVM 대수($NumPvm)만큼"; return }
    if ($PvmNames.Count -gt 0 -and $PvmNames.Count -ne $NumPvm) { Write-Error "-PvmNames 는 PVM 대수($NumPvm)만큼"; return }
    if ($ProfileKey -eq "rnd_aff" -and $NumPvm -ge 2) { Write-Error "이 프로파일은 PVM 2대 이상 구조를 지원하지 않음"; return }
    $VcpuList = @(); $MemList = @()
    for ($k = 0; $k -lt $NumPvm; $k++) {
        $VcpuList += [int]$(if ($PvmVcpu.Count -eq 1) { $PvmVcpu[0] } else { $PvmVcpu[$k] })
        $MemList  += [int]$(if ($PvmMemoryGB.Count -eq 0) { 0 } elseif ($PvmMemoryGB.Count -eq 1) { $PvmMemoryGB[0] } else { $PvmMemoryGB[$k] })
    }

    # ---- 호스트 토폴로지 ----
    $NumSockets     = [int]$HostSockets
    $CoresPerSocket = [int]$HostCoresPerSocket
    $ThreadsPerCore = if ($HostHT -eq "on") { 2 } else { 1 }
    $HTEnabled      = ($ThreadsPerCore -gt 1)
    $TotalCores     = $NumSockets * $CoresPerSocket
    $TotalThreads   = $TotalCores * $ThreadsPerCore
    $NodesPerSocket = [int]$HostSnc
    $NumNodes       = $NumSockets * $NodesPerSocket
    $CoresPerNode   = [int]($CoresPerSocket / $NodesPerSocket)
    $NodeCoreSets   = @()
    for ($n = 0; $n -lt $NumNodes; $n++) { $NodeCoreSets += ,@(($n * $CoresPerNode)..(($n + 1) * $CoresPerNode - 1)) }
    $ReservePerSocket = if ($EsxiReserveCores -ge 0) { [int]$EsxiReserveCores } else { [int]$Spec.Reserve }
    if ($ReservePerSocket % $NodesPerSocket -ne 0) { Write-Error "소켓당 예약 코어($ReservePerSocket)를 소켓당 노드 수($NodesPerSocket)로 균등 분배할 수 없음. -EsxiReserveCores 조정"; return }
    $ReservePerNode = [int]($ReservePerSocket / $NodesPerSocket)

    # ---- VM 목록 (가상 소켓 수 VS 포함) 과 구조 판정 ----
    #   VS = ceil(vCPU / 노드당 코어), 최대 호스트 노드 수. 덮어쓰기 -PvmVSockets / -SvmVSockets
    $Pfx = if ($NamePrefix -ne "") { $NamePrefix } else { $Global:VmPlan_NamePrefix }
    $PriVMs = @()
    for ($k = 0; $k -lt $NumPvm; $k++) {
        $Nm = if ($PvmNames.Count -gt 0) { $PvmNames[$k] } else { $Pfx + ($Global:VmPlan_NameFormat -f ($k + 1)) }
        $VsAuto = [int][math]::Min([math]::Ceiling($VcpuList[$k] / $CoresPerNode), $NumNodes)
        if ($VsAuto -lt 1) { $VsAuto = 1 }
        $VS = if ($PvmVSockets -gt 0) { [int]$PvmVSockets } else { $VsAuto }
        $PriVMs += [PSCustomObject]@{ Name = $Nm; NumCpu = $VcpuList[$k]; Role = "PVM"; Index = $k; MemGB = $MemList[$k]; VS = $VS }
    }
    $SecVM = $null
    $SvmVsNote = ""
    if ($SvmVcpu -gt 0) {
        $Nm = if ($SvmName -ne "") { $SvmName } else { $Pfx + ($Global:VmPlan_NameFormat -f ($NumPvm + 1)) }
        $VsAutoS = if ($ProfileKey -eq "vm4d" -or ($Spec.SvmScope -eq "host" -and -not $HTEnabled)) { $NumNodes } else { 1 }
        $VS = if ($SvmVSockets -gt 0 -and $ProfileKey -ne "vm4d") { [int]$SvmVSockets } else { $VsAutoS }
        if ($SvmVSockets -gt 0 -and $ProfileKey -eq "vm4d" -and [int]$SvmVSockets -ne $NumNodes) { $SvmVsNote = "vm4d: SVM 가상 소켓 수는 호스트 NUMA 노드 수($NumNodes)로 고정 (전 노드 1:1, 적용 스크립트와 동일). -SvmVSockets $SvmVSockets 무시" }
        $SecVM = [PSCustomObject]@{ Name = $Nm; NumCpu = [int]$SvmVcpu; Role = "SVM"; Index = 0; MemGB = [int]$SvmMemoryGB; VS = $VS }
    }
    $MultiPvm = ($NumPvm -ge 2)
    $SN = $Global:VmPlan_StructureNames
    $StructKey = "SvmOnly"
    if ($NumPvm -eq 1) { $StructKey = if ($SecVM) { "Dual" } else { "PvmOnly" } }
    elseif ($NumPvm -eq 2) { $StructKey = if ($SecVM) { "TwoDual" } else { "Two" } }
    elseif ($NumPvm -ge 3) { $StructKey = if ($SecVM) { "MultiDual" } else { "Multi" } }
    $TopoLabel = "$($SN[$StructKey])" + $(if ($NumPvm -ge 3) { " (PVM $NumPvm 대)" } else { "" })

    # ---- 배치 계산 ----
    $Plan = Get-VmPlanAffinity -Spec $Spec -ProfileKey $ProfileKey -NumSockets $NumSockets -CoresPerSocket $CoresPerSocket -ThreadsPerCore $ThreadsPerCore -HTEnabled $HTEnabled `
        -NodeCoreSets $NodeCoreSets -NumNodes $NumNodes -NodesPerSocket $NodesPerSocket -CoresPerNode $CoresPerNode -ReservePerNode $ReservePerNode -PriVMs $PriVMs -SecVM $SecVM
    if ($Plan.Error -ne "") { Write-Error $Plan.Error; return }
    if ($SvmVsNote -ne "") { $Plan.Notes += $SvmVsNote }

    # Multi VM 순차 고정에서 vNUMA 1노드 PVM 이 NUMA 노드 경계에 걸치면 알림 (값은 바꾸지 않음)
    if ($NumPvm -ge 3 -and $Spec.PvmRule -ne "none") {
        foreach ($P in $Plan.PvmTargets) {
            $a = [int]$P.CoreBase; $b = $a + [int]$P.VM.NumCpu - 1
            $na = [int][math]::Floor($a / $CoresPerNode); $nb = [int][math]::Floor($b / $CoresPerNode)
            if ($na -ne $nb -and [int]$P.VM.VS -eq 1) {
                $Plan.Notes += "$($P.Tag) ($($P.VM.Name)): 고정 코어 $a-$b 가 NUMA 노드 $na/$nb 경계에 걸침. vNUMA 1노드라 메모리 지역성이 떨어짐. PVM vCPU 수나 순서 조정 권장"
            }
        }
    }

    # ---- VM 별 토폴로지와 설정값 ----
    $VmInfo = [ordered]@{}
    foreach ($V in $PriVMs) {
        $NumCpuV = [int]$V.NumCpu
        $VS   = [int]$V.VS
        $Cps  = [int][math]::Ceiling($NumCpuV / $VS)
        $Tgt  = @($Plan.PvmTargets | Where-Object { $_.VM.Name -eq $V.Name })
        $Place = ""
        if ($Spec.PvmRule -eq "none") {
            $Place = if ($ProfileKey -eq "vm4d") { "node affinity" } else { "free float" }
        }
        elseif ($MultiPvm -and $Tgt.Count -gt 0) {
            $a = [int]$Tgt[0].CoreBase; $b = $a + $NumCpuV - 1
            $sa = [int][math]::Floor($a / $CoresPerSocket); $sb = [int][math]::Floor($b / $CoresPerSocket)
            $SockText = if ($sa -eq $sb) { "socket $sa" } else { "sockets $sa-$sb" }
            $Place = "cores $a-$b pinned ($SockText)"
        }
        else {
            $SpanSockets = [int][math]::Ceiling($NumCpuV / $CoresPerSocket)
            $Place = "host cores 0-$($NumCpuV - 1) pinned ($SpanSockets sockets, $VS NUMA nodes)"
        }
        $VmInfo[$V.Name] = @{ Role = "PVM"; NumCpu = $NumCpuV; VS = $VS; Cps = $Cps; MemGB = [int]$V.MemGB; Place = $Place; Divisible = (($NumCpuV % $VS) -eq 0) }
    }
    if ($SecVM) {
        $NumCpuS = [int]$SecVM.NumCpu
        $VS   = [int]$SecVM.VS
        $Cps  = [int][math]::Ceiling($NumCpuS / $VS)
        $PlaceS = switch ($Spec.SvmScope) {
            "node" { "float on $NumNodes NUMA nodes (reserved $ReservePerNode cores/node excluded)" }
            "host" { "float on all cores" }
            default { if ($ProfileKey -eq "vm4d") { "node affinity" } else { "free float" } }
        }
        $VmInfo[$SecVM.Name] = @{ Role = "SVM"; NumCpu = $NumCpuS; VS = $VS; Cps = $Cps; MemGB = [int]$SecVM.MemGB; Place = $PlaceS; Divisible = (($NumCpuS % $VS) -eq 0) }
    }
    $SharesP = "$ShareRatio"; $SharesS = "$ShareRatio"
    if ($ShareRatio -match '^\s*(\d+)\s*:\s*(\d+)\s*$') { $SharesP = "$($Matches[1]) (custom)"; $SharesS = "$($Matches[2]) (custom)" }
    elseif ($ShareRatio -match '^(?i)\s*normal\s*$') { $SharesP = "normal"; $SharesS = "normal" }
    else { Write-Error "-ShareRatio 는 'PVM:SVM' 형식(예 10000:1, 1:1) 또는 normal"; return }
    $LpKeys = @("sched.mem.lpage.enable1GPage", "sched.mem.pin", "sched.mem.prealloc", "sched.mem.prealloc.pinnedMainMem", "sched.swap.vmxSwapEnabled")
    $LpVals = if ($Lpage1GB -eq "on") { @("TRUE", "TRUE", "TRUE", "TRUE", "FALSE") } else { @("(없음)", "(없음)", "(없음)", "(없음)", "(없음)") }
    $VpmcText = if ($Vpmc -eq "on") { "TRUE" } else { "(없음)" }
    $HtText = if ($HTEnabled) { "on" } else { "off" }
    $SncText = if ($NodesPerSocket -gt 1) { "SNC-$NodesPerSocket ($NodesPerSocket nodes/socket)" } else { "disabled (1 node/socket)" }

    # ---- 세로 표 ----
    $VmOrder = @($VmInfo.Keys)
    $Rows = New-Object System.Collections.Generic.List[object]
    $AddRow = {
        param($Group, $Item, $ValueMap)
        $o = [ordered]@{ "구분" = $Group; "항목" = $Item }
        foreach ($Vn in $VmOrder) { $o[$Vn] = $(if ($ValueMap.ContainsKey($Vn)) { "$($ValueMap[$Vn])" } else { "" }) }
        $Rows.Add([PSCustomObject]$o)
    }
    $ByVm = { param($Fn) $m = @{}; foreach ($Vn in $VmOrder) { $m[$Vn] = & $Fn $VmInfo[$Vn] }; return $m }
    $AllVm = { param($Text) $m = @{}; foreach ($Vn in $VmOrder) { $m[$Vn] = $Text }; return $m }

    & $AddRow "호스트 전제" "sockets x cores per socket" (& $AllVm "$NumSockets x $CoresPerSocket")
    & $AddRow "" "Hyperthreading" (& $AllVm $HtText)
    & $AddRow "" "SNC" (& $AllVm $SncText)
    & $AddRow "" "pCPU count" (& $AllVm "$TotalThreads")
    & $AddRow "" "structure / profile" (& $AllVm "$TopoLabel / $ProfileKey")

    & $AddRow "VM 기본 정보" "role" (& $ByVm { param($i) $i.Role })
    & $AddRow "" "cpu" (& $ByVm { param($i) $i.NumCpu })
    & $AddRow "" "cores per socket / sockets" (& $ByVm { param($i) "$($i.Cps) / $($i.VS)" + $(if (-not $i.Divisible) { " (vCPU 가 소켓 수로 안 나뉨)" } else { "" }) })
    & $AddRow "" "vNUMA nodes" (& $ByVm { param($i) "$($i.VS)" })
    & $AddRow "" "memory (GB)" (& $ByVm { param($i) if ($i.MemGB -gt 0) { "$($i.MemGB)" } else { "-" } })
    & $AddRow "" "memory reservation" (& $ByVm { param($i) if ($i.MemGB -gt 0) { "$($i.MemGB) (locked)" } else { "-" } })
    & $AddRow "" "cpu shares" (& $ByVm { param($i) if ($i.Role -eq "PVM") { $SharesP } else { $SharesS } })
    & $AddRow "" "mem shares" (& $ByVm { param($i) if ($i.Role -eq "PVM") { $SharesP } else { $SharesS } })
    & $AddRow "" "physical placement" (& $ByVm { param($i) $i.Place })

    for ($j = 0; $j -lt $LpKeys.Count; $j++) {
        $val = $LpVals[$j]
        & $AddRow $(if ($j -eq 0) { "vm advanced config" } else { "" }) $LpKeys[$j] (& $AllVm $val)
    }
    & $AddRow "" "numa.vcpu.maxPerVirtualNode" (& $ByVm { param($i) "$($i.Cps)" })
    & $AddRow "" "vpmc.enable" (& $AllVm $VpmcText)

    $AllPlanned = @($Plan.Settings) + @($Plan.Extras)
    $KeyOrder = @($AllPlanned | ForEach-Object { $_.Key } | Select-Object -Unique | Sort-Object {
        if ($_ -match '^sched\.vcpu(\d+)\.affinity$') { [int]$Matches[1] }
        elseif ($_ -match '^sched\.node(\d+)\.affinity$') { 10000 + [int]$Matches[1] }
        else { 20000 } })
    $first = $true
    foreach ($K in $KeyOrder) {
        $m = @{}
        foreach ($Vn in $VmOrder) {
            $Hit = @($AllPlanned | Where-Object { $_.VMName -eq $Vn -and $_.Key -eq $K })
            $m[$Vn] = if ($Hit.Count -gt 0) { "$($Hit[0].Value)" } else { "" }
        }
        & $AddRow $(if ($first) { "CPU affinity" } else { "" }) $K $m
        $first = $false
    }
    & $AddRow $(if ($first) { "CPU affinity" } else { "" }) "numa.nodeAffinity" (& $AllVm "(없음)")

    # ---- 출력 ----
    if (-not $Quiet) {
        Write-Host "[VM 배포 계획: $TopoLabel, 프로파일 $ProfileKey, 호스트 $NumSockets 소켓 x $CoresPerSocket 코어, HT $HtText, $SncText, 예약 코어 소켓당 $ReservePerSocket]" -ForegroundColor Green
        $Rows | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
        foreach ($Nt in $Plan.Notes) { Write-Host "▶ $Nt" -ForegroundColor Yellow }
        if ($NodesPerSocket -gt 1 -and $NumPvm -gt 0) {
            Write-Host "▶ SNC 호스트: VM 의 가상 소켓 수(vNUMA 노드 수)는 SNC 노드 기준 (vSphere 자동 크기 산정과 같음). 물리 소켓 기준으로 두려면 -PvmVSockets 지정" -ForegroundColor DarkGray
        }
        if ($NumPvm -ge 3 -and $Spec.PvmRule -ne "none") {
            Write-Host "▶ 값은 SetVcpuAffinityProfile v3.10 과 같은 규칙으로 계산(Multi VM PVM 은 코어 0 부터 순차)" -ForegroundColor Yellow
        }
        $NameHint = ""
        if ($PriVMs.Count -gt 0) { $NameHint += " -pvms " + (($PriVMs | ForEach-Object { $_.Name }) -join ",") }
        if ($SecVM) { $NameHint += " -svm " + $SecVM.Name }
        $ShareHint = if ($SharesP -eq "normal") { "-SharesLevel normal" } else { "-ShareRatio $ShareRatio" }
        $LpHint = if ($Lpage1GB -eq "on") { "-Default" } else { "-Lpage1GB off -MemFullReservation true" }
        $VpmcHint = if ($Vpmc -eq "on") { ' -ExtraConfig @{ "vpmc.enable" = "TRUE" }' } else { "" }
        Write-Host "실제 호스트 적용 명령 (VM 생성 뒤, VM 이름을 실제 이름으로):" -ForegroundColor DarkGray
        Write-Host "  Set-VmProfile -VMHostName <호스트> $LpHint $ShareHint$VpmcHint" -ForegroundColor DarkGray
        Write-Host "  Set-VcpuAffinityProfile -ProfileName $ProfileKey$NameHint -VMHostName <호스트>" -ForegroundColor DarkGray
    }
    if ($OutDir -ne "") {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        $Stamp = (Get-Date).ToString("yyyyMMdd-HHmm")
        $File  = Join-Path $OutDir ("deploy_plan_{0}_{1}s{2}c_ht{3}_snc{4}_{5}.csv" -f $ProfileKey, $NumSockets, $CoresPerSocket, $HtText, $NodesPerSocket, $Stamp)
        $Enc   = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $Rows | Export-Csv -LiteralPath $File -NoTypeInformation -Encoding $Enc
        if (-not $Quiet) { Write-Host "[저장] $File" -ForegroundColor Green }
    }
    if ($PassThru) { return $Rows }
}


function Test-VmDeployPlan {
    # 규칙 자체 검증. 기대값은 규칙 모델에서 산출한 값 (2소켓 8코어 기준, pCPU = 코어 x 2 + 스레드)
    # 기대값 "" = 그 키(행)를 설정하지 않음
    $H = @{ HostSockets = 2; HostCoresPerSocket = 8 }
    $Cases = @(
        @{ Name = "C1 PVM only 16 / rev12";          Args = $H + @{ Profile = "rev12"; PvmVcpu = @(16) }
           Expect = @{ "ev01|sched.vcpu0.affinity" = "0,1"; "ev01|sched.vcpu15.affinity" = "30,31"; "ev01|cores per socket / sockets" = "8 / 2"; "ev01|vNUMA nodes" = "2"; "ev01|vpmc.enable" = "(없음)"; "ev01|structure / profile" = "PVM 단독 / rev12" } },
        @{ Name = "C1 PVM only 16 / vm4d";           Args = $H + @{ Profile = "vm4d"; PvmVcpu = @(16) }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev01|sched.node1.affinity" = "1"; "ev01|numa.vcpu.maxPerVirtualNode" = "8" } },
        @{ Name = "C2 Dual VM 16+4 / rev12 (SVM 가상 소켓 1개 = 합친 값)"; Args = $H + @{ Profile = "rev12"; PvmVcpu = @(16); SvmVcpu = 4 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev02|sched.vcpu1.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev02|sched.vcpu2.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev02|sched.vcpu3.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev02|cores per socket / sockets" = "4 / 1"; "ev01|structure / profile" = "Dual VM / rev12" } },
        @{ Name = "C2 Dual VM 16+4 / rev12 (SvmVSockets 2 = 시트 2절의 값)"; Args = $H + @{ Profile = "rev12"; PvmVcpu = @(16); SvmVcpu = 4; SvmVSockets = 2 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,27,25,30,28,26,24"; "ev02|sched.vcpu1.affinity" = "31,29,27,25,30,28,26,24"; "ev02|sched.vcpu2.affinity" = "15,13,11,9,14,12,10,8"; "ev02|sched.vcpu3.affinity" = "15,13,11,9,14,12,10,8"; "ev02|cores per socket / sockets" = "2 / 2"; "ev02|numa.vcpu.maxPerVirtualNode" = "2" } },
        @{ Name = "C2 Dual VM 16+4 / vm4d (SvmVSockets 1 무시)"; Args = $H + @{ Profile = "vm4d"; PvmVcpu = @(16); SvmVcpu = 4; SvmVSockets = 1 }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev01|sched.node1.affinity" = "1"; "ev02|sched.node0.affinity" = "0"; "ev02|sched.node1.affinity" = "1"; "ev02|cores per socket / sockets" = "2 / 2"; "ev01|sched.vcpu0.affinity" = "" } },
        @{ Name = "C3 Two VM 8,8 / rev12";           Args = $H + @{ Profile = "rev12"; PvmVcpu = @(8, 8) }
           Expect = @{ "ev01|sched.vcpu0.affinity" = "0,1"; "ev01|sched.vcpu7.affinity" = "14,15"; "ev02|sched.vcpu0.affinity" = "16,17"; "ev02|sched.vcpu7.affinity" = "30,31"; "ev01|cores per socket / sockets" = "8 / 1"; "ev01|structure / profile" = "Two VM / rev12" } },
        @{ Name = "C3 Two VM 8,8 / vm4d";            Args = $H + @{ Profile = "vm4d"; PvmVcpu = @(8, 8) }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev02|sched.node0.affinity" = "1"; "ev01|sched.node1.affinity" = "" } },
        @{ Name = "C4 Two Dual VM 8,8+4 / rev12";    Args = $H + @{ Profile = "rev12"; PvmVcpu = @(8, 8); SvmVcpu = 4 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "16,17"; "ev03|sched.vcpu0.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev03|sched.vcpu3.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev01|structure / profile" = "Two Dual VM / rev12" } },
        @{ Name = "C4 Two Dual VM 8,8+4 / vm4d";     Args = $H + @{ Profile = "vm4d"; PvmVcpu = @(8, 8); SvmVcpu = 4 }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev02|sched.node0.affinity" = "1"; "ev03|sched.node0.affinity" = "0"; "ev03|sched.node1.affinity" = "1" } },
        @{ Name = "C5 Multi VM 6x2 / rev12 (순차)";   Args = $H + @{ Profile = "rev12"; PvmCount = 6; PvmVcpu = @(2) }
           Expect = @{ "ev01|sched.vcpu0.affinity" = "0,1"; "ev01|sched.vcpu1.affinity" = "2,3"; "ev02|sched.vcpu0.affinity" = "4,5"; "ev02|sched.vcpu1.affinity" = "6,7"; "ev03|sched.vcpu0.affinity" = "8,9"; "ev04|sched.vcpu0.affinity" = "12,13"; "ev05|sched.vcpu0.affinity" = "16,17"; "ev05|sched.vcpu1.affinity" = "18,19"; "ev06|sched.vcpu0.affinity" = "20,21"; "ev06|sched.vcpu1.affinity" = "22,23"; "ev01|cores per socket / sockets" = "2 / 1"; "ev01|vNUMA nodes" = "1"; "ev01|numa.vcpu.maxPerVirtualNode" = "2"; "ev01|structure / profile" = "Multi VM (PVM 6 대) / rev12" } },
        @{ Name = "C5 Multi VM 6x2 / vm4d (홀짝)";    Args = $H + @{ Profile = "vm4d"; PvmCount = 6; PvmVcpu = @(2) }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev02|sched.node0.affinity" = "1"; "ev03|sched.node0.affinity" = "0"; "ev04|sched.node0.affinity" = "1"; "ev05|sched.node0.affinity" = "0"; "ev06|sched.node0.affinity" = "1"; "ev01|sched.node1.affinity" = "" } },
        @{ Name = "C6 Multi VM 8x2 / rev12 (순차)";   Args = $H + @{ Profile = "rev12"; PvmCount = 8; PvmVcpu = @(2) }
           Expect = @{ "ev04|sched.vcpu1.affinity" = "14,15"; "ev05|sched.vcpu0.affinity" = "16,17"; "ev07|sched.vcpu0.affinity" = "24,25"; "ev07|sched.vcpu1.affinity" = "26,27"; "ev08|sched.vcpu0.affinity" = "28,29"; "ev08|sched.vcpu1.affinity" = "30,31" } },
        @{ Name = "C6 Multi VM 8x2 / vm4d (홀짝)";    Args = $H + @{ Profile = "vm4d"; PvmCount = 8; PvmVcpu = @(2) }
           Expect = @{ "ev07|sched.node0.affinity" = "0"; "ev08|sched.node0.affinity" = "1" } },
        @{ Name = "C7 Multi Dual VM 6x2+4 / rev12";  Args = $H + @{ Profile = "rev12"; PvmCount = 6; PvmVcpu = @(2); SvmVcpu = 4 }
           Expect = @{ "ev06|sched.vcpu0.affinity" = "20,21"; "ev07|sched.vcpu0.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev07|sched.vcpu2.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev01|structure / profile" = "Multi Dual VM (PVM 6 대) / rev12" } },
        @{ Name = "C7 Multi Dual VM 6x2+4 / vm4d";   Args = $H + @{ Profile = "vm4d"; PvmCount = 6; PvmVcpu = @(2); SvmVcpu = 4 }
           Expect = @{ "ev05|sched.node0.affinity" = "0"; "ev06|sched.node0.affinity" = "1"; "ev07|sched.node0.affinity" = "0"; "ev07|sched.node1.affinity" = "1"; "ev07|cores per socket / sockets" = "2 / 2" } },
        @{ Name = "C8 SNC-2 Dual VM 16+4 / rev12 (SVM 가상 소켓 1개 = 4노드 합친 값)"; Args = $H + @{ Profile = "rev12"; HostSnc = 2; PvmVcpu = @(16); SvmVcpu = 4 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,30,28,23,21,22,20,15,13,14,12,7,5,6,4"; "ev02|sched.vcpu1.affinity" = "31,29,30,28,23,21,22,20,15,13,14,12,7,5,6,4"; "ev02|sched.vcpu2.affinity" = "31,29,30,28,23,21,22,20,15,13,14,12,7,5,6,4"; "ev02|sched.vcpu3.affinity" = "31,29,30,28,23,21,22,20,15,13,14,12,7,5,6,4"; "ev01|SNC" = "SNC-2 (2 nodes/socket)"; "ev01|cores per socket / sockets" = "4 / 4"; "ev01|numa.vcpu.maxPerVirtualNode" = "4" } },
        @{ Name = "C8 SNC-2 Dual VM 16+4 / rev12 (SvmVSockets 2 = 소켓별 2노드 합친 값)"; Args = $H + @{ Profile = "rev12"; HostSnc = 2; PvmVcpu = @(16); SvmVcpu = 4; SvmVSockets = 2 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,30,28,23,21,22,20"; "ev02|sched.vcpu1.affinity" = "31,29,30,28,23,21,22,20"; "ev02|sched.vcpu2.affinity" = "15,13,14,12,7,5,6,4"; "ev02|sched.vcpu3.affinity" = "15,13,14,12,7,5,6,4"; "ev02|cores per socket / sockets" = "2 / 2" } },
        @{ Name = "C8 SNC-2 Dual VM 16+4 / rev12 (SvmVSockets 4 = 노드별)"; Args = $H + @{ Profile = "rev12"; HostSnc = 2; PvmVcpu = @(16); SvmVcpu = 4; SvmVSockets = 4 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,30,28"; "ev02|sched.vcpu1.affinity" = "23,21,22,20"; "ev02|sched.vcpu2.affinity" = "15,13,14,12"; "ev02|sched.vcpu3.affinity" = "7,5,6,4"; "ev02|cores per socket / sockets" = "1 / 4" } },
        @{ Name = "C8 SNC-2 Dual VM 16+4 / vm4d";    Args = $H + @{ Profile = "vm4d"; HostSnc = 2; PvmVcpu = @(16); SvmVcpu = 4 }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev01|sched.node3.affinity" = "3"; "ev02|sched.node2.affinity" = "2"; "ev02|cores per socket / sockets" = "1 / 4" } },
        @{ Name = "C9 HT off Dual VM 16+4 / rev12";  Args = $H + @{ Profile = "rev12"; HostHT = "off"; PvmVcpu = @(16); SvmVcpu = 4 }
           Expect = @{ "ev01|sched.vcpu0.affinity" = "0"; "ev01|sched.vcpu15.affinity" = "15"; "ev02|sched.vcpu0.affinity" = "15,14,13,12,7,6,5,4"; "ev02|sched.vcpu2.affinity" = "15,14,13,12,7,6,5,4"; "ev01|pCPU count" = "16" } },
        @{ Name = "C10 SVM only 4 / rev12";          Args = $H + @{ Profile = "rev12"; SvmVcpu = 4 }
           Expect = @{ "ev01|sched.vcpu0.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev01|sched.vcpu3.affinity" = "31,29,27,25,30,28,26,24,15,13,11,9,14,12,10,8"; "ev01|structure / profile" = "SVM 단독 / rev12" } },
        @{ Name = "C11 SNC-2 Multi VM 6x2 / vm4d (노드 라운드로빈)"; Args = $H + @{ Profile = "vm4d"; HostSnc = 2; PvmCount = 6; PvmVcpu = @(2) }
           Expect = @{ "ev01|sched.node0.affinity" = "0"; "ev01|sched.node1.affinity" = ""; "ev02|sched.node0.affinity" = "1"; "ev03|sched.node0.affinity" = "2"; "ev04|sched.node0.affinity" = "3"; "ev05|sched.node0.affinity" = "0"; "ev06|sched.node0.affinity" = "1" } },
        @{ Name = "C12 rev11 Dual VM 16+4 (SVM 가상 소켓 1개 = 합친 값)"; Args = $H + @{ Profile = "rev11"; PvmVcpu = @(16); SvmVcpu = 4 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,27,25,15,13,11,9"; "ev02|sched.vcpu1.affinity" = "31,29,27,25,15,13,11,9"; "ev02|sched.vcpu2.affinity" = "31,29,27,25,15,13,11,9"; "ev02|sched.vcpu3.affinity" = "31,29,27,25,15,13,11,9" } },
        @{ Name = "C12 rev11 Dual VM 16+4 (SvmVSockets 2, 예약 2코어 = 시트 3절의 값)"; Args = $H + @{ Profile = "rev11"; PvmVcpu = @(16); SvmVcpu = 4; SvmVSockets = 2; EsxiReserveCores = 2 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,27,25,23,21"; "ev02|sched.vcpu1.affinity" = "31,29,27,25,23,21"; "ev02|sched.vcpu2.affinity" = "15,13,11,9,7,5"; "ev02|sched.vcpu3.affinity" = "15,13,11,9,7,5"; "ev02|cores per socket / sockets" = "2 / 2" } },
        @{ Name = "C15 rev11 Dual VM 8+2 (SVM 1소켓 2 vCPU: 두 vCPU 가 같은 값)"; Args = $H + @{ Profile = "rev11"; PvmVcpu = @(8); SvmVcpu = 2 }
           Expect = @{ "ev02|sched.vcpu0.affinity" = "31,29,27,25,15,13,11,9"; "ev02|sched.vcpu1.affinity" = "31,29,27,25,15,13,11,9"; "ev02|cores per socket / sockets" = "2 / 1"; "ev02|vNUMA nodes" = "1" } },
        @{ Name = "C13 options: share 1:1, lpage off, vpmc off"; Args = $H + @{ Profile = "rev12"; PvmVcpu = @(16); SvmVcpu = 4; ShareRatio = "1:1"; Lpage1GB = "off"; Vpmc = "off"; PvmMemoryGB = @(1540); SvmMemoryGB = 112 }
           Expect = @{ "ev01|cpu shares" = "1 (custom)"; "ev02|mem shares" = "1 (custom)"; "ev01|sched.mem.lpage.enable1GPage" = "(없음)"; "ev02|sched.swap.vmxSwapEnabled" = "(없음)"; "ev01|vpmc.enable" = "(없음)"; "ev01|memory reservation" = "1540 (locked)"; "ev02|memory (GB)" = "112" } },
        @{ Name = "C14 options: share normal, vpmc on"; Args = $H + @{ Profile = "rev12"; PvmVcpu = @(8, 8); ShareRatio = "normal"; Vpmc = "on" }
           Expect = @{ "ev01|cpu shares" = "normal"; "ev02|mem shares" = "normal"; "ev01|sched.mem.pin" = "TRUE"; "ev01|vpmc.enable" = "TRUE" } }
    )
    $Fail = 0
    foreach ($C in $Cases) {
        $CaseArgs = $C.Args
        $Rows = New-VmDeployPlan @CaseArgs -PassThru -Quiet
        $Lookup = @{}
        foreach ($R in @($Rows)) {
            foreach ($Prop in $R.PSObject.Properties) {
                if ($Prop.Name -ne "구분" -and $Prop.Name -ne "항목") { $Lookup["$($Prop.Name)|$($R.'항목')"] = "$($Prop.Value)" }
            }
        }
        $Bad = @()
        foreach ($Ek in $C.Expect.Keys) {
            $Got = if ($Lookup.ContainsKey($Ek)) { $Lookup[$Ek] } else { "" }
            if ($Got -ne $C.Expect[$Ek]) { $Bad += "$Ek : 기대 '$($C.Expect[$Ek])' 결과 '$Got'" }
        }
        if ($Bad.Count -eq 0) { Write-Host "[PASS] $($C.Name)" -ForegroundColor Green }
        else { $Fail++; Write-Host "[FAIL] $($C.Name)" -ForegroundColor Red; foreach ($B in $Bad) { Write-Host "       $B" -ForegroundColor Red } }
    }
    if ($Fail -eq 0) { Write-Host "RESULT: 전체 통과 ($($Cases.Count)건)" -ForegroundColor Green } else { Write-Host "RESULT: 실패 $Fail 건" -ForegroundColor Red }
}

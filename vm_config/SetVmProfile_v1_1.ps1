# ==============================================================================
# SetVmProfile  v1.1 (2026-10-27)
#   변경 이력: 2026-09-28 v1.0 확정 (출력 형식, sched.mem.pin 처리, ReconfigVM 1회 적용)
#             2026-10-27 v1.0 -> v1.1: 적용 전 변경 항목 표시와 -Detail 적용 전 표, -WhatIf 결과 반환 수정
#
#   VM 생성 뒤 실행 설정을 적용한다 (PowerCLI, vCenter 연결 필요). 읽기, 계획, 적용, 적용 후 검증 순.
#   affinity 키(sched.vcpuN.affinity 등)는 만지지 않는다 (SetVcpuAffinityProfile 담당).
#
#   [함수]
#     Set-VmType       VM 에 VM_TYPE(PVM/SVM) 태그를 붙인다. DEPT_NAME, PURPOSE 는 생략하면 설정 블록 기본값(AI센터, PoC)
#     Set-VmProfile    설정 적용. 지정한 항목만 적용하며, 기적용 항목은 건너뛴다
#     Test-VmProfile   현재 상태를 표로 보여 주고 -Default 항목(lpage 5키, 메모리 전량 예약)과 대조한다
#
#   [Set-VmType 옵션]
#     -VMHostName <패턴,…>   호스트 이름. 와일드카드 * ? [1-8] 가능, 여러 개 쉼표
#     -VMName <패턴,…>       VM 이름 패턴. 호스트를 안 주면 vCenter 전체에서 찾는다
#     -Type PVM|SVM          VM_TYPE 값 (필수)
#     -Dept <값>             DEPT_NAME. 생략 = 기본값 AI센터
#     -Purpose <값>          PURPOSE.   생략 = 기본값 PoC
#     -TypeOnly              VM_TYPE 만 쓰고 DEPT_NAME, PURPOSE 는 건드리지 않음
#     -CreateAttributes      속성 정의(VM_TYPE 등)가 vCenter 에 없으면 만든다
#
#   [Set-VmProfile 옵션]  ※ 아무것도 안 주면 오류. 지정한 항목만 적용
#     -VMHostName / -VMName  대상 (Set-VmType 과 동일)
#     -Default               VM_TYPE 태그별 기본 프로파일: 1GB lpage 5키 + 메모리 전량 예약 + DEPT_NAME, PURPOSE 기본값
#                            (shares 는 포함하지 않음 - 아래 shares 옵션으로 지정)
#     -Role PVM|SVM          태그 대신 역할 강제 (태그 없는 VM 에 -Default 줄 때)
#     -TagPvm <패턴,…>       이 패턴의 대상 VM 에 먼저 VM_TYPE=PVM 태그 후 진행 (Set-VmType 을 한 명령에 합친 것)
#     -TagSvm <패턴,…>       같은 방식으로 SVM
#     -Sockets <n>           가상 소켓 수        ┐ 셋 중 둘을 주면 나머지 산출. 셋 다 주면 곱이 맞아야 함.
#     -CoresPerSocket <n>    소켓당 코어 수      │ 하나만 주면 VM 현재 vCPU 와 조합. 오류는 메시지 후 중단.
#     -Cpu <n>               vCPU 수             ┘ 지정하면 numa.vcpu.maxPerVirtualNode 도 소켓당 코어로 기록
#     -MemoryGB <n>          메모리 크기 (GB)
#     -ShareRatio <PVM>:<SVM>  역할별 CPU, 메모리 shares 값. SharesLevel 은 custom 으로 기록. 예 10000:1, 100:1
#     -CpuShares <n> / -MemShares <n>  역할 무관 shares 값 직접 지정. SharesLevel 은 custom 으로 기록
#     -SharesLevel normal|custom  vSphere 의 Shares 설정에 있는 Level 값. normal = vSphere 가 vCPU 수에 비례해 정하는 자동값,
#                                 custom = 위 shares 값 옵션으로 직접 지정 (값 옵션을 주면 custom 은 자동)
#     -MemFullReservation true|false  메모리 전량 예약 (vSphere MemoryReservationLockedToMax)
#     -Lpage1GB on|off       1GB lpage 5키 적용(on) / 5키를 고급 설정에서 삭제(off)
#     -ExtraConfig @{키=값}  임의 고급 설정 추가, 변경
#     -RemoveExtraConfig <키,…>  임의 고급 설정 키 삭제
#     -ResetAdvanced         이 스크립트가 쓰는 고급 설정 키 전부 삭제 (lpage 5키 + numa.vcpu.maxPerVirtualNode)
#     -Dept / -Purpose       속성 값. -Default 일 때 생략하면 기본값(AI센터, PoC), -Default 없이는 준 것만
#     -AttributesOnly        속성만 적용 (켜진 VM 허용)
#     -CreateAttributes      속성 정의가 없으면 만든다
#     -Detail                계획, 결과를 VM×항목 전체 행 표로도 출력 (기본은 '항목 = 값 : 적용 n대' 와 미적용 VM 별 사유만)
#     -ShowUnchanged         (-Detail 과 함께) 기적용이라 건너뛰는 항목까지 표시
#     -PassThru              결과 행 객체(Host, VM, 항목, 이전, 이후, 목표, 작업, 판정)를 반환. 기본은 화면 출력만
#                            (미지정 시 반환 없음. 반환 객체가 있으면 PowerShell 이 항목마다 세로 목록으로 다시 찍어 화면이 길어짐)
#     -WhatIf                계획표만 출력, 적용 없음
#
#   [초기화 조합 예]
#     고급 설정 키 삭제 + shares normal + 전량 예약 해제:
#       Set-VmProfile -VMName tstev01 -ResetAdvanced -SharesLevel normal -MemFullReservation false
#     affinity 키까지 지우려면 별도로: Set-VcpuAffinityProfile -ProfileName clear -pvm tstev01 -VMHostName <호스트>
#
#   [커스텀 속성]  VM_TYPE (PVM/SVM), DEPT_NAME (기본 AI센터), PURPOSE (기본 PoC). 이름은 설정 블록 $VmProfile_Attr
#   [고급 설정 판독]  Get-AdvancedSetting 과 VM 구성 ExtraConfig 를 합쳐 읽는다.
#                    sched.mem.pin 은 vCenter 가 값을 돌려주지 않아 조회할 수 없다. 기록은 다른 1GB lpage 키와 함께 하고,
#                    판정은 다른 키 상태로 간주하며 결과 표에는 '조회 불가' 로 표시한다.
#   [고급 설정 기록, 삭제]  기록과 삭제(빈값 기록)를 한 spec 에 모아 VM 당 ReconfigVM 1회로 끝낸다.
#                    sched.mem.pin 은 삭제 요청에 함께 넣지만 API 로는 지워지지 않으므로 vmx 에서 제거한다.
#   [vNUMA]  vCPU Topology 화면의 NUMA 노드 수는 이 스크립트가 바꾸지 않는다 (vSphere API numaInfo 미지원).
#            토폴로지 지정 시 numa.vcpu.maxPerVirtualNode(소켓당 코어) 만 함께 기록한다. UI 에서 수동 지정한 NUMA 노드 수는 UI 에서 바꾼다.
#   [전원]  shares, 메모리 전량 예약, 속성은 켜진 VM 에도 적용. vCPU/소켓/메모리 크기/고급 설정 키는
#           끈 상태가 필요해, 켜진 VM 에 그런 변경이 있으면 항목을 표시하고 중단한다 (끈 뒤 재실행).
#
#   [사용 흐름]
#     1) Set-VmType   -VMHostName esx0* -VMName *ev0[1-8] -Type PVM
#        Set-VmType   -VMHostName esx0* -VMName *ev09      -Type SVM
#     2) Set-VmProfile -VMHostName esx0* -Default -ShareRatio 10000:1
#     한 번에: Set-VmProfile -VMHostName esx0* -TagPvm *ev0[1-8] -TagSvm *ev09 -Default -ShareRatio 10000:1
#     토폴로지: Set-VmProfile -VMName esx01ev01 -Sockets 2 -CoresPerSocket 8 -MemoryGB 1540
#     확인만:   Test-VmProfile -VMHostName esx0*
#
#   값 우선순위 : 명령줄 지정값 > (-Default 일 때) 역할 프로파일 > 현재값 유지
# ==============================================================================

# ---- [A] 설정 블록 - 값, 키 추가는 여기만 고친다 -------------------------------
# 1GB lpage 관련 키 5종 (전 역할 공통). 키를 더하거나 값을 바꾸면 -Default 에 그대로 반영
$Global:VmProfile_CommonExtraConfig = [ordered]@{
    "sched.mem.lpage.enable1GPage"     = "TRUE"
    "sched.mem.pin"                    = "TRUE"
    "sched.mem.prealloc"               = "TRUE"
    "sched.mem.prealloc.pinnedMainMem" = "TRUE"
    "sched.swap.vmxSwapEnabled"        = "FALSE"
}

# 역할별 기본 프로파일 (-Default). shares 는 여기 넣지 않는다 - 실행 시 -ShareRatio 등으로 지정
$Global:VmProfile_Defaults = @{
    PVM = @{ MemFullReservation = $true }
    SVM = @{ MemFullReservation = $true }
}

# 토폴로지를 지정할 때 자동으로 따라가는 키 (값 = 소켓당 코어 수)
$Global:VmProfile_TopologyExtraKey = "numa.vcpu.maxPerVirtualNode"

# vCenter 가 값을 돌려주지 않아 조회할 수 없는 키 - 판정은 다른 1GB lpage 키 상태로 간주, 삭제는 vmx 에서
$Global:VmProfile_VmxOnlyKeys = @("sched.mem.pin")

# 커스텀 속성 이름
$Global:VmProfile_Attr = @{ Type = "VM_TYPE"; Dept = "DEPT_NAME"; Purpose = "PURPOSE" }
# 커스텀 속성 기본값 - Set-VmType 과 Set-VmProfile -Default 가 -Dept/-Purpose 를 안 주면 이 값을 쓴다
$Global:VmProfile_AttrDefaults = @{ Dept = "AI센터"; Purpose = "PoC" }

# VM_TYPE 값에서 역할 판정: 값에 PVM 이 들어 있으면 PVM, SVM 이 들어 있으면 SVM (대소문자 무시)
$Global:VmProfile_RoleMatch = @( @{ Match = "PVM"; Role = "PVM" }, @{ Match = "SVM"; Role = "SVM" } )
# 계획표, 결과표에 쓰는 항목 표시 이름
$Global:VmProfile_ItemLabel = @{
    Cpu = "vCPU 수"; Sockets = "소켓 수"; CoresPerSocket = "소켓당 코어"; MemoryGB = "메모리(GB)"
    CpuShares = "CPU shares"; MemShares = "메모리 shares"; MemFullReservation = "메모리 전량 예약"
    "numa.vcpu.maxPerVirtualNode" = "vNUMA 노드당 최대 vCPU (numa.vcpu.maxPerVirtualNode)"
}
# ---- 설정 블록 끝 ---------------------------------------------------------------


function Get-VmProfileTargets {
    # 호스트(와일드카드, 복수)와 VM 이름 패턴(와일드카드, 복수)으로 대상 VM 을 고른다.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)] [string[]]$VMHostName = @(),
        [Parameter(Mandatory=$false)] [string[]]$VMName = @()
    )
    $Vms = @()
    if ($VMHostName.Count -gt 0) {
        $Hosts = @()
        foreach ($Pat in $VMHostName) {
            $F = @(Get-VMHost -Name $Pat -ErrorAction SilentlyContinue)
            if ($F.Count -eq 0) { Write-Warning "호스트 '$Pat' 없음" }
            $Hosts += $F
        }
        $Hosts = @($Hosts | Sort-Object Name -Unique)
        foreach ($H in $Hosts) { $Vms += @(Get-VM -Location $H -ErrorAction SilentlyContinue) }
    }
    else {
        if ($VMName.Count -eq 0) { Write-Error "-VMHostName 또는 -VMName 중 하나는 필요합니다."; return @() }
        $Vms = @(Get-VM -ErrorAction SilentlyContinue)
    }
    if ($VMName.Count -gt 0) {
        $Vms = @($Vms | Where-Object { $v = $_; @($VMName | Where-Object { $v.Name -like $_ }).Count -gt 0 })
    }
    return @($Vms | Sort-Object { $_.VMHost.Name }, Name -Unique)
}


function Get-VmRole {
    # VM_TYPE 커스텀 속성 값으로 역할(PVM/SVM)을 돌려준다. 없거나 판정 불가면 "".
    [CmdletBinding()]
    param ([Parameter(Mandatory=$true)] $VM)
    $A = Get-Annotation -Entity $VM -CustomAttribute $Global:VmProfile_Attr.Type -ErrorAction SilentlyContinue | Select-Object -First 1
    $Val = if ($A) { "$($A.Value)" } else { "" }
    foreach ($R in $Global:VmProfile_RoleMatch) {
        if ($Val.ToUpper().Contains($R.Match.ToUpper())) { return $R.Role }
    }
    return ""
}


function Set-VmType {
    # 1단계: VM_TYPE (PVM/SVM) 태그와 선택적으로 DEPT_NAME, PURPOSE 를 붙인다. 전원 상태 무관.
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$false)] [string[]]$VMHostName = @(),
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),
        [Parameter(Mandatory=$true)] [ValidateSet("PVM","SVM")] [string]$Type,
        [Parameter(Mandatory=$false, HelpMessage="DEPT_NAME 값. 생략 시 설정 블록 기본값")] [string]$Dept = "",
        [Parameter(Mandatory=$false, HelpMessage="PURPOSE 값. 생략 시 설정 블록 기본값")] [string]$Purpose = "",
        [Parameter(Mandatory=$false, HelpMessage="DEPT_NAME, PURPOSE 는 건드리지 않고 VM_TYPE 만")] [switch]$TypeOnly,
        [Parameter(Mandatory=$false, HelpMessage="속성 정의가 vCenter 에 없으면 만든다")] [switch]$CreateAttributes
    )
    $Vms = Get-VmProfileTargets -VMHostName $VMHostName -VMName $VMName
    if ($Vms.Count -eq 0) { Write-Error "대상 VM 없음"; return }
    if (-not $TypeOnly) {
        if (-not $Dept)    { $Dept    = $Global:VmProfile_AttrDefaults.Dept }
        if (-not $Purpose) { $Purpose = $Global:VmProfile_AttrDefaults.Purpose }
    } else { $Dept = ""; $Purpose = "" }

    foreach ($Name in @($Global:VmProfile_Attr.Type, $Global:VmProfile_Attr.Dept, $Global:VmProfile_Attr.Purpose)) {
        $Def = Get-CustomAttribute -Name $Name -TargetType VirtualMachine -ErrorAction SilentlyContinue
        if (-not $Def) {
            if ($CreateAttributes) { New-CustomAttribute -TargetType VirtualMachine -Name $Name -ErrorAction Stop | Out-Null; Write-Host "▶ 커스텀 속성 정의 생성: $Name" -ForegroundColor DarkGray }
            elseif ($Name -eq $Global:VmProfile_Attr.Type -or ($Name -eq $Global:VmProfile_Attr.Dept -and $Dept) -or ($Name -eq $Global:VmProfile_Attr.Purpose -and $Purpose)) {
                Write-Error "커스텀 속성 정의 '$Name' 이 vCenter 에 없습니다. -CreateAttributes 로 만들거나 vCenter 에서 먼저 정의하십시오."; return
            }
        }
    }

    $DeptTag = if ($Dept -and $Dept -eq $Global:VmProfile_AttrDefaults.Dept -and -not $PSBoundParameters.ContainsKey("Dept")) { " (기본값)" } else { "" }
    $PurTag  = if ($Purpose -and $Purpose -eq $Global:VmProfile_AttrDefaults.Purpose -and -not $PSBoundParameters.ContainsKey("Purpose")) { " (기본값)" } else { "" }
    Write-Host "`n[태그 대상 $($Vms.Count)대] VM_TYPE=$Type$(if ($Dept) { " DEPT_NAME=$Dept$DeptTag" })$(if ($Purpose) { " PURPOSE=$Purpose$PurTag" })" -ForegroundColor Cyan
    $Vms | Select-Object @{n="Host";e={$_.VMHost.Name}}, Name, PowerState, @{n="현재 VM_TYPE";e={ (Get-Annotation -Entity $_ -CustomAttribute $Global:VmProfile_Attr.Type -ErrorAction SilentlyContinue).Value }} | Format-Table -AutoSize | Out-String | Write-Host
    if (-not $PSCmdlet.ShouldProcess("VM $($Vms.Count)대", "VM_TYPE=$Type 태그")) { return }
    $Ans = Read-Host "위 VM 에 태그를 적용합니까? (y/n)"
    if ($Ans -notmatch '^y') { Write-Host "취소" -ForegroundColor Yellow; return }

    $Rows = @()
    foreach ($V in $Vms) {
        try {
            Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Type -Value $Type -ErrorAction Stop | Out-Null
            if ($Dept)    { Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Dept    -Value $Dept    -ErrorAction Stop | Out-Null }
            if ($Purpose) { Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Purpose -Value $Purpose -ErrorAction Stop | Out-Null }
            $Now = (Get-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Type -ErrorAction SilentlyContinue).Value
            $Rows += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; VM_TYPE = "$Now"; Result = $(if ("$Now" -eq $Type) { "OK" } else { "DIFF" }) }
        }
        catch { $Rows += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; VM_TYPE = ""; Result = "FAIL: $($_.Exception.Message)" } }
    }
    $Rows | Format-Table -AutoSize | Out-String | Write-Host
    return $Rows
}


function Test-VmTopologyInput {
    # 소켓 수, 소켓당 코어, vCPU 입력을 검증하고 빠진 값을 산출한다.
    #   둘을 주면 나머지 하나 산출, 하나만 주면 VM 현재값과 조합, 셋 다 주면 곱 일치 검사.
    # 반환 : @{ Ok=$true; Sockets; CoresPerSocket; Cpu; Warn=@() } 또는 @{ Ok=$false; Error="..." }
    [CmdletBinding()]
    param (
        [int]$Sockets = 0, [int]$CoresPerSocket = 0, [int]$Cpu = 0,
        [int]$CurrentCpu = 0, [int]$CurrentCoresPerSocket = 0,
        [int]$HostSockets = 0, [int]$HostCoresPerSocket = 0, [int]$HostThreads = 0
    )
    $Err = { param($m) return @{ Ok = $false; Error = $m } }
    foreach ($Pair in @(@("Sockets",$Sockets), @("CoresPerSocket",$CoresPerSocket), @("Cpu",$Cpu))) {
        if ($Pair[1] -lt 0) { return (& $Err "-$($Pair[0]) 는 1 이상이어야 합니다 (입력 $($Pair[1]))") }
    }
    $S = $Sockets; $C = $CoresPerSocket; $N = $Cpu
    # 주의: PowerShell 은 쉼표가 비교 연산자보다 먼저 묶인다. @($S -gt 0, $C -gt 0) 처럼 쓰면
    #       $S -gt (0, $C) 로 해석돼 잘못 센다. 하나씩 센다.
    $Given = 0
    if ($S -gt 0) { $Given++ }
    if ($C -gt 0) { $Given++ }
    if ($N -gt 0) { $Given++ }
    if ($Given -eq 0) { return (& $Err "토폴로지 값이 없습니다 (-Sockets, -CoresPerSocket, -Cpu 중 최소 하나)") }
    if ($Given -eq 3 -and $N -ne ($S * $C)) { return (& $Err "-Cpu($N) 가 -Sockets($S) × -CoresPerSocket($C) = $($S*$C) 와 다릅니다") }
    if ($Given -eq 2) {
        if ($N -eq 0) { $N = $S * $C }
        elseif ($C -eq 0) { if ($N % $S -ne 0) { return (& $Err "-Cpu($N) 이 -Sockets($S) 로 나누어떨어지지 않습니다") }; $C = $N / $S }
        else { if ($N % $C -ne 0) { return (& $Err "-Cpu($N) 이 -CoresPerSocket($C) 로 나누어떨어지지 않습니다") }; $S = $N / $C }
    }
    if ($Given -eq 1) {
        if ($S -gt 0) { $N = $CurrentCpu; if ($N -le 0 -or $N % $S -ne 0) { return (& $Err "현재 vCPU($N) 이 -Sockets($S) 로 나누어떨어지지 않습니다. -CoresPerSocket 또는 -Cpu 를 함께 주십시오") }; $C = $N / $S }
        elseif ($C -gt 0) { $N = $CurrentCpu; if ($N -le 0 -or $N % $C -ne 0) { return (& $Err "현재 vCPU($N) 이 -CoresPerSocket($C) 로 나누어떨어지지 않습니다. -Sockets 또는 -Cpu 를 함께 주십시오") }; $S = $N / $C }
        else { $C = $(if ($CurrentCoresPerSocket -gt 0) { $CurrentCoresPerSocket } else { $N }); if ($N % $C -ne 0) { return (& $Err "-Cpu($N) 이 현재 소켓당 코어($C) 로 나누어떨어지지 않습니다. -CoresPerSocket 을 함께 주십시오") }; $S = $N / $C }
    }
    $S = [int]$S; $C = [int]$C; $N = [int]$N
    if ($S -lt 1 -or $C -lt 1 -or $N -lt 1) { return (& $Err "산출된 토폴로지가 유효하지 않습니다 (소켓 $S, 소켓당 코어 $C, vCPU $N)") }
    if ($HostThreads -gt 0 -and $N -gt $HostThreads) { return (& $Err "vCPU $N 이 호스트 논리 프로세서 수($HostThreads)를 넘습니다") }
    $Warn = @()
    if ($HostSockets -gt 0 -and $S -gt $HostSockets) { $Warn += "가상 소켓 $S 개가 호스트 물리 소켓 $HostSockets 개보다 많습니다" }
    if ($HostCoresPerSocket -gt 0 -and $C -gt $HostCoresPerSocket) { $Warn += "소켓당 코어 $C 가 호스트 소켓당 물리 코어 $HostCoresPerSocket 보다 많습니다" }
    return @{ Ok = $true; Sockets = $S; CoresPerSocket = $C; Cpu = $N; Warn = $Warn }
}


function Get-VmProfileState {
    # VM 하나의 현재 설정을 읽는다 (계획표, 검증표 공용).
    [CmdletBinding()]
    param ([Parameter(Mandatory=$true)] $VM, [Parameter(Mandatory=$false)] [string[]]$ExtraKeys = @())
    $V = Get-VM -Id $VM.Id -ErrorAction Stop
    $Cfg = $V.ExtensionData.Config
    $Cps = 0; try { $Cps = [int]$Cfg.Hardware.NumCoresPerSocket } catch { }
    # 고급 설정은 두 경로를 합쳐 읽는다: Get-AdvancedSetting + VM 구성의 ExtraConfig(vmx 내용).
    # sched.mem.pin 처럼 vCenter UI 고급 설정 화면에 안 보이는 키는 ExtraConfig 에만 있을 수 있다.
    $Adv = @{}
    foreach ($O in @($Cfg.ExtraConfig)) { if ($O -and $O.Key) { $Adv[$O.Key] = "$($O.Value)" } }
    foreach ($S in @(Get-AdvancedSetting -Entity $V -ErrorAction SilentlyContinue)) { if ($S) { $Adv[$S.Name] = "$($S.Value)" } }
    $St = [ordered]@{
        Cpu            = [int]$V.NumCpu
        CoresPerSocket = $Cps
        Sockets        = $(if ($Cps -gt 0) { [int]([math]::Ceiling($V.NumCpu / $Cps)) } else { 0 })
        MemoryGB       = [int][math]::Round($V.MemoryGB, 0)
        CpuShares      = [int]$Cfg.CpuAllocation.Shares.Shares
        CpuSharesLevel = "$($Cfg.CpuAllocation.Shares.Level)"
        MemShares      = [int]$Cfg.MemoryAllocation.Shares.Shares
        MemSharesLevel = "$($Cfg.MemoryAllocation.Shares.Level)"
        MemFullReservation    = "$($Cfg.MemoryReservationLockedToMax)"
        PowerState     = "$($V.PowerState)"
        Role           = (Get-VmRole -VM $V)
    }
    foreach ($K in $ExtraKeys) { $St[$K] = $(if ($Adv.ContainsKey($K) -and "$($Adv[$K])" -ne "") { $Adv[$K] } else { "(없음)" }) }
    return $St
}


function Test-VmProfileItemSame {
    # 항목 하나가 기적용인지 판정한다. shares 는 값과 SharesLevel(custom/normal)을 함께 본다.
    param ([string]$Key, $State, [string]$Target)
    switch ($Key) {
        { $_ -in @("CpuShares","MemShares") } {
            $Lv  = if ($Key -eq "CpuShares") { "$($State.CpuSharesLevel)" } else { "$($State.MemSharesLevel)" }
            $Val = "$($State[$Key])"
            if ($Target -eq "normal") { return ($Lv -eq "normal") }
            return ($Lv -eq "custom" -and $Val -eq $Target)
        }
        default {
            $Cur = if ($State.Contains($Key)) { "$($State[$Key])" } else { "" }
            if ($Target -eq "(제거)") { return ($Cur -eq "(없음)" -or $Cur -eq "") }
            return ($Cur.Trim().ToUpper() -eq $Target.Trim().ToUpper())
        }
    }
}

function Set-VmProfileUnreadableKeys {
    # 조회 불가 키(sched.mem.pin)의 현재값을 같은 묶음(1GB lpage 키)의 다른 키 상태로 채운다.
    #   다른 키가 전부 목표 상태 -> 목표값으로 채워 기적용 취급
    #   하나라도 다르면          -> "(조회 불가)" 로 채워 함께 기록
    param ($State, $Target, [string]$RemoveMark)
    foreach ($K in $Global:VmProfile_VmxOnlyKeys) {
        if (-not $Target.Contains($K)) { continue }
        if ($State.Contains($K) -and "$($State[$K])" -notin @("", "(없음)", "(조회 불가)")) { continue }   # 혹시 조회되면 그 값을 쓴다
        $Sib = @($Global:VmProfile_CommonExtraConfig.Keys | Where-Object { $_ -ne $K -and $Target.Contains($_) })
        $AllSame = ($Sib.Count -gt 0) -and (@($Sib | Where-Object { -not (Test-VmProfileItemSame -Key $_ -State $State -Target "$($Target[$_])") }).Count -eq 0)
        if ($AllSame) { $State[$K] = $(if ("$($Target[$K])" -eq $RemoveMark) { "(없음)" } else { "$($Target[$K])" }) }
        else          { $State[$K] = "(조회 불가)" }
    }
}

# 켜진 VM 에서도 바꿀 수 있는 항목 (vSphere 가 실행 중 변경 허용)
$Global:VmProfile_LiveOkItems = @("CpuShares","MemShares","MemFullReservation")


function Format-VmNameList {
    # VM 이름 목록을 짧게: 6대 이하면 전부, 넘으면 앞 3대 + '외 n대'
    param ([string[]]$Names)
    $N = @($Names | Sort-Object -Unique)
    if ($N.Count -le 6) { return ($N -join ", ") }
    return (($N | Select-Object -First 3) -join ", ") + " 외 $($N.Count - 3)대"
}


function Write-VmGroupedLines {
    # 호스트 이름을 윗줄로, 그 아래에 Host 열을 뺀 표 (VM, 항목, …, 사유)
    param ([object[]]$Rows, [string[]]$Columns, [string]$Color = "White")
    foreach ($Hg in @($Rows | Group-Object Host | Sort-Object Name)) {
        Write-Host "  [$($Hg.Name)]" -ForegroundColor $Color
        $Hg.Group | Sort-Object VM | Format-Table -Property $Columns -AutoSize -Wrap | Out-String -Width 320 | ForEach-Object { $_.TrimEnd() } | Write-Host -ForegroundColor $Color
    }
}


function Format-ItemShort {
    # 목록 나열용 짧은 항목명: '1GB lpage: sched.mem.pin' -> 'lpage pin', 긴 라벨은 괄호 앞부분만
    param ([string]$Item)
    if ($Item -like "1GB lpage: *") { return "lpage " + ($Item -replace '^1GB lpage: (sched\.(mem|swap)\.)?','' -replace '^lpage\.','') }
    if ($Item -like "1GB lpage 키 5개*") { return "lpage 5키" }
    if ($Item -like "*(numa.vcpu.maxPerVirtualNode)") { return "maxPerVirtualNode" }
    return $Item
}


function Set-VmProfile {
    # 2단계: 지정한 값(과 -Default 프로파일)을 대상 VM 에 적용한다.
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
    param (
        [Parameter(Mandatory=$false)] [string[]]$VMHostName = @(),
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),

        [Parameter(Mandatory=$false, HelpMessage="VM_TYPE 태그의 역할별 기본 프로파일(lpage 5키, shares, 전량 예약) 적용")] [switch]$Default,
        [Parameter(Mandatory=$false, HelpMessage="태그 대신 역할 강제 (PVM|SVM)")] [ValidateSet("","PVM","SVM")] [string]$Role = "",

        [Parameter(Mandatory=$false)] [int]$Sockets = 0,
        [Parameter(Mandatory=$false)] [int]$CoresPerSocket = 0,
        [Parameter(Mandatory=$false)] [int]$Cpu = 0,
        [Parameter(Mandatory=$false)] [int]$MemoryGB = 0,

        [Parameter(Mandatory=$false, HelpMessage="PVM:SVM shares 비율, 예 10000:1 (CPU, 메모리 동일 적용)")] [string]$ShareRatio = "",
        [Parameter(Mandatory=$false, HelpMessage="역할 무관 CPU shares 직접 지정")] [int]$CpuShares = -1,
        [Parameter(Mandatory=$false, HelpMessage="역할 무관 메모리 shares 직접 지정")] [int]$MemShares = -1,
        [Parameter(Mandatory=$false, HelpMessage="SharesLevel: normal = vSphere 자동값, custom = 값 직접 지정 (값 옵션을 주면 자동으로 custom)")] [ValidateSet("","normal","custom")] [string]$SharesLevel = "",
        [Parameter(Mandatory=$false)] [ValidateSet("","true","false")] [string]$MemFullReservation = "",
        [Parameter(Mandatory=$false, HelpMessage="추가/덮어쓸 고급 설정 키=값")] [hashtable]$ExtraConfig = @{},
        [Parameter(Mandatory=$false, HelpMessage="1GB page 관련 5키: on = 적용, off = 고급 설정에서 제거")] [ValidateSet("","on","off")] [string]$Lpage1GB = "",
        [Parameter(Mandatory=$false, HelpMessage="삭제할 고급 설정 키 목록")] [string[]]$RemoveExtraConfig = @(),
        [Parameter(Mandatory=$false, HelpMessage="이 스크립트가 쓰는 고급 설정 키 전부 삭제 (lpage 5키 + numa.vcpu.maxPerVirtualNode)")] [switch]$ResetAdvanced,

        [Parameter(Mandatory=$false, HelpMessage="DEPT_NAME 값. -Default 면 생략 시 설정 블록 기본값")] [string]$Dept = "",
        [Parameter(Mandatory=$false, HelpMessage="PURPOSE 값. -Default 면 생략 시 설정 블록 기본값")] [string]$Purpose = "",
        [Parameter(Mandatory=$false, HelpMessage="속성(DEPT_NAME, PURPOSE)만 적용 - 켜진 VM 허용")] [switch]$AttributesOnly,
        [Parameter(Mandatory=$false, HelpMessage="이 패턴에 맞는 대상 VM 에 먼저 VM_TYPE=PVM 태그")] [string[]]$TagPvm = @(),
        [Parameter(Mandatory=$false, HelpMessage="이 패턴에 맞는 대상 VM 에 먼저 VM_TYPE=SVM 태그")] [string[]]$TagSvm = @(),
        [Parameter(Mandatory=$false, HelpMessage="속성 정의가 vCenter 에 없으면 만든다")] [switch]$CreateAttributes,
        [Parameter(Mandatory=$false, HelpMessage="기적용 항목까지 계획표에 표시")] [switch]$ShowUnchanged,
        [Parameter(Mandatory=$false, HelpMessage="결과 행 객체 반환 (기본은 화면 출력만)")] [switch]$PassThru,
        [Parameter(Mandatory=$false, HelpMessage="계획, 결과를 VM×항목 전체 행 표로도 출력 (기본은 항목별 값과 미적용 VM 사유만)")] [switch]$Detail
    )

    # ---- 1. 대상 ----
    $Vms = Get-VmProfileTargets -VMHostName $VMHostName -VMName $VMName
    if ($Vms.Count -eq 0) { Write-Error "대상 VM 없음"; return }

    # ---- 1-1. 속성 기본값, 정의 확인, 선행 태그 ----
    if ($Default) {
        if (-not $Dept)    { $Dept    = $Global:VmProfile_AttrDefaults.Dept }
        if (-not $Purpose) { $Purpose = $Global:VmProfile_AttrDefaults.Purpose }
    }
    $NeedAttr = @()
    if ($TagPvm.Count -gt 0 -or $TagSvm.Count -gt 0) { $NeedAttr += $Global:VmProfile_Attr.Type }
    if ($Dept)    { $NeedAttr += $Global:VmProfile_Attr.Dept }
    if ($Purpose) { $NeedAttr += $Global:VmProfile_Attr.Purpose }
    foreach ($Name in ($NeedAttr | Sort-Object -Unique)) {
        if (-not (Get-CustomAttribute -Name $Name -TargetType VirtualMachine -ErrorAction SilentlyContinue)) {
            if ($CreateAttributes) { New-CustomAttribute -TargetType VirtualMachine -Name $Name -ErrorAction Stop | Out-Null; Write-Host "▶ 커스텀 속성 정의 생성: $Name" -ForegroundColor DarkGray }
            else { Write-Error "커스텀 속성 정의 '$Name' 이 vCenter 에 없습니다. -CreateAttributes 를 주거나 vCenter 에서 먼저 정의하십시오."; return }
        }
    }
    if ($TagPvm.Count -gt 0 -or $TagSvm.Count -gt 0) {
        $TagRows = @()
        foreach ($V in $Vms) {
            $IsP = @($TagPvm | Where-Object { $V.Name -like $_ }).Count -gt 0
            $IsS = @($TagSvm | Where-Object { $V.Name -like $_ }).Count -gt 0
            if ($IsP -and $IsS) { Write-Error "$($V.Name): -TagPvm 과 -TagSvm 패턴에 둘 다 맞습니다. 패턴을 조정하십시오."; return }
            if (-not ($IsP -or $IsS)) { continue }
            $T = if ($IsP) { "PVM" } else { "SVM" }
            if ($WhatIfPreference) { $TagRows += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; VM_TYPE = "$T (WhatIf)" }; continue }
            try { Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Type -Value $T -ErrorAction Stop | Out-Null; $TagRows += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; VM_TYPE = $T } }
            catch { Write-Error "$($V.Name): VM_TYPE 태그 실패: $($_.Exception.Message)"; return }
        }
        Write-Host "`n[선행 태그 VM_TYPE - $($TagRows.Count)대]" -ForegroundColor Green
        $TagRows | Format-Table -AutoSize | Out-String | Write-Host
    }

    # ---- 2. 지정 항목 정리 (지정한 것만 적용) ----
    $ExpPvm = $null; $ExpSvm = $null
    if ($ShareRatio) {
        $P = $ShareRatio -split ":"
        if ($P.Count -ne 2 -or $P[0] -notmatch '^\d+$' -or $P[1] -notmatch '^\d+$') { Write-Error "-ShareRatio 형식: <PVM>:<SVM>, 예 10000:1"; return }
        $ExpPvm = [int]$P[0]; $ExpSvm = [int]$P[1]
    }
    if ($Sockets -gt 0 -and $CoresPerSocket -gt 0 -and $Cpu -gt 0 -and $Cpu -ne ($Sockets * $CoresPerSocket)) {
        Write-Error "-Cpu($Cpu) 가 -Sockets($Sockets) × -CoresPerSocket($CoresPerSocket) = $($Sockets*$CoresPerSocket) 와 다릅니다."; return
    }
    $TopoGiven = ($Sockets -gt 0 -or $CoresPerSocket -gt 0 -or $Cpu -gt 0)
    $Anything = $Default -or $TopoGiven -or $MemoryGB -gt 0 -or $ShareRatio -or $CpuShares -ge 0 -or $MemShares -ge 0 -or $SharesLevel -or $MemFullReservation -or $ExtraConfig.Count -gt 0 -or $Lpage1GB -or $RemoveExtraConfig.Count -gt 0 -or $ResetAdvanced -or $Dept -or $Purpose -or $TagPvm.Count -gt 0 -or $TagSvm.Count -gt 0
    if ($SharesLevel -eq "custom" -and -not ($Default -or $ShareRatio -or $CpuShares -ge 0 -or $MemShares -ge 0)) { Write-Error "-SharesLevel custom 은 값이 필요합니다: -ShareRatio, -CpuShares/-MemShares 또는 -Default"; return }
    $REMOVE = "(제거)"   # 목표값이 이 표식이면 그 키를 고급 설정에서 지운다
    if (-not $Anything) { Write-Error "적용할 항목이 없습니다. -Default 또는 값을 지정하십시오."; return }

    $ExtraKeys = @($Global:VmProfile_CommonExtraConfig.Keys) + @($Global:VmProfile_TopologyExtraKey) + @($ExtraConfig.Keys) + @($RemoveExtraConfig) | Sort-Object -Unique

    # ---- 3. VM 별 계획 ----
    $Plans = @(); $NeedOff = @(); $NoRole = @()
    foreach ($V in $Vms) {
        $Cur = Get-VmProfileState -VM $V -ExtraKeys $ExtraKeys
        $R = if ($Role) { $Role } else { $Cur.Role }
        $Tgt = [ordered]@{}   # 항목 -> 목표값 (지정된 것만)

        if ($Default) {
            if (-not $R) { $NoRole += $V.Name }
            else {
                $D = $Global:VmProfile_Defaults[$R]
                $Tgt.MemFullReservation = "$($D.MemFullReservation)"
                foreach ($K in $Global:VmProfile_CommonExtraConfig.Keys) { $Tgt[$K] = $Global:VmProfile_CommonExtraConfig[$K] }
            }
        }
        if ($ShareRatio) {
            if (-not $R) { if ($V.Name -notin $NoRole) { $NoRole += $V.Name } }
            else { $Tgt.CpuShares = $(if ($R -eq "PVM") { $ExpPvm } else { $ExpSvm }); $Tgt.MemShares = $Tgt.CpuShares }
        }
        if ($CpuShares -ge 0) { $Tgt.CpuShares = $CpuShares }
        if ($MemShares -ge 0) { $Tgt.MemShares = $MemShares }
        if ($SharesLevel -eq "normal") { $Tgt.CpuShares = "normal"; $Tgt.MemShares = "normal" }
        if ($MemFullReservation) { $Tgt.MemFullReservation = $(if ($MemFullReservation -eq "true") { "True" } else { "False" }) }

        # 토폴로지: 검증 함수가 빠진 값을 산출하고 오류, 경고를 돌려준다
        if ($TopoGiven) {
            $Hw = $V.VMHost.ExtensionData.Hardware.CpuInfo
            $HSock = [int]$Hw.NumCpuPackages; $HThr = [int]$Hw.NumCpuThreads
            $HCps = $(if ($HSock -gt 0) { [int]([int]$Hw.NumCpuCores / $HSock) } else { 0 })
            $Tp = Test-VmTopologyInput -Sockets $Sockets -CoresPerSocket $CoresPerSocket -Cpu $Cpu `
                      -CurrentCpu $Cur.Cpu -CurrentCoresPerSocket $Cur.CoresPerSocket `
                      -HostSockets $HSock -HostCoresPerSocket $HCps -HostThreads $HThr
            if (-not $Tp.Ok) { Write-Error "[$($V.Name)] 토폴로지 오류: $($Tp.Error)"; return }
            foreach ($W in $Tp.Warn) { Write-Warning "[$($V.Name)] $W" }
            $Tgt.Cpu = $Tp.Cpu; $Tgt.CoresPerSocket = $Tp.CoresPerSocket; $Tgt.Sockets = $Tp.Sockets
            $Tgt[$Global:VmProfile_TopologyExtraKey] = "$($Tp.CoresPerSocket)"
        }
        if ($MemoryGB -gt 0) { $Tgt.MemoryGB = $MemoryGB }
        if ($Lpage1GB -eq "on")  { foreach ($K in $Global:VmProfile_CommonExtraConfig.Keys) { $Tgt[$K] = $Global:VmProfile_CommonExtraConfig[$K] } }
        if ($Lpage1GB -eq "off") { foreach ($K in $Global:VmProfile_CommonExtraConfig.Keys) { $Tgt[$K] = $REMOVE } }
        foreach ($K in $ExtraConfig.Keys) { $Tgt[$K] = "$($ExtraConfig[$K])" }
        if ($ResetAdvanced) { foreach ($K in (@($Global:VmProfile_CommonExtraConfig.Keys) + @($Global:VmProfile_TopologyExtraKey))) { $Tgt[$K] = $REMOVE } }
        foreach ($K in $RemoveExtraConfig) { if ($K) { $Tgt[$K] = $REMOVE } }

        Set-VmProfileUnreadableKeys -State $Cur -Target $Tgt -RemoveMark $REMOVE
        $Items = @()
        $LpKeys = @($Global:VmProfile_CommonExtraConfig.Keys)
        $LpInTgt = @($LpKeys | Where-Object { $Tgt.Contains($_) })
        $Lbl = { param($k) if ($Global:VmProfile_ItemLabel.ContainsKey($k)) { $Global:VmProfile_ItemLabel[$k] } else { $k } }
        foreach ($K in $Tgt.Keys) {
            if ($K -in $LpKeys) { continue }
            $Same = Test-VmProfileItemSame -Key $K -State $Cur -Target "$($Tgt[$K])"
            $CurVal = if ($Cur.Contains($K)) { "$($Cur[$K])" } else { "" }
            if ($CurVal -eq "" -or $CurVal -eq "(없음)") { $CurVal = "없음" }
            if ($K -in @("CoresPerSocket","Sockets") -and $CurVal -eq "0") { $CurVal = "자동(0)" }   # vCenter 는 자동 배정을 0 으로 돌려준다
            if ($K -eq "CpuShares") { $CurVal = "$($Cur.CpuShares) ($($Cur.CpuSharesLevel))" }
            if ($K -eq "MemShares") { $CurVal = "$($Cur.MemShares) ($($Cur.MemSharesLevel))" }
            $TgtVal = "$($Tgt[$K])"
            if ($K -in @("CpuShares","MemShares") -and $TgtVal -ne "normal") { $TgtVal = "$TgtVal (custom)" }
            $Act = if ($Same) { "-" } elseif ($TgtVal -eq $REMOVE) { "삭제" } elseif ($CurVal -eq "없음") { "적용" } else { "변경" }
            if ($TgtVal -eq $REMOVE) { $TgtVal = "삭제" }
            $Items += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; 항목 = (& $Lbl $K); 현재 = $CurVal; 목표 = $TgtVal; 작업 = $Act }
        }
        if ($LpInTgt.Count -gt 0) {
            # 1GB lpage 키: 5키 상태가 전부 같으면 한 줄, 하나라도 다르면 키별로 펼친다
            $IsRemove = ($Lpage1GB -eq "off" -or $ResetAdvanced)
            $PerKey = @()
            foreach ($K in $LpInTgt) {
                $Same = Test-VmProfileItemSame -Key $K -State $Cur -Target "$($Tgt[$K])"
                $CurVal = if ($Cur.Contains($K) -and "$($Cur[$K])" -ne "(없음)") { "$($Cur[$K])" } else { "없음" }
                if ($K -in $Global:VmProfile_VmxOnlyKeys) { $CurVal = $(if ("$($Cur[$K])" -eq "(조회 불가)") { "조회 불가" } else { "$($Cur[$K]) (다른 키 기준 간주)" }) }
                $TgtVal = if ($IsRemove) { "삭제" } else { "$($Tgt[$K])" }
                $Act = if ($Same) { "-" } elseif ($IsRemove) { "삭제" } elseif ($CurVal -eq "없음") { "적용" } else { "변경" }
                $PerKey += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; 항목 = "1GB lpage: $K"; 현재 = $CurVal; 목표 = $TgtVal; 작업 = $Act }
            }
            $Acts = @($PerKey | ForEach-Object { $_.작업 } | Sort-Object -Unique)
            $Curs = @($PerKey | ForEach-Object { $(if ($_.현재 -eq "없음") { "없음" } else { "있음" }) } | Sort-Object -Unique)
            if ($Acts.Count -eq 1 -and $Curs.Count -eq 1) {
                $n = $LpInTgt.Count
                $CurJ = if ($Curs[0] -eq "없음") { "없음" } elseif ($Acts[0] -eq "-" -and -not $IsRemove) { "적용됨($n/$n)" } else { "있음($n/$n)" }
                $Items += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; 항목 = "1GB lpage 키 $n개 (전부 동일 상태)"; 현재 = $CurJ; 목표 = $(if ($IsRemove) { "삭제" } else { "적용" }); 작업 = $Acts[0] }
            } else {
                $Items += $PerKey
            }
        }
        $Changed = @($Tgt.Keys | Where-Object { -not (Test-VmProfileItemSame -Key $_ -State $Cur -Target "$($Tgt[$_])") })
        $Plans += [PSCustomObject]@{ VM = $V; Role = $R; State = $Cur; Target = $Tgt; Items = $Items; Changed = $Changed }
        $OffNeeded = @($Changed | Where-Object { $_ -notin $Global:VmProfile_LiveOkItems })
        if ($Cur.PowerState -eq "PoweredOn" -and -not $AttributesOnly -and $OffNeeded.Count -gt 0) { $NeedOff += "$($V.Name)($($OffNeeded -join ','))" }
    }

    if ($NoRole.Count -gt 0) {
        Write-Error "VM_TYPE 태그가 없거나 PVM/SVM 으로 판정되지 않는 VM: $($NoRole -join ', '). 먼저 Set-VmType 으로 태그를 붙이거나 -Role 로 강제하십시오."; return
    }

    # 계획 행 전체와 변경 행 (적용 전 표시, -Detail 표, -WhatIf 반환에 쓴다)
    $All = @($Plans | ForEach-Object { $_.Items })
    $ChangeRows = @($All | Where-Object { $_.작업 -ne "-" })

    # ---- 4. 계획표: 요약(공통) → 집계 → 변경 있는 행만 상세 ----
    $Lp5 = @($Global:VmProfile_CommonExtraConfig.Keys)
    $Summary = @()
    if ($Default)                    { $Summary += "기본 프로파일(-Default): 1GB lpage 키 5개 적용 + 메모리 전량 예약 True + 속성 기본값" }
    if ($Lpage1GB -eq "on")          { $Summary += "1GB lpage 키 5개 적용: $($Lp5 -join ', ')" }
    if ($Lpage1GB -eq "off")         { $Summary += "1GB lpage 키 5개 삭제: $($Lp5 -join ', ')" }
    if ($ResetAdvanced)              { $Summary += "고급 설정 초기화: lpage 키 5개 + $($Global:VmProfile_TopologyExtraKey) 삭제" }
    if ($RemoveExtraConfig.Count -gt 0) { $Summary += "고급 설정 키 삭제: $($RemoveExtraConfig -join ', ')" }
    if ($ExtraConfig.Count -gt 0)    { $Summary += "고급 설정 기록: " + (($ExtraConfig.Keys | ForEach-Object { "$_=$($ExtraConfig[$_])" }) -join ', ') }
    if ($ShareRatio)                 { $Summary += "CPU, 메모리 shares (custom): PVM $ExpPvm / SVM $ExpSvm" }
    if ($CpuShares -ge 0)            { $Summary += "CPU shares (custom): $CpuShares (역할 무관)" }
    if ($MemShares -ge 0)            { $Summary += "메모리 shares (custom): $MemShares (역할 무관)" }
    if ($SharesLevel -eq "normal")   { $Summary += "CPU, 메모리 SharesLevel: normal (vSphere 자동값으로 되돌림)" }
    if ($MemFullReservation)         { $Summary += "메모리 전량 예약: $MemFullReservation" }
    if ($TopoGiven) {
        # -join 은 + 보다 우선순위가 낮아 괄호 없이는 뒤 문구가 사라진다
        $TopoParts = @()
        if ($Sockets -gt 0)        { $TopoParts += "소켓 수 $Sockets" }
        if ($CoresPerSocket -gt 0) { $TopoParts += "소켓당 코어 $CoresPerSocket" }
        if ($Cpu -gt 0)            { $TopoParts += "vCPU 수 $Cpu" }
        $Summary += "vCPU 토폴로지: " + ($TopoParts -join ', ') + " (나머지는 산출) + $($Global:VmProfile_TopologyExtraKey)=소켓당 코어"
    }
    if ($MemoryGB -gt 0)             { $Summary += "메모리 크기: $MemoryGB GB" }
    if ($Dept -or $Purpose)          { $Summary += "속성: " + (@($(if ($Dept) { "DEPT_NAME=$Dept$(if (-not $PSBoundParameters.ContainsKey('Dept')) { '(기본값)' })" }), $(if ($Purpose) { "PURPOSE=$Purpose$(if (-not $PSBoundParameters.ContainsKey('Purpose')) { '(기본값)' })" })) | Where-Object { $_ }) -join ', ' }
    if ($TagPvm.Count -gt 0) { $Summary += "선행 태그 VM_TYPE=PVM: $($TagPvm -join ', ')" }
    if ($TagSvm.Count -gt 0) { $Summary += "선행 태그 VM_TYPE=SVM: $($TagSvm -join ', ')" }

    $ChangedVms = @($Plans | Where-Object { $_.Changed.Count -gt 0 })
    Write-Host "`n══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "[이번 실행이 적용하는 설정]" -ForegroundColor Green
    foreach ($Line in $Summary) { Write-Host "  - $Line" }
    Write-Host "[대상] VM $($Vms.Count)대$(if ($Role) { " (역할 강제 $Role)" })" -ForegroundColor Green
    foreach ($Hg in @($Vms | Group-Object { $_.VMHost.Name } | Sort-Object Name)) { Write-Host "  $($Hg.Name): $(Format-VmNameList @($Hg.Group | ForEach-Object { $_.Name }))" -ForegroundColor DarkGray }
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
    # 예외만: 위 공통 설정이 그대로 적용되지 않는 VM×항목 (기적용, 키 미존재)
    $Exc = @($All | Where-Object { $_.작업 -eq "-" } | ForEach-Object {
        [PSCustomObject]@{ Host = $_.Host; VM = $_.VM; 항목 = $_.항목; 현재값 = $_.현재; 사유 = $(if ($_.목표 -eq "삭제") { "키 미존재 (삭제 대상 없음)" } else { "기적용 (현재값 = 목표값)" }) }
    })
    if ($Exc.Count -eq 0) {
        Write-Host "[변경 불필요 VM] 없음 - 전 VM 에 위 설정 적용" -ForegroundColor Green
    } else {
        Write-Host "[변경 불필요 VM - 기적용, 키 미존재 ($($Exc.Count)건). 나머지 VM 은 위 설정 적용]" -ForegroundColor Yellow
        Write-VmGroupedLines -Rows $Exc -Color DarkGray -Columns @("VM","항목","현재값","사유")
    }
    if ($ChangeRows.Count -eq 0) { Write-Host "[변경] 바뀌는 항목 없음 - 전 VM 기적용" -ForegroundColor DarkGray }
    if ($Detail) {
        $Rows = if ($ShowUnchanged) { $All } else { $ChangeRows }
        if ($Rows.Count -gt 0) {
            Write-Host "[상세 - VM×항목. 작업 = 적용(없던 것 기록) / 변경(값 교체) / 삭제 / -(기적용)]" -ForegroundColor Green
            $Rows | Format-Table -Property Host, VM, 항목, 현재, 목표, 작업 -AutoSize -Wrap | Out-String -Width 320 | Write-Host
        }
    } else {
        Write-Host "  (VM 별 전체 행은 -Detail 로 표시)" -ForegroundColor DarkGray
    }

    # ---- 5. 전원 검사 ----
    if ($NeedOff.Count -gt 0) {
        Write-Host "[중단] 전원이 켜진 VM 에 끈 상태가 필요한 변경이 있습니다: $($NeedOff -join ', ')" -ForegroundColor Red
        Write-Host "       vCPU/소켓/메모리 크기/고급 설정 키는 전원을 끈 상태에서 적용합니다 (shares, 메모리 전량 예약, 속성은 켜진 채 가능). VM 을 끈 뒤 같은 명령을 다시 실행하십시오." -ForegroundColor Red
        return
    }
    if ($WhatIfPreference) { Write-Host "-WhatIf: 적용하지 않습니다." -ForegroundColor Yellow; return $All }
    if (-not $PSCmdlet.ShouldProcess("VM $($Vms.Count)대", "설정 적용")) { return }
    $Ans = Read-Host "위 계획대로 적용합니까? (y/n)"
    if ($Ans -notmatch '^y') { Write-Host "취소" -ForegroundColor Yellow; return }

    # ---- 6. 적용 ----
    $Results = @(); $VmLines = @(); $VmStatus = @{}
    foreach ($Pl in $Plans) {
        $V = $Pl.VM; $T = $Pl.Target; $Ch = @($Pl.Changed)
        if (-not $AttributesOnly -and $Ch.Count -gt 0) {
            $Spec = New-Object VMware.Vim.VirtualMachineConfigSpec
            if ("Cpu" -in $Ch)            { $Spec.NumCPUs = [int]$T.Cpu }
            if ("CoresPerSocket" -in $Ch) { $Spec.NumCoresPerSocket = [int]$T.CoresPerSocket }
            if ("MemoryGB" -in $Ch)       { $Spec.MemoryMB = [long]$T.MemoryGB * 1024 }
            if ("CpuShares" -in $Ch) {
                $Spec.CpuAllocation = New-Object VMware.Vim.ResourceAllocationInfo
                $Spec.CpuAllocation.Shares = $(if ("$($T.CpuShares)" -eq "normal") { New-Object VMware.Vim.SharesInfo -Property @{ Level = "normal" } } else { New-Object VMware.Vim.SharesInfo -Property @{ Level = "custom"; Shares = [int]$T.CpuShares } })
            }
            if ("MemShares" -in $Ch) {
                $Spec.MemoryAllocation = New-Object VMware.Vim.ResourceAllocationInfo
                $Spec.MemoryAllocation.Shares = $(if ("$($T.MemShares)" -eq "normal") { New-Object VMware.Vim.SharesInfo -Property @{ Level = "normal" } } else { New-Object VMware.Vim.SharesInfo -Property @{ Level = "custom"; Shares = [int]$T.MemShares } })
            }
            if ("MemFullReservation" -in $Ch) { $Spec.MemoryReservationLockedToMax = ($T.MemFullReservation -eq "True") }
            # 고급 설정은 기록, 삭제를 한 spec 에 모아 VM 당 ReconfigVM 1회. 삭제는 빈값("") 기록 (sched.mem.pin 포함).
            $Ec = @(); $SetKeys = @(); $RemoveKeys = @()
            foreach ($K in $Ch) {
                if ($K -in @("Cpu","CoresPerSocket","Sockets","MemoryGB","CpuShares","MemShares","MemFullReservation")) { continue }
                if ("$($T[$K])" -eq $REMOVE) { $RemoveKeys += $K; $Ec += New-Object VMware.Vim.OptionValue -Property @{ Key = $K; Value = "" } }
                else { $SetKeys += $K; $Ec += New-Object VMware.Vim.OptionValue -Property @{ Key = $K; Value = "$($T[$K])" } }
            }
            if ($Ec.Count -gt 0) { $Spec.ExtraConfig = $Ec }
            $Ok = ""
            try {
                $V.ExtensionData.ReconfigVM($Spec)
                $Parts = @()
                $Other = @($Ch | Where-Object { $_ -in @("Cpu","CoresPerSocket","MemoryGB","CpuShares","MemShares","MemFullReservation") })
                if ($Other.Count -gt 0)      { $Parts += "설정 $($Other.Count)개" }
                if ($SetKeys.Count -gt 0)    { $Parts += "고급 설정 기록 $($SetKeys.Count)개" }
                if ($RemoveKeys.Count -gt 0) { $Parts += "고급 설정 삭제 $($RemoveKeys.Count)개" }
                $Ok = "적용 (재구성 1회: " + ($Parts -join ", ") + ")"
            }
            catch { $Ok = "FAIL: $($_.Exception.Message)" }
        } else { $Ok = $(if ($T.Count -gt 0) { "변경 없음(전부 기적용)" } else { "(설정 항목 없음)" }) }

        $AttrOk = ""
        try {
            if ($Dept)    { Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Dept    -Value $Dept    -ErrorAction Stop | Out-Null; $AttrOk += "DEPT_NAME " }
            if ($Purpose) { Set-Annotation -Entity $V -CustomAttribute $Global:VmProfile_Attr.Purpose -Value $Purpose -ErrorAction Stop | Out-Null; $AttrOk += "PURPOSE " }
        } catch { $AttrOk += "FAIL: $($_.Exception.Message)" }

        # ---- 7. 적용 후 검증 - 항목마다 이전값 → 이후값 → 판정 ----
        $After = Get-VmProfileState -VM $V -ExtraKeys $ExtraKeys
        Set-VmProfileUnreadableKeys -State $After -Target $T -RemoveMark $REMOVE
        foreach ($K in $Global:VmProfile_VmxOnlyKeys) { if ($T.Contains($K) -and "$($T[$K])" -eq $REMOVE) { $After[$K] = "(조회 불가)" } }   # 삭제는 API 로 안 됨
        $Lbl = { param($k) if ($Global:VmProfile_ItemLabel.ContainsKey($k)) { $Global:VmProfile_ItemLabel[$k] } elseif ($k -in $Global:VmProfile_CommonExtraConfig.Keys) { "1GB lpage: $k" } else { $k } }
        $Fmt = { param($st, $k)
            if (-not $st.Contains($k)) { return "없음" }
            $v = "$($st[$k])"
            if ($k -eq "CpuShares") { return "$v ($($st.CpuSharesLevel))" }
            if ($k -eq "MemShares") { return "$v ($($st.MemSharesLevel))" }
            if ($k -in @("CoresPerSocket","Sockets") -and $v -eq "0") { return "자동(0)" }
            if ($k -in $Global:VmProfile_VmxOnlyKeys) {
                if ($v -eq "(조회 불가)") { return "조회 불가" }
                if ($v -eq "(없음)" -or $v -eq "") { return "없음 (다른 키 기준 간주)" }
                return "$v (다른 키 기준 간주)"
            }
            if ($v -eq "(없음)" -or $v -eq "") { return "없음" }
            return $v }
        $OkCnt = 0; $DiffCnt = 0
        foreach ($K in $T.Keys) {
            $Same = Test-VmProfileItemSame -Key $K -State $After -Target "$($T[$K])"
            if ($Same) { $OkCnt++ } else { $DiffCnt++ }
            $Results += [PSCustomObject]@{
                Host = $V.VMHost.Name; VM = $V.Name; 항목 = (& $Lbl $K)
                이전 = (& $Fmt $Pl.State $K); 이후 = (& $Fmt $After $K)
                목표 = $(if ("$($T[$K])" -eq $REMOVE) { "삭제" } elseif ($K -in @("CpuShares","MemShares") -and "$($T[$K])" -ne "normal") { "$($T[$K]) (custom)" } else { "$($T[$K])" })
                작업 = $(if ($K -in $Ch) { "변경" } else { "기적용" }); 판정 = $(if ($Same) { "OK" } else { "DIFF" })
            }
        }
        foreach ($Pair in @(@("Dept",$Dept,$Global:VmProfile_Attr.Dept), @("Purpose",$Purpose,$Global:VmProfile_Attr.Purpose))) {
            if (-not $Pair[1]) { continue }
            $Now = "$((Get-Annotation -Entity $V -CustomAttribute $Pair[2] -ErrorAction SilentlyContinue).Value)"
            $Same = ($Now -eq $Pair[1])
            if ($Same) { $OkCnt++ } else { $DiffCnt++ }
            $Results += [PSCustomObject]@{ Host = $V.VMHost.Name; VM = $V.Name; 항목 = "속성 $($Pair[2])"; 이전 = "-"; 이후 = $Now; 목표 = $Pair[1]; 작업 = "기록"; 판정 = $(if ($Same) { "OK" } else { "DIFF" }) }
        }
        $VmLines += "[$($V.Name)] $Ok, 검증 OK $OkCnt / DIFF $DiffCnt$(if ($AttrOk -match 'FAIL') { ", 속성 $AttrOk" })"
        $VmStatus[$V.Name] = @{ Reconfig = $Ok; Attr = $AttrOk }
    }
    $DiffRows = @($Results | Where-Object 판정 -eq "DIFF")
    $DiffVms  = @($DiffRows | ForEach-Object { $_.VM } | Sort-Object -Unique)
    $FailVms  = @($VmLines | Where-Object { $_ -match 'FAIL' })
    Write-Host "`n══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "[결과 - VM $($Plans.Count)대: 정상 $($Plans.Count - $DiffVms.Count)대, 적용 실패 $($DiffVms.Count)대$(if ($DiffVms.Count) { " (" + ($DiffVms -join ', ') + ")" })]" -ForegroundColor $(if ($DiffVms.Count -eq 0 -and $FailVms.Count -eq 0) { "Green" } else { "Yellow" })
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
    if ($FailVms.Count -gt 0) {
        Write-Host "[재구성 호출 실패 VM]" -ForegroundColor Red
        foreach ($Nm in @($VmStatus.Keys | Sort-Object)) {
            $St = $VmStatus[$Nm]
            if ($St.Reconfig -match '^FAIL') { Write-Host "  - $Nm : vCenter 오류 - $($St.Reconfig -replace '^FAIL: ','')" -ForegroundColor Red }
            if ($St.Attr -match 'FAIL')     { Write-Host "  - $Nm : 속성 기록 실패 - $($St.Attr)" -ForegroundColor Red }
        }
    }
    Write-Host "[적용 완료 - 항목 = 적용 후 값 (전 VM 공통)]" -ForegroundColor Green
    $Order = @(); foreach ($R in $Results) { if ($R.항목 -notin $Order) { $Order += $R.항목 } }
    $ExcRows = @()
    foreach ($Name in $Order) {
        $g = @($Results | Where-Object 항목 -eq $Name)
        $Applied = @($g | Where-Object { $_.판정 -eq "OK" -and $_.작업 -in @("변경","기록") })
        $Rest    = @($g | Where-Object { -not ($_.판정 -eq "OK" -and $_.작업 -in @("변경","기록")) })
        $Vals = @($Applied | ForEach-Object { $_.이후 } | Sort-Object -Unique)
        $ValText = if ($Vals.Count -gt 0) { $Vals -join " / " } else { (@($g | ForEach-Object { $_.목표 } | Sort-Object -Unique) -join " / ") }
        $nFail = @($Rest | Where-Object 판정 -eq "DIFF").Count; $nSkip = $Rest.Count - $nFail
        Write-Host "  - $Name = $ValText : 적용 $($Applied.Count)대$(if ($nSkip) { ", 변경 불필요 $nSkip대" })$(if ($nFail) { ", 적용 실패 $nFail대" })" -ForegroundColor $(if ($nFail) { "Yellow" } else { "White" })
        foreach ($R in $Rest) {
            $Why = if ($R.판정 -eq "OK" -and $R.작업 -eq "기적용" -and $R.목표 -eq "삭제") { "키 미존재 (삭제 대상 없음)" }
                   elseif ($R.판정 -eq "OK" -and $R.작업 -eq "기적용") { "기적용 (현재값 = 목표값)" }
                   elseif ($VmStatus[$R.VM].Reconfig -match '^FAIL') { "재구성 호출 실패: $($VmStatus[$R.VM].Reconfig -replace '^FAIL: ','')" }
                   elseif ($R.작업 -eq "기록") { "속성 값 미기록 (속성 정의 없음 또는 쓰기 오류)" }
                   elseif ($R.이후 -eq "조회 불가" -and $R.목표 -eq "삭제") { "sched.mem.pin 은 vmx 에서 제거하세요" }
                   elseif ($R.이후 -eq "조회 불가") { "조회 불가 키 - 다른 1GB lpage 키에 실패가 있어 미확정. vmx 에서 확인" }
                   elseif ($R.이후 -eq "없음" -and $R.목표 -ne "삭제") { "재구성 성공 후 적용 후 조회에 키 없음 - Test-VmProfile 로 재확인" }
                   elseif ($R.목표 -eq "삭제" -and $R.이후 -ne "없음") { "삭제 미반영 (빈값 기록 후 값 유지) - Get-AdvancedSetting | Remove-AdvancedSetting 으로 재시도" }
                   elseif ($R.작업 -eq "기적용") { "기적용으로 판정했으나 적용 후 값이 다름 (다른 세션의 동시 변경 가능성)" }
                   else { "적용 후 값이 목표와 다름 (vCenter 가 값을 보정했거나 다른 설정과 충돌)" }
            $ExcRows += [PSCustomObject]@{ Host = $R.Host; VM = $R.VM; 항목 = $R.항목; 목표값 = $R.목표; "적용 후 값" = $R.이후; 구분 = $(if ($R.판정 -eq "OK") { "변경 불필요" } else { "적용 실패" }); 사유 = $Why }
        }
    }
    $FailRows = @($ExcRows | Where-Object 구분 -eq "적용 실패")
    $SkipRows = @($ExcRows | Where-Object 구분 -eq "변경 불필요")
    if ($FailRows.Count -gt 0) {
        Write-Host "[적용 실패 ($($FailRows.Count)건) - 적용 후 값이 목표값과 다름]" -ForegroundColor Red
        Write-VmGroupedLines -Rows $FailRows -Color Red -Columns @("VM","항목","목표값","적용 후 값","사유")
    } else {
        Write-Host "[적용 실패] 없음" -ForegroundColor Green
    }
    if ($SkipRows.Count -gt 0) {
        Write-Host "[변경 불필요 ($($SkipRows.Count)건) - 기적용, 키 미존재]" -ForegroundColor DarkGray
        Write-VmGroupedLines -Rows $SkipRows -Color DarkGray -Columns @("VM","항목","적용 후 값","사유")
    }
    if ($Detail) {
        Write-Host "[상세 - VM×항목 전체. 작업 = 변경(이번에 바꿈) / 기적용 / 기록(속성)]" -ForegroundColor Green
        foreach ($L in $VmLines) { Write-Host "  $L" -ForegroundColor $(if ($L -match 'DIFF 0') { "Green" } else { "Yellow" }) }
        $Results | Format-Table -Property Host, VM, 항목, 이전, 이후, 목표, 작업, 판정 -AutoSize -Wrap | Out-String -Width 320 | Write-Host
    } else {
        Write-Host "  (VM 별 전체 행은 -Detail 로 표시, 객체로 받으려면 -PassThru)" -ForegroundColor DarkGray
    }
    if ($PassThru) { return $Results }
}


function Test-VmProfile {
    # 적용 없이 현재 상태를 역할 기본 프로파일과 대조한다.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)] [string[]]$VMHostName = @(),
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false, HelpMessage="결과 행 객체 반환 (기본은 화면 출력만)")] [switch]$PassThru
    )
    $Vms = Get-VmProfileTargets -VMHostName $VMHostName -VMName $VMName
    if ($Vms.Count -eq 0) { Write-Error "대상 VM 없음"; return }
    $Keys = @($Global:VmProfile_CommonExtraConfig.Keys) + @($Global:VmProfile_TopologyExtraKey)
    $Rows = @()
    foreach ($V in $Vms) {
        $S = Get-VmProfileState -VM $V -ExtraKeys $Keys
        $R = $S.Role
        $D = if ($R) { $Global:VmProfile_Defaults[$R] } else { $null }
        $Diff = @()
        if ($D) {
            if ("$($S.MemFullReservation)".ToUpper() -ne "$($D.MemFullReservation)".ToUpper()) { $Diff += "MemFullReservation=$($S.MemFullReservation)" }
            foreach ($K in $Global:VmProfile_CommonExtraConfig.Keys) { if ("$($S[$K])".ToUpper() -ne "$($Global:VmProfile_CommonExtraConfig[$K])".ToUpper()) { $Diff += "$K=$($S[$K])" } }
            if ($S.CoresPerSocket -gt 0 -and "$($S[$Global:VmProfile_TopologyExtraKey])" -ne "$($S.CoresPerSocket)") { $Diff += "$($Global:VmProfile_TopologyExtraKey)=$($S[$Global:VmProfile_TopologyExtraKey])" }
        }
        $Rows += [PSCustomObject]@{
            Host = $V.VMHost.Name; VM = $V.Name; Role = $(if ($R) { $R } else { "(태그 없음)" }); Power = $S.PowerState
            Cpu = $S.Cpu; Sockets = $S.Sockets; CoresPerSocket = $S.CoresPerSocket; MemoryGB = $S.MemoryGB
            CpuShares = "$($S.CpuShares) ($($S.CpuSharesLevel))"; MemShares = "$($S.MemShares) ($($S.MemSharesLevel))"; MemFullReservation = $S.MemFullReservation
            Lpage1GB = $S["sched.mem.lpage.enable1GPage"]; Pin = $S["sched.mem.pin"]; Prealloc = $S["sched.mem.prealloc"]; PinnedMainMem = $S["sched.mem.prealloc.pinnedMainMem"]; VmxSwap = $S["sched.swap.vmxSwapEnabled"]
            MaxPerVirtualNode = $S[$Global:VmProfile_TopologyExtraKey]
            Result = $(if (-not $D) { "역할 미판정" } elseif ($Diff.Count -eq 0) { "OK (-Default 항목 기준, shares 는 표시만)" } else { "DIFF: " + ($Diff -join "; ") })
        }
    }
    $Rows | Format-Table -AutoSize -Wrap | Out-String -Width 320 | Write-Host
    if ($PassThru) { return $Rows }
}

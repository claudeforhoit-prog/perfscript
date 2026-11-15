# ==============================================================================
# StartVmsSequential  v1.4  (2026-09-28)   - 구판 이름 StartVmsWithBackingGate (v1.0~v1.3)
#
#   호스트별로 VM 을 하나씩 순서대로 켠다. 한 VM 의 "전원 켜기" 작업(PowerOnVM task)이 끝나면
#   호스트 메모리 점유량을 한 번 읽어 표시하고 그 호스트의 다음 VM 을 켠다.
#   호스트를 여러 개 주면 호스트끼리는 기다리지 않고 각자 동시에 진행한다 (호스트 3개면 각 호스트의
#   1번 VM 을 동시에 켜고, 먼저 끝난 호스트가 먼저 2번으로 넘어간다).
#
#   v1.3 -> v1.4
#     - 게이트를 "전원 켜기 작업 완료" 로 바꿈. sched.mem.prealloc 이 켜진 VM 은 전원 켜기 작업 안에서
#       구성 메모리 전량을 호스트 물리 메모리에 배정하므로, 작업 완료 = 배정 완료로 본다.
#       점유량 폴링으로 완료를 기다리던 방식(Backing 게이트)은 제거. 점유량은 켜진 직후 1회 읽어 표시만 한다.
#     - 여러 호스트 동시 진행 (한 루프가 호스트별 대기열을 같이 관리, 별도 스레드 없음)
#     - 폴링 5초. 확인 1회는 Get-View 속성 읽기만 (VM 재조회, 고급 설정 재조회 없음)
#     - SSH 기반 1GB page 게이트 제거 (작업 PC 에서 ESXi SSH 불가). 1GB page 백킹 여부는 이 스크립트가
#       판정하지 않는다.
#     - 함수 이름: Start-VmsSequential (구 Start-VmsWithBackingGate), Get-VmHostMemStatus (구 Get-VmBackingStatus)
#
#   [함수]
#     Start-VmsSequential   호스트별 순차 기동 (아래 옵션)
#     Get-VmHostMemStatus   VM 의 전원 상태, 구성 메모리, 호스트 메모리 점유량, 1GB lpage 키를 표로 (읽기만)
#
#   [옵션]
#     -VMHostName <이름,…>   대상 ESXi 호스트. 여러 개, 와일드카드 가능 (esx0*, esx01,esx02)
#     -VMName <이름,…>       켤 VM 이름을 순서대로. 여러 호스트일 때는 각 호스트에서 이 이름에 맞는 VM 을 그 순서로
#     -All                   호스트의 VM 전부를 이름순으로 (-VMName 생략 시 필요)
#     -NamePattern <패턴>    -All 에서 고를 이름 와일드카드 (기본 *)
#     -Exclude <패턴,…>      -All 에서 뺄 이름 와일드카드
#     -Gate PowerOn|Tools    다음 VM 으로 넘어가는 기준. PowerOn(기본) = 전원 켜기 작업 완료,
#                            Tools = 그 뒤 VMware Tools 실행(게스트 부팅 완료)까지
#     -PollSeconds <초>      확인 주기 (기본 5)
#     -TaskTimeoutMinutes    전원 켜기 작업 최대 대기 (기본 90). 넘으면 그 호스트는 멈춘다 (작업 자체는 취소하지 않음)
#     -ToolsTimeoutMinutes   Tools 게이트 최대 대기 (기본 20)
#     -ContinueOnIncomplete  실패, 시간초과가 나도 그 호스트의 다음 VM 을 계속 켠다
#     -Require1GPage         sched.mem.lpage.enable1GPage 가 TRUE 가 아닌 VM 이 있으면 켜지 않고 중단
#     -PassThru              결과 행 객체 반환 (기본은 화면 출력만)
#     -WhatIf                순서, 사전 확인만 보고 켜지 않음
#
#   [켜진 직후 메모리 표시]  vCenter 의 점유량(HostMemoryUsage, 오버헤드 포함)은 약 20초마다 갱신되므로
#     켜진 직후 값이 낮게 나올 수 있다. 99% 미만이면 25초 뒤 한 번 다시 읽어 결과 표를 갱신한다 (다음 VM 기동은 막지 않음).
#
#   [하지 않는 것]  VM 설정 변경 없음, 끄기 없음, 1GB page 백킹 판정 없음.
#
#   사용 예
#     . .\StartVmsSequential_v1_4.ps1
#     Start-VmsSequential -VMHostName esx01,esx02,esx03 -All
#     Start-VmsSequential -VMHostName esx0* -All -NamePattern "*ev0*" -Exclude "*ev09"
#     Start-VmsSequential -VMHostName esx01 -VMName esx01ev01,esx01ev02
#     Start-VmsSequential -VMHostName esx0* -All -Gate Tools
#     Start-VmsSequential -VMHostName esx0* -All -WhatIf
#     Get-VmHostMemStatus -VMHostName esx01
# ==============================================================================


# 1GB lpage 관련 키 (표시용). sched.mem.pin 은 vCenter 가 값을 돌려주지 않아 표에서 뺀다.
$Global:StartVms_LpageKeys = @("sched.mem.lpage.enable1GPage", "sched.mem.prealloc", "sched.mem.prealloc.pinnedMainMem", "sched.swap.vmxSwapEnabled")


function Get-VmViewRows {
    # 호스트의 VM 을 Get-View 1회로 읽어 행으로 만든다 (전원, 메모리, 점유량, 키).
    param ([Parameter(Mandatory=$true)] $VMHost, [string[]]$Names = @())
    $Views = @(Get-View -ViewType VirtualMachine -SearchRoot $VMHost.ExtensionData.MoRef `
                 -Property Name, Runtime.PowerState, Config.Hardware.MemoryMB, Config.ExtraConfig, `
                           Config.MemoryReservationLockedToMax, Config.MemoryAllocation, Summary.QuickStats -ErrorAction Stop)
    $Rows = @()
    foreach ($Vw in $Views) {
        if ($Names.Count -gt 0 -and $Vw.Name -notin $Names) { continue }
        $Ec = @{}
        foreach ($O in @($Vw.Config.ExtraConfig)) { if ($O -and $O.Key) { $Ec[$O.Key] = "$($O.Value)" } }
        $CfgMB = [double]$Vw.Config.Hardware.MemoryMB
        $UseMB = [double]$Vw.Summary.QuickStats.HostMemoryUsage
        $ResMB = 0; if ($null -ne $Vw.Config.MemoryAllocation.Reservation) { $ResMB = [double]$Vw.Config.MemoryAllocation.Reservation }
        $Rows += [PSCustomObject][ordered]@{
            Host         = $VMHost.Name
            VM           = $Vw.Name
            MoRef        = $Vw.MoRef
            PowerState   = "$($Vw.Runtime.PowerState)"
            ConfiguredGB = [math]::Round($CfgMB / 1024, 1)
            ConsumedGB   = [math]::Round($UseMB / 1024, 1)
            Pct          = $(if ($CfgMB -gt 0) { [math]::Round(100.0 * $UseMB / $CfgMB, 1) } else { 0 })
            Reserved100  = (($ResMB -ge $CfgMB) -or [bool]$Vw.Config.MemoryReservationLockedToMax)
            Lpage1GB     = $(if ($Ec.ContainsKey("sched.mem.lpage.enable1GPage")) { $Ec["sched.mem.lpage.enable1GPage"] } else { "없음" })
            Prealloc     = $(if ($Ec.ContainsKey("sched.mem.prealloc")) { $Ec["sched.mem.prealloc"] } else { "없음" })
            PinnedMain   = $(if ($Ec.ContainsKey("sched.mem.prealloc.pinnedMainMem")) { $Ec["sched.mem.prealloc.pinnedMainMem"] } else { "없음" })
            VmxSwap      = $(if ($Ec.ContainsKey("sched.swap.vmxSwapEnabled")) { $Ec["sched.swap.vmxSwapEnabled"] } else { "없음" })
        }
    }
    return $Rows
}


function Read-VmMemNow {
    # MoRef 로 전원 상태와 점유량만 다시 읽는다 (빠른 확인용).
    param ([Parameter(Mandatory=$true)] $MoRef)
    $Vw = Get-View -Id $MoRef -Property Runtime.PowerState, Config.Hardware.MemoryMB, Summary.QuickStats, Guest -ErrorAction Stop
    $CfgMB = [double]$Vw.Config.Hardware.MemoryMB
    $UseMB = [double]$Vw.Summary.QuickStats.HostMemoryUsage
    return [PSCustomObject]@{
        PowerState = "$($Vw.Runtime.PowerState)"
        ConsumedGB = [math]::Round($UseMB / 1024, 1)
        ConfiguredGB = [math]::Round($CfgMB / 1024, 1)
        Pct        = $(if ($CfgMB -gt 0) { [math]::Round(100.0 * $UseMB / $CfgMB, 1) } else { 0 })
        Tools      = "$($Vw.Guest.ToolsRunningStatus)"
        ToolsStatus = "$($Vw.Guest.ToolsStatus)"
        GuestState = "$($Vw.Guest.GuestState)"
    }
}


function Write-HostGroupedTable {
    # 호스트 이름을 윗줄로, 그 아래 Host 열을 뺀 표
    param ([object[]]$Rows, [string[]]$Columns, [string]$Color = "White")
    foreach ($Hg in @($Rows | Group-Object Host | Sort-Object Name)) {
        Write-Host "  [$($Hg.Name)]" -ForegroundColor $Color
        $Hg.Group | Format-Table -Property $Columns -AutoSize -Wrap | Out-String -Width 320 | ForEach-Object { $_.TrimEnd() } | Write-Host -ForegroundColor $Color
    }
}


function Get-VmHostMemStatus {
    # 호스트(들)의 VM 전원, 구성 메모리, 호스트 메모리 점유량, 1GB lpage 키를 표로 보여 준다. 읽기만 한다.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [string[]]$VMHostName,
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false)] [switch]$PassThru
    )
    $Hosts = @(); foreach ($P in $VMHostName) { $Hosts += @(Get-VMHost -Name $P -ErrorAction SilentlyContinue) }
    $Hosts = @($Hosts | Sort-Object Name -Unique)
    if ($Hosts.Count -eq 0) { Write-Error "호스트 없음: $($VMHostName -join ', ')"; return }
    $Rows = @(); foreach ($H in $Hosts) { $Rows += Get-VmViewRows -VMHost $H -Names $VMName }
    Write-Host "`n[VM 호스트 메모리 점유 - ConsumedGB 는 오버헤드 포함, 1GB page 여부는 표시하지 않음]" -ForegroundColor Green
    Write-HostGroupedTable -Rows ($Rows | Sort-Object Host, VM) -Columns @("VM","PowerState","ConfiguredGB","ConsumedGB","Pct","Reserved100","Lpage1GB","Prealloc","PinnedMain","VmxSwap")
    if ($PassThru) { return $Rows }
}


function Start-VmsSequential {
    # --------------------------------------------------------------------------
    # 호스트별로 VM 을 하나씩 켠다. 전원 켜기 작업이 끝나면 점유량을 읽어 표시하고 다음 VM.
    # 호스트끼리는 동시에 진행한다.
    # --------------------------------------------------------------------------
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
    param (
        [Parameter(Mandatory=$true,  HelpMessage="대상 ESXi 호스트 (여러 개, 와일드카드)")] [string[]]$VMHostName,
        [Parameter(Mandatory=$false, HelpMessage="켤 VM 이름 (순서대로)")] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false, HelpMessage="호스트의 VM 전부를 이름순으로")] [switch]$All,
        [Parameter(Mandatory=$false, HelpMessage="-All 이름 와일드카드")] [string]$NamePattern = "*",
        [Parameter(Mandatory=$false, HelpMessage="-All 제외 와일드카드")] [string[]]$Exclude = @(),
        [Parameter(Mandatory=$false, HelpMessage="다음 VM 기준: PowerOn(작업 완료) | Tools(게스트 부팅 완료)")] [ValidateSet("PowerOn","Tools")] [string]$Gate = "PowerOn",
        [Parameter(Mandatory=$false, HelpMessage="확인 주기 (초)")] [int]$PollSeconds = 5,
        [Parameter(Mandatory=$false, HelpMessage="전원 켜기 작업 최대 대기 (분)")] [int]$TaskTimeoutMinutes = 90,
        [Parameter(Mandatory=$false, HelpMessage="Tools 게이트 최대 대기 (분)")] [int]$ToolsTimeoutMinutes = 20,
        [Parameter(Mandatory=$false, HelpMessage="실패해도 그 호스트의 다음 VM 계속")] [switch]$ContinueOnIncomplete,
        [Parameter(Mandatory=$false, HelpMessage="1GB page 키가 TRUE 가 아니면 중단")] [switch]$Require1GPage,
        [Parameter(Mandatory=$false, HelpMessage="결과 행 객체 반환")] [switch]$PassThru
    )

    # ---- 1. 호스트, VM 확인 (켜기 전에 전부 확인, 하나라도 이상하면 안 켠다) ----
    $Hosts = @(); foreach ($P in $VMHostName) { $Hosts += @(Get-VMHost -Name $P -ErrorAction SilentlyContinue) }
    $Hosts = @($Hosts | Sort-Object Name -Unique)
    if ($Hosts.Count -eq 0) { Write-Error "호스트 없음: $($VMHostName -join ', ')"; return }
    foreach ($H in $Hosts) { if ($H.ConnectionState -ne "Connected") { Write-Error "호스트 '$($H.Name)' 이(가) Connected 가 아님 (현재 $($H.ConnectionState))"; return } }
    if ($VMName.Count -eq 0 -and -not $All) { Write-Error "-VMName 으로 순서를 주거나 -All 을 지정하십시오."; return }

    $Queues = @{}   # 호스트 이름 -> VM 행 배열 (켤 순서)
    $Plan = @()
    foreach ($H in $Hosts) {
        $Rows = @(Get-VmViewRows -VMHost $H)
        if ($VMName.Count -gt 0) {
            # 준 순서 유지, 중복 제거
            $Sel = @(); $Seen = @{}
            foreach ($N in $VMName) { foreach ($R in @($Rows | Where-Object { $_.VM -like $N } | Sort-Object VM)) { if (-not $Seen.ContainsKey($R.VM)) { $Seen[$R.VM] = $true; $Sel += $R } } }
            $Rows = $Sel
        } else {
            $Rows = @($Rows | Where-Object { $_.VM -like $NamePattern })
            foreach ($Pat in $Exclude) { $Rows = @($Rows | Where-Object { $_.VM -notlike $Pat }) }
            $Rows = @($Rows | Sort-Object VM)
        }
        if ($Rows.Count -eq 0) { Write-Warning "[$($H.Name)] 조건에 맞는 VM 없음 - 이 호스트는 건너뜁니다."; continue }
        $Queues[$H.Name] = $Rows
        $Plan += $Rows
        $FreeGB = [math]::Round($H.MemoryTotalGB - $H.MemoryUsageGB, 1)
        $NeedGB = ($Rows | Where-Object { $_.PowerState -ne "poweredOn" } | Measure-Object -Property ConfiguredGB -Sum).Sum
        if ($null -eq $NeedGB) { $NeedGB = 0 }
        Write-Host "[$($H.Name)] 켤 순서: $(($Rows | ForEach-Object { $_.VM }) -join ' -> ')   (새로 배정할 메모리 $([math]::Round($NeedGB,1)) GB / 호스트 여유 $FreeGB GB)" -ForegroundColor Cyan
        if ($NeedGB -gt $FreeGB) { Write-Warning "[$($H.Name)] 요구량이 호스트 여유 메모리를 넘습니다. 뒤쪽 VM 의 전원 켜기가 실패할 수 있습니다." }
    }
    if ($Plan.Count -eq 0) { Write-Error "켤 VM 이 없습니다."; return }

    Write-Host "`n[사전 확인 - 1GB lpage 키 (sched.mem.pin 은 vCenter 미조회)]" -ForegroundColor Yellow
    Write-HostGroupedTable -Rows $Plan -Columns @("VM","PowerState","ConfiguredGB","Reserved100","Lpage1GB","Prealloc","PinnedMain","VmxSwap")
    $NoLp = @($Plan | Where-Object { $_.Lpage1GB -notmatch '^(TRUE|true|1)$' })
    if ($NoLp.Count -gt 0) {
        $Msg = "sched.mem.lpage.enable1GPage 가 TRUE 가 아닌 VM: " + (($NoLp | ForEach-Object { "$($_.VM)=$($_.Lpage1GB)" }) -join ", ")
        if ($Require1GPage) { Write-Error "$Msg - -Require1GPage 지정으로 중단"; return }
        Write-Warning "$Msg - 그대로 진행"
    }
    $GateText = $(if ($Gate -eq "Tools") { "전원 켜기 작업 완료 후 VMware Tools 실행까지" } else { "전원 켜기 작업 완료" })
    Write-Host "[게이트] $GateText 이면 그 호스트의 다음 VM. 호스트 $($Queues.Count)개 동시 진행, 확인 주기 $PollSeconds 초" -ForegroundColor Cyan
    if ($WhatIfPreference) { Write-Host "-WhatIf: 켜지 않습니다." -ForegroundColor Yellow; return }
    if (-not $PSCmdlet.ShouldProcess("호스트 $($Queues.Count)개, VM $($Plan.Count)대", "순차 전원 켜기")) { return }

    # ---- 2. 호스트별 대기열을 한 루프에서 동시 진행 ----
    $St = @{}   # 호스트 -> 상태
    foreach ($HN in $Queues.Keys) { $St[$HN] = @{ Idx = 0; Task = $null; StartedAt = $null; Phase = "Next"; Cur = $null; Done = $false } }
    $ResultsList = New-Object System.Collections.Generic.List[object]   # 스크립트블록 안에서 Add 로 쌓는다 (+= 는 스코프 문제)
    $Recheck = @()
    $Now = { Get-Date -Format "HH:mm:ss" }
    $AddResult = { param($Row, $Res, $Elapsed, $Mem, $Tools, $Note)
        $ResultsList.Add([PSCustomObject][ordered]@{
            Host = $Row.Host; VM = $Row.VM; Result = $Res
            Elapsed = $(if ($Elapsed) { "{0:mm\:ss}" -f $Elapsed } else { "" })
            ConsumedGB = $(if ($Mem) { $Mem.ConsumedGB } else { $null }); ConfiguredGB = $Row.ConfiguredGB
            Pct = $(if ($Mem) { $Mem.Pct } else { $null }); Tools = $Tools; Note = $Note
        })
    }

    while ($true) {
        $Active = $false
        foreach ($HN in @($Queues.Keys | Sort-Object)) {
            $S = $St[$HN]; if ($S.Done) { continue }
            $Q = $Queues[$HN]

            # (a) 다음 VM 켜기
            while ($S.Phase -eq "Next") {
                if ($S.Idx -ge $Q.Count) { $S.Done = $true; Write-Host "$(& $Now) [$HN] 완료 - VM $($Q.Count)대 처리" -ForegroundColor Green; break }
                $Row = $Q[$S.Idx]; $S.Cur = $Row
                if ($Row.PowerState -eq "poweredOn") {
                    $Mem = Read-VmMemNow -MoRef $Row.MoRef
                    Write-Host "$(& $Now) [$HN] $($Row.VM) 이미 켜져 있음 - 호스트 메모리 $($Mem.ConsumedGB) / $($Row.ConfiguredGB) GB ($($Mem.Pct)%)" -ForegroundColor DarkGray
                    & $AddResult $Row "AlreadyOn" $null $Mem "" ""
                    $S.Idx++; continue
                }
                try {
                    $Vw = Get-View -Id $Row.MoRef -Property Name -ErrorAction Stop
                    $S.Task = $Vw.PowerOnVM_Task($null); $S.StartedAt = Get-Date; $S.Phase = "Task"
                    Write-Host "$(& $Now) [$HN] $($Row.VM) 전원 켜기 시작 (구성 메모리 $($Row.ConfiguredGB) GB)" -ForegroundColor Yellow
                }
                catch {
                    Write-Warning "$(& $Now) [$HN] $($Row.VM) 전원 켜기 호출 실패: $($_.Exception.Message)"
                    & $AddResult $Row "StartFailed" $null $null "" $_.Exception.Message
                    if ($ContinueOnIncomplete) { $S.Idx++ } else { $S.Done = $true; Write-Warning "[$HN] 이 호스트는 여기서 멈춥니다 (-ContinueOnIncomplete 로 계속 가능)"; break }
                }
            }
            if ($S.Done) { continue }
            $Active = $true
            $Row = $S.Cur

            # (b) 전원 켜기 작업 상태
            if ($S.Phase -eq "Task") {
                $TI = (Get-View -Id $S.Task -Property Info -ErrorAction Stop).Info
                $El = (Get-Date) - $S.StartedAt
                switch ("$($TI.State)") {
                    "success" {
                        $Mem = Read-VmMemNow -MoRef $Row.MoRef
                        Write-Host "$(& $Now) [$HN] $($Row.VM) 켜짐, 소요 $("{0:mm\:ss}" -f $El), 호스트 메모리 $($Mem.ConsumedGB) / $($Row.ConfiguredGB) GB ($($Mem.Pct)%)" -ForegroundColor Green
                        if ($Gate -eq "Tools") { $S.Phase = "Tools"; $S.ToolsAt = Get-Date; $S.Mem = $Mem; $S.El = $El }
                        else {
                            & $AddResult $Row "PoweredOn" $El $Mem "" ""
                            if ($Mem.Pct -lt 99) { $Recheck += @{ Row = $Row; At = (Get-Date).AddSeconds(25) } }
                            $S.Phase = "Next"; $S.Idx++
                        }
                    }
                    "error" {
                        $Msg = "$($TI.Error.LocalizedMessage)"
                        Write-Warning "$(& $Now) [$HN] $($Row.VM) 전원 켜기 실패 ($("{0:mm\:ss}" -f $El)): $Msg"
                        & $AddResult $Row "StartFailed" $El $null "" $Msg
                        if ($ContinueOnIncomplete) { $S.Phase = "Next"; $S.Idx++ } else { $S.Done = $true; Write-Warning "[$HN] 이 호스트는 여기서 멈춥니다 (-ContinueOnIncomplete 로 계속 가능)" }
                    }
                    default {
                        if ($El.TotalMinutes -ge $TaskTimeoutMinutes) {
                            Write-Warning "$(& $Now) [$HN] $($Row.VM) 전원 켜기 작업이 $TaskTimeoutMinutes 분 안에 끝나지 않음 (진행 $($TI.Progress)%). 작업은 vCenter 에서 계속 진행됩니다."
                            & $AddResult $Row "Timeout" $El $null "" "작업 진행 $($TI.Progress)%"
                            if ($ContinueOnIncomplete) { $S.Phase = "Next"; $S.Idx++ } else { $S.Done = $true }
                        }
                        elseif ([int]$El.TotalSeconds % 30 -lt $PollSeconds) {
                            Write-Host "$(& $Now) [$HN] $($Row.VM) 전원 켜기 진행 중 $($TI.Progress)% ($("{0:mm\:ss}" -f $El))" -ForegroundColor DarkGray
                        }
                    }
                }
            }
            # (c) Tools 게이트
            elseif ($S.Phase -eq "Tools") {
                $G = Read-VmMemNow -MoRef $Row.MoRef
                $ElT = (Get-Date) - $S.ToolsAt
                if ($G.Tools -eq "guestToolsRunning" -and $G.GuestState -eq "running") {
                    Write-Host "$(& $Now) [$HN] $($Row.VM) 게스트 부팅 완료 (Tools 실행, 대기 $("{0:mm\:ss}" -f $ElT))" -ForegroundColor Green
                    & $AddResult $Row "PoweredOn" $S.El $S.Mem "Running" ""
                    $S.Phase = "Next"; $S.Idx++
                }
                elseif ($G.ToolsStatus -eq "toolsNotInstalled") {
                    Write-Warning "$(& $Now) [$HN] $($Row.VM) VMware Tools 없음 - 부팅 완료를 판정할 수 없어 전원 상태만으로 넘어갑니다."
                    & $AddResult $Row "PoweredOn" $S.El $S.Mem "NoTools" ""
                    $S.Phase = "Next"; $S.Idx++
                }
                elseif ($G.PowerState -ne "poweredOn") {
                    Write-Warning "$(& $Now) [$HN] $($Row.VM) 대기 중 꺼짐"
                    & $AddResult $Row "PoweredOff" $S.El $S.Mem "" ""
                    if ($ContinueOnIncomplete) { $S.Phase = "Next"; $S.Idx++ } else { $S.Done = $true }
                }
                elseif ($ElT.TotalMinutes -ge $ToolsTimeoutMinutes) {
                    Write-Warning "$(& $Now) [$HN] $($Row.VM) $ToolsTimeoutMinutes 분 안에 Tools 가 실행되지 않음 (tools=$($G.Tools) guest=$($G.GuestState))"
                    & $AddResult $Row "ToolsTimeout" $S.El $S.Mem $G.Tools ""
                    if ($ContinueOnIncomplete) { $S.Phase = "Next"; $S.Idx++ } else { $S.Done = $true }
                }
            }
        }

        # (d) 켜진 직후 점유량이 낮게 읽힌 VM 은 25초 뒤 한 번 다시 읽어 결과 표를 갱신
        if ($Recheck.Count -gt 0) {
            $Keep = @()
            foreach ($R in $Recheck) {
                if ((Get-Date) -lt $R.At) { $Keep += $R; continue }
                $M2 = Read-VmMemNow -MoRef $R.Row.MoRef
                foreach ($X in $ResultsList) { if ($X.Host -eq $R.Row.Host -and $X.VM -eq $R.Row.VM) { $X.ConsumedGB = $M2.ConsumedGB; $X.Pct = $M2.Pct } }
                Write-Host "$(& $Now) [$($R.Row.Host)] $($R.Row.VM) 호스트 메모리 재확인 $($M2.ConsumedGB) / $($R.Row.ConfiguredGB) GB ($($M2.Pct)%)" -ForegroundColor DarkGray
            }
            $Recheck = $Keep
            if ($Recheck.Count -gt 0) { $Active = $true }
        }

        if (-not $Active) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    # ---- 3. 결과 ----
    $Results = @($ResultsList.ToArray())
    $Bad = @($Results | Where-Object { $_.Result -notin @("PoweredOn","AlreadyOn") })
    Write-Host "`n══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "[결과 - 호스트 $($Queues.Count)개, VM $($Results.Count)대: 켜짐 $(@($Results | Where-Object Result -eq 'PoweredOn').Count)대, 이미 켜져 있음 $(@($Results | Where-Object Result -eq 'AlreadyOn').Count)대, 실패, 시간초과 $($Bad.Count)대]" -ForegroundColor $(if ($Bad.Count -eq 0) { "Green" } else { "Yellow" })
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-HostGroupedTable -Rows $Results -Columns @("VM","Result","Elapsed","ConsumedGB","ConfiguredGB","Pct","Tools","Note")
    Write-Host "  ConsumedGB = 호스트 물리 메모리 점유(오버헤드 포함). 1GB page 백킹 여부는 이 스크립트가 판정하지 않음" -ForegroundColor DarkGray
    if ($PassThru) { return $Results }
}

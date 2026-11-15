# ==============================================================================
# StartVmsWithBackingGate  v1.3  (2026-09-23)
#
#   v1.2 -> v1.3 (사용자 지적 0923: "점유량만 보고 완료로 찍는다 — 1GB 백킹은
#                 vsish /memory/lpage/vmLpage/<worldID> 에서 봐야 한다")
#     -Gate 에 Lpage 를 추가하고 기본값으로 둔다. Lpage 게이트는 ESXi 에 SSH 로
#     vsish -e get /memory/lpage/vmLpage/<worldID> 를 읽어
#       "Current number of 1GB page backings"  (현재 1GB 백킹 수)
#       "1GB page backing attempts failed"      (실패 횟수)
#     를 얻고, 1GB 백킹 수가 목표(구성 메모리 GB × LpageCompletePercent) 에
#     닿아야 완료로 본다. 늘지 않고 실패가 쌓이면 LpageFailed 로 멈춘다.
#     호스트 메모리 점유량(Backing 게이트)은 오버헤드까지 포함한 총량이라
#     1GB 로 깔렸는지는 말해 주지 않는다 — 참고 표시로만 남긴다.
#
#     SSH 두 방식 중 하나
#       (a) ssh.exe (Windows 10+ OpenSSH 내장) + 키 인증 : -EsxiSshKey <개인키>
#           ESXi 쪽 /etc/ssh/keys-root/authorized_keys 에 공개키 등록 필요.
#       (b) Posh-SSH 모듈 + 비밀번호            : -EsxiSshCredential (Get-Credential)
#     -EsxiSshHost 를 안 주면 -VMHostName 을 그대로 접속 주소로 쓴다.
#
#     -Gate 는 이제 목록이다: -Gate Lpage,Tools 처럼 순서대로 통과해야 다음 VM.
#       Lpage(기본) · Backing(점유량, v1.2 동작) · Tools(게스트 부팅) · Power(전원만)
#     새 함수 Get-VmLpageStatus : 켜진 VM 전부의 1GB 백킹 수·목표·실패를 표로.
#
#   v1.1 -> v1.2 (사용자 지적 0923: "백킹 100% 이상인데도 두 번 더 확인해 느리다")
#     백킹 비율이 100% 이상이면 (구성 메모리 전량 + 오버헤드가 호스트에 붙은 상태)
#     더 늘어날 것이 없으므로 안정 표본을 기다리지 않고 그 자리에서 완료로 본다.
#     안정 표본(StableSamples) 확인은 목표 비율(CompletePercent, 기본 99%)에는
#     닿았지만 100% 미만인 경우에만 한다. 기본 StableSamples 도 3 -> 2 로 줄였다.
#     예전 동작이 필요하면 -NoFastComplete.
#
#   v1.0 -> v1.1 (사용자 요청 0923: "호스트의 VM 을 순차로, 다 켜지면 다음 VM")
#     -All            : VM 이름을 안 줘도 호스트의 VM 전부를 이름순으로 켠다.
#                       -NamePattern "*ev*" 로 고르고 -Exclude 로 뺀다. 켜기 전에
#                       순서를 표로 보여 준다.
#     -Gate           : "다 켜졌다" 의 기준을 고른다.
#                         Backing (기본) : 메모리 백킹이 다 올라옴 (v1.0 동작)
#                         Tools          : 게스트 부팅 완료 — VMware Tools 실행 중
#                                          (guestToolsRunning) 이고 게스트 상태 running
#                         Both           : Backing 뒤 Tools 까지
#                         Power          : 전원 상태 poweredOn 만 확인 (기다리지 않음)
#                       Tools 가 없는 VM 은 판정할 수 없어 NoTools 로 표시하고
#                       전원 상태만으로 다음으로 넘어간다.
#     -ToolsTimeoutMinutes : Tools 게이트 최대 대기 (기본 20분)
#
#   지정한 ESXi 호스트에서 VM 을 하나씩 켜되, 켠 VM 의 "백킹 용량"이 다 올라올
#   때까지 기다렸다가 다음 VM 을 켠다.
#
#   [백킹 용량이란 무엇을 재는가 — 이 스크립트의 판정 근거]
#     이 프로젝트의 VM 은 메모리를 100% 예약하고 부팅 시 전량 미리 배정한다
#     (기술교재 37.2 의 차단 세트 — memReservation 전체 / sched.mem.pin=TRUE /
#      sched.mem.prealloc=TRUE / sched.swap.vmxSwapEnabled=FALSE /
#      sched.mem.lpage.enable1GPage=TRUE).
#     prealloc 이 켜져 있으면 호스트는 VM 을 켠 뒤 게스트 메모리 전량을 호스트
#     물리 메모리에 실제로 붙인다. 그 붙는 양이 여기서 말하는 "백킹 용량" 이고,
#     vCenter/ESXi 가 VM 별로 보고하는 값은
#         Summary.QuickStats.HostMemoryUsage   (= 이 VM 이 실제로 점유 중인
#                                                 호스트 물리 메모리, MB, 오버헤드 포함)
#     이다. 이 값이 구성 메모리(Config.Hardware.MemoryMB) 에 도달하고 더 이상
#     늘지 않으면 백킹이 다 올라온 것으로 본다.
#     -> 판정식 : HostMemoryUsage / MemoryMB >= CompletePercent 가
#                 StableSamples 회 연속, 그리고 그 사이 증가분이 허용오차 이내.
#     QuickStats 는 20초 안팎으로 갱신되므로 PollSeconds 기본값도 20 이다.
#
#   [1GB 페이지로 백킹되고 있는지는 무엇으로 보는가 — 범위를 분명히 한다]
#     vCenter API 는 "이 VM 이 몇 GB 를 점유 중인가" 는 알려주지만
#     "그 메모리가 1GB 페이지로 깔렸는가" 는 알려주지 않는다. 페이지 크기는
#     호스트 안에서만 보인다. 그래서 이 스크립트는 두 가지를 나눠서 다룬다.
#       (1) 설정 확인 — VM 의 sched.mem.lpage.enable1GPage 등 백킹 키 값을 읽어
#           표로 보여준다. 켜져 있지 않으면 켜기 전에 경고한다(-Require1GPage
#           를 주면 아예 중단). 이건 이 스크립트가 끝까지 책임진다.
#       (2) 실제 페이지 크기 확인 — 호스트에서 직접 봐야 한다.
#           -EmitHostCheckScript <경로> 를 주면 호스트에 붙여 넣고 돌릴 셸
#           스크립트를 만들어 준다. 그 안의 명령은 이 프로젝트가 이미 쓰고 있는
#           것들(esxcli 고급설정 조회 · memstats · vsish)이며, 출력은 가공하지
#           않고 원문 그대로 남긴다. 어느 필드를 1GB 백킹의 증거로 삼을지는
#           호스트 빌드에서 한 번 확인한 뒤 고정하는 것이 맞다.
#
#   [무엇을 하지 않는가]
#     VM 설정을 바꾸지 않는다. 백킹 키도 읽기만 한다. 끄지도 않는다.
#     켜는 것 외의 전원 조작을 하지 않는다.
#
#   사용 예
#     . .\StartVmsWithBackingGate_v1_3.ps1
#     Start-VmsWithBackingGate -VMHostName esx8 -All                       # 전부, 이름순, 백킹 게이트
#     Start-VmsWithBackingGate -VMHostName esx8 -All -Gate Tools           # 전부, 게스트 부팅 완료 게이트
#     Start-VmsWithBackingGate -VMHostName esx8 -All -NamePattern "*ev0*" -Exclude "*ev09" -Gate Both
#     Start-VmsWithBackingGate -VMHostName esx8 -VMName pvm01,svm01,svm02  # 준 순서대로 (v1.0 과 동일)
#     Start-VmsWithBackingGate -VMHostName esx8 -All -WhatIf               # 순서·설정만 보고 켜지 않음
#     Start-VmsWithBackingGate -VMHostName esx8 -All -PollSeconds 10       # 더 자주 확인 (QuickStats 갱신은 20초 안팎)
#     Start-VmsWithBackingGate -VMHostName esx03 -All -EsxiSshKey C:\keys\esxi_id_ed25519          # 1GB 백킹 게이트 (기본)
#     Start-VmsWithBackingGate -VMHostName esx03 -All -Gate Lpage,Tools -EsxiSshCredential (Get-Credential root)
#     Get-VmLpageStatus -VMHostName esx03 -EsxiSshKey C:\keys\esxi_id_ed25519   # 켜진 VM 전부 1GB 백킹 표
#     Get-VmBackingStatus -VMName pvm01 | Format-Table -AutoSize
# ==============================================================================


function Get-VmBackingStatus {
    # --------------------------------------------------------------------------
    # VM 하나의 백킹 현황을 한 줄로 돌려준다. 켜져 있든 꺼져 있든 동작한다.
    # 값은 조회 시점의 스냅샷이며, 캐시를 피하려고 매번 Get-View 로 다시 읽는다.
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="VM 이름")]
        [string[]]$VMName,

        [Parameter(Mandatory=$false, HelpMessage="이 호스트에 있는 VM 으로 한정")]
        [string]$VMHostName = ""
    )

    process {
        foreach ($Name in $VMName) {
            $Vm = if ([string]::IsNullOrWhiteSpace($VMHostName)) {
                      Get-VM -Name $Name -ErrorAction SilentlyContinue
                  } else {
                      Get-VM -Name $Name -Location (Get-VMHost -Name $VMHostName -ErrorAction Stop) -ErrorAction SilentlyContinue
                  }
            if (-not $Vm) {
                Write-Warning "VM '$Name' 을(를) 찾지 못했습니다. 건너뜁니다."
                continue
            }
            $Vm = @($Vm)[0]

            # QuickStats 는 캐시가 남기 쉬우므로 MoRef 로 다시 읽는다
            $View = Get-View -Id $Vm.ExtensionData.MoRef -Property `
                        Name, Runtime.PowerState, Summary.QuickStats, `
                        Config.Hardware.MemoryMB, Config.MemoryAllocation, `
                        Config.MemoryReservationLockedToMax -ErrorAction Stop

            $ConfiguredMB = [double]$View.Config.Hardware.MemoryMB
            $ConsumedMB   = [double]$View.Summary.QuickStats.HostMemoryUsage      # 호스트 물리 메모리 점유(오버헤드 포함)
            $OverheadMB   = [double]$View.Summary.QuickStats.ConsumedOverheadMemory
            $ReservedMB   = if ($null -ne $View.Config.MemoryAllocation.Reservation) { [double]$View.Config.MemoryAllocation.Reservation } else { 0 }
            $Pct          = if ($ConfiguredMB -gt 0) { [math]::Round(100.0 * $ConsumedMB / $ConfiguredMB, 2) } else { 0 }

            # 백킹 관련 vmx 키 (기술교재 37.2). 없으면 "(미설정)" 으로 표시한다.
            $Keys = @{}
            foreach ($K in @("sched.mem.pin", "sched.mem.prealloc",
                             "sched.swap.vmxSwapEnabled", "sched.mem.lpage.enable1GPage")) {
                $S = Get-AdvancedSetting -Entity $Vm -Name $K -ErrorAction SilentlyContinue | Select-Object -First 1
                $Keys[$K] = if ($S) { [string]$S.Value } else { "(미설정)" }
            }

            [PSCustomObject][ordered]@{
                VM            = $View.Name
                VMHost        = $Vm.VMHost.Name
                PowerState    = [string]$View.Runtime.PowerState
                ConfiguredGB  = [math]::Round($ConfiguredMB / 1024, 1)
                ConsumedGB    = [math]::Round($ConsumedMB   / 1024, 1)
                OverheadGB    = [math]::Round($OverheadMB   / 1024, 2)
                BackedPct     = $Pct
                Reserved100   = ($ReservedMB -ge $ConfiguredMB) -or [bool]$View.Config.MemoryReservationLockedToMax
                Pin           = $Keys["sched.mem.pin"]
                Prealloc      = $Keys["sched.mem.prealloc"]
                VmxSwap       = $Keys["sched.swap.vmxSwapEnabled"]
                Lpage1GB      = $Keys["sched.mem.lpage.enable1GPage"]
                ConfiguredMB  = $ConfiguredMB
                ConsumedMB    = $ConsumedMB
                SampledAt     = Get-Date
            }
        }
    }
}


function Wait-VmBackingComplete {
    # --------------------------------------------------------------------------
    # VM 하나의 백킹이 다 올라올 때까지 기다린다.
    #   완료 조건 : PoweredOn 이고, BackedPct >= CompletePercent 인 상태가
    #               StableSamples 회 연속이며, 그 구간 증가분이 허용오차 이내.
    #   정체 감지 : 목표에 못 미친 채 StallSamples 회 연속 증가가 없으면 정체로
    #               보고 경고한다(반환 객체의 Result = "Stalled").
    # 반환 : Result(Completed|Stalled|Timeout|PoweredOff) + 마지막 스냅샷 + 이력
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,  HelpMessage="VM 이름")]                    [string]$VMName,
        [Parameter(Mandatory=$false, HelpMessage="이 호스트로 한정")]           [string]$VMHostName = "",
        [Parameter(Mandatory=$false, HelpMessage="완료로 볼 백킹 비율 (%)")]    [double]$CompletePercent = 99.0,
        [Parameter(Mandatory=$false, HelpMessage="폴링 간격 (초)")]             [int]$PollSeconds = 20,
        [Parameter(Mandatory=$false, HelpMessage="완료 판정에 필요한 연속 표본 수 (100% 미만일 때만 적용)")] [int]$StableSamples = 2,
        [Parameter(Mandatory=$false, HelpMessage="증가 없음으로 볼 허용오차 (구성 메모리 대비 %)")] [double]$StableTolerancePercent = 0.1,
        [Parameter(Mandatory=$false, HelpMessage="100% 이상이어도 안정 표본을 기다리는 예전 동작")] [switch]$NoFastComplete,
        [Parameter(Mandatory=$false, HelpMessage="정체로 볼 연속 표본 수")]     [int]$StallSamples = 15,
        [Parameter(Mandatory=$false, HelpMessage="최대 대기 시간 (분)")]        [int]$TimeoutMinutes = 90,
        [Parameter(Mandatory=$false, HelpMessage="진행 상황을 한 줄씩 출력")]   [switch]$ShowProgress
    )

    $Deadline    = (Get-Date).AddMinutes($TimeoutMinutes)
    $StableCount = 0
    $StallCount  = 0
    $PrevMB      = -1.0
    $History     = @()
    $Last        = $null
    $Result      = "Timeout"

    while ((Get-Date) -lt $Deadline) {
        $Last = Get-VmBackingStatus -VMName $VMName -VMHostName $VMHostName
        if (-not $Last) { Write-Error "VM '$VMName' 조회 실패. 대기를 중단합니다."; return $null }
        $History += $Last

        $TolMB = $Last.ConfiguredMB * $StableTolerancePercent / 100.0
        $Delta = if ($PrevMB -lt 0) { [double]::PositiveInfinity } else { $Last.ConsumedMB - $PrevMB }

        if ($ShowProgress) {
            $DeltaText = if ($PrevMB -lt 0) { "-" } else { "{0:+0.0;-0.0;0.0} GB" -f ($Delta / 1024) }
            Write-Host ("    {0}  {1,-11}  {2,8:N1} / {3,8:N1} GB  ({4,6:N2}%)  증가 {5}" -f `
                        (Get-Date -Format "HH:mm:ss"), $Last.PowerState, $Last.ConsumedGB, `
                        $Last.ConfiguredGB, $Last.BackedPct, $DeltaText) -ForegroundColor DarkGray
        }

        if ($Last.PowerState -ne "poweredOn") {
            # 켜는 도중 꺼졌다면 더 기다릴 이유가 없다
            if ($PrevMB -ge 0) { $Result = "PoweredOff"; break }
        }
        elseif ($Last.BackedPct -ge 100.0 -and -not $NoFastComplete) {
            # 구성 메모리 전량(오버헤드 포함)이 붙었다 — 더 늘 것이 없으니 바로 완료
            if ($ShowProgress) { Write-Host "    100% 이상 도달 — 안정 표본을 기다리지 않고 완료로 봅니다." -ForegroundColor DarkGray }
            $Result = "Completed"; break
        }
        elseif ($Last.BackedPct -ge $CompletePercent) {
            if ($PrevMB -ge 0 -and [math]::Abs($Delta) -le $TolMB) { $StableCount++ } else { $StableCount = 1 }
            $StallCount = 0
            if ($StableCount -ge $StableSamples) { $Result = "Completed"; break }
        }
        else {
            $StableCount = 0
            if ($PrevMB -ge 0 -and $Delta -le $TolMB) { $StallCount++ } else { $StallCount = 0 }
            if ($StallCount -ge $StallSamples) { $Result = "Stalled"; break }
        }

        $PrevMB = $Last.ConsumedMB
        Start-Sleep -Seconds $PollSeconds
    }

    $FinalPct  = $null; $FinalGB = $null; $TargetGB = $null; $Elapsed = $null
    if ($Last) { $FinalPct = $Last.BackedPct; $FinalGB = $Last.ConsumedGB; $TargetGB = $Last.ConfiguredGB }
    if ($History.Count -gt 0) { $Elapsed = New-TimeSpan -Start $History[0].SampledAt -End $History[-1].SampledAt }

    [PSCustomObject][ordered]@{
        VM         = $VMName
        Result     = $Result
        BackedPct  = $FinalPct
        ConsumedGB = $FinalGB
        TargetGB   = $TargetGB
        Samples    = $History.Count
        Elapsed    = $Elapsed
        History    = $History
    }
}


function Invoke-EsxiSsh {
    # --------------------------------------------------------------------------
    # ESXi 에 명령 하나를 보내고 표준출력을 문자열 배열로 돌려준다.
    #   Credential 이 있으면 Posh-SSH(Invoke-SSHCommand), 없으면 ssh.exe + 키.
    #   실패하면 $null 을 돌려주고 Write-Error 로 이유를 남긴다.
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [string]$SshHost,
        [Parameter(Mandatory=$true)]  [string]$Command,
        [Parameter(Mandatory=$false)] [string]$User = "root",
        [Parameter(Mandatory=$false)] [string]$KeyPath = "",
        [Parameter(Mandatory=$false)] [PSCredential]$Credential = $null
    )
    if ($Credential) {
        if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { Write-Error "Posh-SSH 모듈이 없습니다. Install-Module Posh-SSH 하거나 -EsxiSshKey 로 ssh.exe 방식을 쓰십시오."; return $null }
        Import-Module Posh-SSH -ErrorAction Stop
        $S = $null
        try {
            $S = New-SSHSession -ComputerName $SshHost -Credential $Credential -AcceptKey -ErrorAction Stop
            $R = Invoke-SSHCommand -SessionId $S.SessionId -Command $Command -TimeOut 60 -ErrorAction Stop
            return @($R.Output)
        }
        catch { Write-Error "SSH($SshHost) 실패: $($_.Exception.Message)"; return $null }
        finally { if ($S) { Remove-SSHSession -SessionId $S.SessionId -ErrorAction SilentlyContinue | Out-Null } }
    }
    $Ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $Ssh) { Write-Error "ssh.exe 를 찾지 못했습니다 (Windows OpenSSH 클라이언트). -EsxiSshCredential 로 Posh-SSH 방식을 쓰십시오."; return $null }
    $SshCmdArgs = @("-o","BatchMode=yes","-o","StrictHostKeyChecking=accept-new","-o","ConnectTimeout=15")
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) { $SshCmdArgs += @("-i", $KeyPath) }
    $SshCmdArgs += @("$User@$SshHost", $Command)
    $Out = & $Ssh.Source @SshCmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSH($User@$SshHost) 실패 (exit $LASTEXITCODE): $(($Out | Out-String).Trim()). 키 인증(-EsxiSshKey)이 안 돼 있으면 ESXi 의 /etc/ssh/keys-root/authorized_keys 에 공개키를 넣거나 -EsxiSshCredential 을 쓰십시오."
        return $null
    }
    return @($Out | ForEach-Object { "$_" })
}


function Get-VmLpageStatus {
    # --------------------------------------------------------------------------
    # 켜진 VM 의 1GB 페이지 백킹 상태를 vsish 로 읽는다.
    #   esxcli vm process list 로 VM 이름 -> World ID / VMX Cartel ID 를 얻고,
    #   /memory/lpage/vmLpage/ 아래에 있는 ID 를 골라 그 노드를 읽는다.
    #   목표 1GB 수 = 구성 메모리 MB / 1024 (내림). 구성 메모리는 vCenter 에서 읽는다.
    # 반환 : VM 별 객체 (VM · WorldId · MemGB · Backed1GB · Target1GB · Pct · Failed · Raw)
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [string]$VMHostName,
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false)] [string]$EsxiSshHost = "",
        [Parameter(Mandatory=$false)] [string]$EsxiSshUser = "root",
        [Parameter(Mandatory=$false)] [string]$EsxiSshKey = "",
        [Parameter(Mandatory=$false)] [PSCredential]$EsxiSshCredential = $null,
        [Parameter(Mandatory=$false)] [switch]$Quiet
    )
    $SshHost = if ([string]::IsNullOrWhiteSpace($EsxiSshHost)) { $VMHostName } else { $EsxiSshHost }
    $SshArgs = @{ SshHost = $SshHost; User = $EsxiSshUser; KeyPath = $EsxiSshKey }
    if ($EsxiSshCredential) { $SshArgs.Credential = $EsxiSshCredential }

    # 1) 이름 -> World ID / Cartel ID, 그리고 vmLpage 아래 존재하는 ID 목록 — SSH 1회
    $Cmd = "esxcli vm process list; echo __LPAGE_IDS__; vsish -e ls /memory/lpage/vmLpage/ 2>/dev/null"
    $Out = Invoke-EsxiSsh @SshArgs -Command $Cmd
    if ($null -eq $Out) { return $null }
    $Map = @{}; $Ids = @{}; $W = ""; $C = ""; $InIds = $false
    foreach ($Line in $Out) {
        if ($Line -match '^__LPAGE_IDS__') { $InIds = $true; continue }
        if ($InIds) { if ($Line -match '^\s*(\d+)/?\s*$') { $Ids["$($Matches[1])"] = $true }; continue }
        if ($Line -match '^\s*World ID:\s*(\d+)')        { $W = $Matches[1]; continue }
        if ($Line -match '^\s*VMX Cartel ID:\s*(\d+)')   { $C = $Matches[1]; continue }
        if ($Line -match '^\s*Display Name:\s*(.+?)\s*$') { $Map[$Matches[1]] = @{ World = $W; Cartel = $C }; $W = ""; $C = ""; continue }
    }
    if ($Map.Count -eq 0) { Write-Warning "$SshHost : esxcli vm process list 에 켜진 VM 이 없습니다."; return @() }

    $TargetHost = Get-VMHost -Name $VMHostName -ErrorAction Stop | Select-Object -First 1
    $Names = @($Map.Keys | Sort-Object)
    if ($VMName.Count -gt 0) { $Names = @($Names | Where-Object { $n = $_; ($VMName | Where-Object { $n -like $_ }).Count -gt 0 }) }

    $Rows = @()
    foreach ($N in $Names) {
        $Id = ""
        foreach ($Cand in @($Map[$N].World, $Map[$N].Cartel)) { if ($Cand -and $Ids.ContainsKey($Cand)) { $Id = $Cand; break } }
        if (-not $Id -and $Ids.Count -eq 0) { $Id = $Map[$N].World }   # ls 가 비었으면 World ID 로 시도
        $MemMB = 0
        $Vm = Get-VM -Name $N -Location $TargetHost -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Vm) { $MemMB = [double]$Vm.ExtensionData.Config.Hardware.MemoryMB }
        $Target = [int][math]::Floor($MemMB / 1024)
        $Backed = $null; $Failed = $null; $Raw = ""
        if ($Id) {
            $Vs = Invoke-EsxiSsh @SshArgs -Command "vsish -e get /memory/lpage/vmLpage/$Id"
            if ($Vs) {
                $Raw = ($Vs -join "`n")
                if ($Raw -match '(?i)Current number of 1GB page backings\s*:\s*(\d+)') { $Backed = [int]$Matches[1] }
                if ($Raw -match '(?i)1GB page backing attempts failed\s*:\s*(\d+)')   { $Failed = [int]$Matches[1] }
            }
        }
        $Rows += [PSCustomObject][ordered]@{
            VM = $N; WorldId = $Id; MemGB = [math]::Round($MemMB/1024, 0)
            Backed1GB = $Backed; Target1GB = $Target
            Pct = $(if ($null -ne $Backed -and $Target -gt 0) { [math]::Round(100.0 * $Backed / $Target, 1) } else { $null })
            Failed = $Failed
            Note = $(if (-not $Id) { "vmLpage 노드 없음" } elseif ($null -eq $Backed) { "필드 파싱 실패 — Raw 확인" } else { "" })
            Raw = $Raw
        }
    }
    if (-not $Quiet) {
        Write-Host "`n[1GB 페이지 백킹 — $SshHost · vsish /memory/lpage/vmLpage/<worldID>]" -ForegroundColor Green
        $Rows | Select-Object VM, WorldId, MemGB, Backed1GB, Target1GB, Pct, Failed, Note | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
    return $Rows
}


function Wait-VmLpageComplete {
    # --------------------------------------------------------------------------
    # VM 하나의 1GB 백킹 수가 목표에 닿을 때까지 vsish 를 반복해 읽는다.
    #   완료 : Backed1GB >= Target1GB × CompletePercent/100
    #   실패 : StallSamples 회 연속 늘지 않고 Failed > 0  -> LpageFailed
    #   정체 : StallSamples 회 연속 늘지 않는데 Failed = 0 -> Stalled
    # 반환 : Result(Completed|LpageFailed|Stalled|Timeout|NoNode) + 마지막 값 + 이력
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [string]$VMName,
        [Parameter(Mandatory=$true)]  [string]$VMHostName,
        [Parameter(Mandatory=$false)] [hashtable]$SshOpts = @{},
        [Parameter(Mandatory=$false)] [double]$CompletePercent = 100.0,
        [Parameter(Mandatory=$false)] [int]$PollSeconds = 15,
        [Parameter(Mandatory=$false)] [int]$StallSamples = 6,
        [Parameter(Mandatory=$false)] [int]$TimeoutMinutes = 90,
        [Parameter(Mandatory=$false)] [switch]$ShowProgress
    )
    $Start = Get-Date; $Deadline = $Start.AddMinutes($TimeoutMinutes)
    $Result = "Timeout"; $Prev = -1; $Stall = 0; $Last = $null; $History = @()
    while ((Get-Date) -lt $Deadline) {
        $Rows = Get-VmLpageStatus -VMHostName $VMHostName -VMName @($VMName) -Quiet @SshOpts
        if ($null -eq $Rows) { Write-Error "SSH 조회 실패. Lpage 대기를 중단합니다."; return $null }
        $Last = @($Rows | Where-Object { $_.VM -eq $VMName }) | Select-Object -First 1
        if (-not $Last) {
            # 방금 켠 VM 은 esxcli 목록에 몇 초 뒤에 나타난다 — 처음 1분은 기다린다
            if (((Get-Date) - $Start).TotalSeconds -gt 60) { $Result = "NoNode"; break }
            Start-Sleep -Seconds 5; continue
        }
        if (-not $Last.WorldId -or $null -eq $Last.Backed1GB) {
            if (((Get-Date) - $Start).TotalSeconds -gt 120) { $Result = "NoNode"; break }
            Start-Sleep -Seconds $PollSeconds; continue
        }
        $History += [PSCustomObject]@{ SampledAt = Get-Date; VM = $VMName; Backed1GB = $Last.Backed1GB; Target1GB = $Last.Target1GB; Failed = $Last.Failed }
        if ($ShowProgress) {
            Write-Host ("    {0}  1GB {1,5} / {2,5}  ({3,6:N1}%)  failed {4}" -f (Get-Date -Format "HH:mm:ss"), $Last.Backed1GB, $Last.Target1GB, $Last.Pct, $Last.Failed) -ForegroundColor DarkGray
        }
        $Goal = [math]::Ceiling($Last.Target1GB * $CompletePercent / 100.0)
        if ($Last.Backed1GB -ge $Goal) { $Result = "Completed"; break }
        if ($Prev -ge 0 -and $Last.Backed1GB -le $Prev) { $Stall++ } else { $Stall = 0 }
        if ($Stall -ge $StallSamples) { $Result = $(if ($Last.Failed -gt 0) { "LpageFailed" } else { "Stalled" }); break }
        $Prev = $Last.Backed1GB
        Start-Sleep -Seconds $PollSeconds
    }
    [PSCustomObject][ordered]@{
        VM = $VMName; Result = $Result
        Backed1GB = $(if ($Last) { $Last.Backed1GB } else { $null })
        Target1GB = $(if ($Last) { $Last.Target1GB } else { $null })
        Pct       = $(if ($Last) { $Last.Pct } else { $null })
        Failed    = $(if ($Last) { $Last.Failed } else { $null })
        Raw       = $(if ($Last) { $Last.Raw } else { "" })
        Elapsed   = ((Get-Date) - $Start)
        History   = $History
    }
}


function Wait-VmToolsReady {
    # --------------------------------------------------------------------------
    # VM 하나의 게스트 부팅이 끝났는지 기다린다.
    #   완료 조건 : 전원 poweredOn 이고 VMware Tools 실행 상태(Guest.ToolsRunningStatus)
    #               가 guestToolsRunning 이며 Guest.GuestState 가 running.
    #   NoTools   : Guest.ToolsStatus 가 toolsNotInstalled 이면 판정 불가로 즉시 반환.
    # 반환 : Result(Completed|NoTools|Timeout|PoweredOff) + 마지막 상태 + 경과
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [string]$VMName,
        [Parameter(Mandatory=$false)] [string]$VMHostName = "",
        [Parameter(Mandatory=$false)] [int]$PollSeconds = 10,
        [Parameter(Mandatory=$false)] [int]$TimeoutMinutes = 20,
        [Parameter(Mandatory=$false)] [switch]$ShowProgress
    )
    $Start    = Get-Date
    $Deadline = $Start.AddMinutes($TimeoutMinutes)
    $Result   = "Timeout"
    $Tools    = ""; $GState = ""; $Power = ""
    while ((Get-Date) -lt $Deadline) {
        $Vm = if ([string]::IsNullOrWhiteSpace($VMHostName)) {
                  Get-VM -Name $VMName -ErrorAction SilentlyContinue
              } else {
                  Get-VM -Name $VMName -Location (Get-VMHost -Name $VMHostName) -ErrorAction SilentlyContinue
              }
        $Vm = $Vm | Select-Object -First 1
        if (-not $Vm) { Write-Error "VM '$VMName' 조회 실패. Tools 대기를 중단합니다."; return $null }
        $G      = $Vm.ExtensionData.Guest
        $Power  = "$($Vm.ExtensionData.Runtime.PowerState)"
        $Tools  = "$($G.ToolsRunningStatus)"
        $GState = "$($G.GuestState)"
        $TStat  = "$($G.ToolsStatus)"
        if ($ShowProgress) {
            Write-Host ("    {0}  {1,-11}  tools={2,-22} guest={3}" -f (Get-Date -Format "HH:mm:ss"), $Power, $Tools, $GState) -ForegroundColor DarkGray
        }
        if ($Power -ne "poweredOn") {
            if (((Get-Date) - $Start).TotalSeconds -gt 60) { $Result = "PoweredOff"; break }
        }
        elseif ($Tools -eq "guestToolsRunning" -and $GState -eq "running") { $Result = "Completed"; break }
        elseif ($TStat -eq "toolsNotInstalled") { $Result = "NoTools"; break }
        Start-Sleep -Seconds $PollSeconds
    }
    [PSCustomObject][ordered]@{
        VM = $VMName; Result = $Result; PowerState = $Power; Tools = $Tools; GuestState = $GState
        Elapsed = ((Get-Date) - $Start)
    }
}


function Start-VmsWithBackingGate {
    # --------------------------------------------------------------------------
    # 지정 호스트에서 VM 을 준 순서대로 하나씩 켠다. 앞 VM 의 백킹이 다
    # 올라오기 전에는 다음 VM 을 켜지 않는다.
    # --------------------------------------------------------------------------
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
    param (
        [Parameter(Mandatory=$true,  HelpMessage="대상 ESXi 호스트 이름")]        [string]$VMHostName,
        [Parameter(Mandatory=$false, HelpMessage="켤 VM 이름 — 적은 순서대로 켠다. 생략하면 -All 필요")] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false, HelpMessage="호스트의 VM 전부를 이름순으로 켠다")] [switch]$All,
        [Parameter(Mandatory=$false, HelpMessage="-All 일 때 이름 와일드카드 (기본 *)")] [string]$NamePattern = "*",
        [Parameter(Mandatory=$false, HelpMessage="-All 일 때 제외할 이름 와일드카드 목록")] [string[]]$Exclude = @(),
        [Parameter(Mandatory=$false, HelpMessage="다음 VM 으로 넘어가는 기준 (목록, 순서대로): Lpage|Backing|Tools|Power")] [ValidateSet("Lpage","Backing","Tools","Power")] [string[]]$Gate = @("Lpage"),
        [Parameter(Mandatory=$false, HelpMessage="Tools 게이트 최대 대기 (분)")] [int]$ToolsTimeoutMinutes = 20,
        [Parameter(Mandatory=$false, HelpMessage="Lpage 게이트 완료 비율 (목표 1GB 수 대비 %)")] [double]$LpageCompletePercent = 100.0,
        [Parameter(Mandatory=$false, HelpMessage="Lpage 게이트 정체 판정 연속 표본 수")] [int]$LpageStallSamples = 6,
        [Parameter(Mandatory=$false, HelpMessage="ESXi SSH 접속 주소 (기본 = VMHostName)")] [string]$EsxiSshHost = "",
        [Parameter(Mandatory=$false, HelpMessage="ESXi SSH 사용자")] [string]$EsxiSshUser = "root",
        [Parameter(Mandatory=$false, HelpMessage="ssh.exe 키 인증용 개인키 경로")] [string]$EsxiSshKey = "",
        [Parameter(Mandatory=$false, HelpMessage="Posh-SSH 비밀번호 인증용 자격증명")] [PSCredential]$EsxiSshCredential = $null,

        [Parameter(Mandatory=$false, HelpMessage="완료로 볼 백킹 비율 (%)")]      [double]$CompletePercent = 99.0,
        [Parameter(Mandatory=$false, HelpMessage="폴링 간격 (초)")]               [int]$PollSeconds = 20,
        [Parameter(Mandatory=$false, HelpMessage="완료 판정에 필요한 연속 표본 수 (100% 미만일 때만)")] [int]$StableSamples = 2,
        [Parameter(Mandatory=$false, HelpMessage="100% 이상이어도 안정 표본을 기다리는 예전 동작")] [switch]$NoFastComplete,
        [Parameter(Mandatory=$false, HelpMessage="정체로 볼 연속 표본 수")]       [int]$StallSamples = 15,
        [Parameter(Mandatory=$false, HelpMessage="VM 하나당 최대 대기 시간 (분)")] [int]$TimeoutMinutes = 90,

        [Parameter(Mandatory=$false, HelpMessage="1GB 백킹 키가 TRUE 가 아니면 켜지 않고 중단")] [switch]$Require1GPage,
        [Parameter(Mandatory=$false, HelpMessage="앞 VM 이 완료되지 않아도 다음 VM 을 계속 켠다")] [switch]$ContinueOnIncomplete,
        [Parameter(Mandatory=$false, HelpMessage="폴링 로그를 CSV 로 저장할 경로")] [string]$LogCsv = "",
        [Parameter(Mandatory=$false, HelpMessage="호스트에서 돌릴 페이지 크기 확인 셸 스크립트를 이 경로에 생성")] [string]$EmitHostCheckScript = ""
    )

    # ==========================================================================
    # 1. 호스트·VM 확인 — 켜기 전에 전부 확인하고, 하나라도 이상하면 안 켠다
    # ==========================================================================
    $TargetHost = Get-VMHost -Name $VMHostName -ErrorAction Stop | Select-Object -First 1
    if ($TargetHost.ConnectionState -ne "Connected") {
        Write-Error "호스트 '$VMHostName' 이(가) Connected 상태가 아닙니다. 현재: $($TargetHost.ConnectionState)"
        return
    }

    $HostTotalGB = [math]::Round($TargetHost.MemoryTotalGB, 1)
    $HostUsedGB  = [math]::Round($TargetHost.MemoryUsageGB, 1)
    Write-Host "`n[호스트] $($TargetHost.Name) — 메모리 $HostUsedGB / $HostTotalGB GB 사용 중 (여유 $([math]::Round($HostTotalGB - $HostUsedGB,1)) GB)" -ForegroundColor Cyan

    $Names = @($VMName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Names.Count -eq 0) {
        if (-not $All) { Write-Error "켤 VM 을 -VMName 으로 주거나, 호스트 전체를 켜려면 -All 을 지정하십시오."; return }
        $HostVms = @(Get-VM -Location $TargetHost -ErrorAction Stop | Where-Object { $_.Name -like $NamePattern })
        foreach ($Pat in $Exclude) { $HostVms = @($HostVms | Where-Object { $_.Name -notlike $Pat }) }
        $Names = @($HostVms | Sort-Object Name | ForEach-Object { $_.Name })
        if ($Names.Count -eq 0) { Write-Error "호스트 '$VMHostName' 에서 조건(-NamePattern '$NamePattern', -Exclude $($Exclude -join ','))에 맞는 VM 이 없습니다."; return }
        Write-Host "`n[대상] -All — 호스트의 VM $($Names.Count) 대를 이름순으로 켭니다: $($Names -join ' -> ')" -ForegroundColor Cyan
    }
    $GateDesc = @{ Lpage = "1GB 페이지 백킹 수 = 구성 메모리 GB (vsish)"; Backing = "호스트 메모리 점유량 (오버헤드 포함)"; Tools = "게스트 부팅 완료(VMware Tools 실행)"; Power = "전원 poweredOn 만 확인" }
    Write-Host "[게이트] $($Gate -join ' -> ') — $(($Gate | ForEach-Object { $GateDesc[$_] }) -join ' 뒤 ') 후 다음 VM" -ForegroundColor Cyan
    $SshOpts = @{ EsxiSshHost = $EsxiSshHost; EsxiSshUser = $EsxiSshUser; EsxiSshKey = $EsxiSshKey }
    if ($EsxiSshCredential) { $SshOpts.EsxiSshCredential = $EsxiSshCredential }
    if ($Gate -contains "Lpage") {
        $ProbeArgs = @{ SshHost = $(if ($EsxiSshHost) { $EsxiSshHost } else { $VMHostName }); User = $EsxiSshUser; KeyPath = $EsxiSshKey }
        if ($EsxiSshCredential) { $ProbeArgs.Credential = $EsxiSshCredential }
        $Probe = Invoke-EsxiSsh @ProbeArgs -Command "vsish -e ls /memory/lpage/ 2>&1 | head -5"
        if ($null -eq $Probe) { Write-Error "Lpage 게이트는 ESXi SSH 가 필요합니다. 접속을 확인하거나 -Gate Backing 으로 바꾸십시오."; return }
        Write-Host "[SSH] $($EsxiSshUser)@$(if ($EsxiSshHost) { $EsxiSshHost } else { $VMHostName }) 접속 확인 — /memory/lpage/ : $(($Probe -join ' ').Trim())" -ForegroundColor DarkGray
    }

    $Plan = @()
    foreach ($Name in $Names) {
        $Vm = Get-VM -Name $Name -Location $TargetHost -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Vm) { Write-Error "VM '$Name' 을(를) 호스트 '$VMHostName' 에서 찾지 못했습니다. 중단합니다."; return }
        $Plan += (Get-VmBackingStatus -VMName $Name -VMHostName $VMHostName)
    }

    Write-Host "`n[사전 확인] 백킹 설정 — 기술교재 37.2 차단 세트" -ForegroundColor Yellow
    $Plan | Select-Object VM, PowerState, ConfiguredGB, Reserved100, Pin, Prealloc, VmxSwap, Lpage1GB |
            Format-Table -AutoSize | Out-Host

    $NeedGB = ($Plan | Where-Object { $_.PowerState -ne "poweredOn" } | Measure-Object -Property ConfiguredGB -Sum).Sum
    if ($null -eq $NeedGB) { $NeedGB = 0 }
    Write-Host ("이번에 새로 붙일 메모리 합계 약 {0:N1} GB · 호스트 여유 {1:N1} GB" -f $NeedGB, ($HostTotalGB - $HostUsedGB)) -ForegroundColor DarkGray
    if ($NeedGB -gt ($HostTotalGB - $HostUsedGB)) {
        Write-Warning "요구량이 호스트 여유 메모리를 넘습니다. 뒤쪽 VM 의 백킹이 끝까지 안 올라올 수 있습니다."
    }

    $NoLpage = @($Plan | Where-Object { $_.Lpage1GB -notmatch '^(TRUE|true|1)$' })
    if ($NoLpage.Count -gt 0) {
        $Msg = "sched.mem.lpage.enable1GPage 가 TRUE 가 아닌 VM: " + (($NoLpage | ForEach-Object { "$($_.VM)=$($_.Lpage1GB)" }) -join ", ")
        if ($Require1GPage) { Write-Error "$Msg — -Require1GPage 지정으로 중단합니다."; return }
        Write-Warning "$Msg — 그대로 진행합니다(끄고 켜는 대조 실험이면 정상)."
    }

    # ==========================================================================
    # 2. 순차 기동 — 앞 VM 의 백킹이 다 올라온 뒤에 다음 VM 을 켠다
    # ==========================================================================
    $Summary   = @()
    $AllPolls  = @()

    foreach ($Row in $Plan) {
        $Name = $Row.VM
        Write-Host "`n────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "[$Name] 구성 메모리 $($Row.ConfiguredGB) GB · 현재 $($Row.PowerState)" -ForegroundColor Cyan

        if ($Row.PowerState -eq "poweredOn") {
            Write-Host "  이미 켜져 있습니다. 켜지 않고 백킹만 확인합니다." -ForegroundColor DarkGray
        }
        else {
            if (-not $PSCmdlet.ShouldProcess($Name, "전원 켜기")) {
                $Summary += [PSCustomObject][ordered]@{ VM=$Name; Result="Skipped(WhatIf)"; Backed1GB=$null; LpageFailed=$null; BackedPct=$null; ConsumedGB=$null; TargetGB=$Row.ConfiguredGB; Tools=$null; Elapsed=$null }
                continue
            }
            Write-Host "  전원을 켭니다..." -ForegroundColor Yellow
            try { Start-VM -VM (Get-VM -Name $Name -Location $TargetHost) -Confirm:$false -ErrorAction Stop | Out-Null }
            catch {
                Write-Error "VM '$Name' 전원 켜기 실패: $($_.Exception.Message)"
                $Summary += [PSCustomObject][ordered]@{ VM=$Name; Result="StartFailed"; Backed1GB=$null; LpageFailed=$null; BackedPct=$null; ConsumedGB=$null; TargetGB=$Row.ConfiguredGB; Tools=$null; Elapsed=$null }
                if (-not $ContinueOnIncomplete) { break } else { continue }
            }
        }

        $GateRes = "Completed"; $Wait = $null; $ToolsWait = $null; $LpWait = $null
        $ElapsedText = $null

        foreach ($G in $Gate) {
            if ($GateRes -ne "Completed") { break }
            switch ($G) {
                "Power" {
                    $Pw = "$((Get-VM -Name $Name -Location $TargetHost).ExtensionData.Runtime.PowerState)"
                    $GateRes = if ($Pw -eq "poweredOn") { "Completed" } else { "PoweredOff" }
                    Write-Host "  전원 상태 확인: $Pw" -ForegroundColor DarkGray
                }
                "Lpage" {
                    Write-Host "  1GB 페이지 백킹이 구성 메모리 GB 수에 닿을 때까지 기다립니다 (vsish · $PollSeconds 초 간격 · 최대 $TimeoutMinutes 분 · 목표 $LpageCompletePercent%)" -ForegroundColor Yellow
                    $LpWait = Wait-VmLpageComplete -VMName $Name -VMHostName $VMHostName -SshOpts $SshOpts `
                                  -CompletePercent $LpageCompletePercent -PollSeconds $PollSeconds `
                                  -StallSamples $LpageStallSamples -TimeoutMinutes $TimeoutMinutes -ShowProgress
                    if (-not $LpWait) { $GateRes = "QueryFailed"; break }
                    if ($LpWait.Elapsed) { $ElapsedText = "{0:hh\:mm\:ss}" -f $LpWait.Elapsed }
                    switch ($LpWait.Result) {
                        "Completed"   { Write-Host "  [1GB 백킹 완료] $($LpWait.Backed1GB) / $($LpWait.Target1GB) 개 ($($LpWait.Pct)%) · failed $($LpWait.Failed)" -ForegroundColor Green }
                        "LpageFailed" { Write-Warning "  [1GB 백킹 실패] $($LpWait.Backed1GB) / $($LpWait.Target1GB) 개 ($($LpWait.Pct)%) 에서 멈췄고 attempts failed = $($LpWait.Failed). 호스트에 연속 1GB 영역이 부족한 상태 — 다른 VM 을 먼저 끄거나 호스트를 재부팅해 조각을 정리한 뒤 다시 켜야 합니다." }
                        "Stalled"     { Write-Warning "  [정체] $($LpWait.Backed1GB) / $($LpWait.Target1GB) 개에서 늘지 않는데 failed 는 0 — prealloc 설정과 VM 전원 상태를 확인하십시오." }
                        "Timeout"     { Write-Warning "  [시간초과] $TimeoutMinutes 분 안에 목표에 닿지 못했습니다 (현재 $($LpWait.Backed1GB) / $($LpWait.Target1GB))." }
                        "NoNode"      { Write-Warning "  [노드 없음] /memory/lpage/vmLpage/ 에서 이 VM 의 worldID 를 찾지 못했거나 필드를 읽지 못했습니다. -Gate Backing 으로 돌리고 원문(Raw)을 확인하십시오." }
                    }
                    $GateRes = $LpWait.Result
                }
                "Backing" {
                    Write-Host "  호스트 메모리 점유가 다 올라올 때까지 기다립니다 (목표 $CompletePercent% · $PollSeconds 초 간격 · 최대 $TimeoutMinutes 분 · 100% 이상이면 즉시 완료 · 1GB 여부는 판정하지 않음)" -ForegroundColor Yellow
                    $Wait = Wait-VmBackingComplete -VMName $Name -VMHostName $VMHostName `
                                -CompletePercent $CompletePercent -PollSeconds $PollSeconds `
                                -StableSamples $StableSamples -StallSamples $StallSamples `
                                -TimeoutMinutes $TimeoutMinutes -NoFastComplete:$NoFastComplete -ShowProgress
                    if (-not $Wait) { $GateRes = "QueryFailed"; break }
                    $AllPolls += $Wait.History
                    if (-not $ElapsedText -and $Wait.Elapsed) { $ElapsedText = "{0:hh\:mm\:ss}" -f $Wait.Elapsed }
                    switch ($Wait.Result) {
                        "Completed" { Write-Host "  [점유 완료] $($Wait.ConsumedGB) / $($Wait.TargetGB) GB ($($Wait.BackedPct)%)" -ForegroundColor Green }
                        "Stalled"   { Write-Warning "  [정체] $($Wait.BackedPct)% 에서 더 늘지 않습니다. 호스트 여유 메모리와 예약 설정을 확인하십시오." }
                        "Timeout"   { Write-Warning "  [시간초과] $TimeoutMinutes 분 안에 $CompletePercent% 에 도달하지 못했습니다 (현재 $($Wait.BackedPct)%)." }
                        "PoweredOff"{ Write-Warning "  [꺼짐] 대기 중 VM 이 꺼졌습니다." }
                    }
                    $GateRes = $Wait.Result
                }
                "Tools" {
                    Write-Host "  게스트 부팅 완료(VMware Tools 실행)를 기다립니다 (10 초 간격 · 최대 $ToolsTimeoutMinutes 분)" -ForegroundColor Yellow
                    $ToolsWait = Wait-VmToolsReady -VMName $Name -VMHostName $VMHostName -PollSeconds 10 -TimeoutMinutes $ToolsTimeoutMinutes -ShowProgress
                    if (-not $ToolsWait) { $GateRes = "QueryFailed"; break }
                    if (-not $ElapsedText) { $ElapsedText = "{0:hh\:mm\:ss}" -f $ToolsWait.Elapsed }
                    switch ($ToolsWait.Result) {
                        "Completed"  { Write-Host "  [부팅 완료] tools=$($ToolsWait.Tools) guest=$($ToolsWait.GuestState)" -ForegroundColor Green }
                        "NoTools"    { Write-Warning "  [Tools 없음] 이 VM 은 VMware Tools 가 없어 부팅 완료를 판정할 수 없습니다. 전원 상태만으로 다음으로 넘어갑니다." }
                        "Timeout"    { Write-Warning "  [시간초과] $ToolsTimeoutMinutes 분 안에 Tools 가 실행되지 않았습니다 (tools=$($ToolsWait.Tools) guest=$($ToolsWait.GuestState))." }
                        "PoweredOff" { Write-Warning "  [꺼짐] 대기 중 VM 이 꺼졌습니다." }
                    }
                    if ($ToolsWait.Result -ne "Completed" -and $ToolsWait.Result -ne "NoTools") { $GateRes = "Tools" + $ToolsWait.Result }
                }
            }
        }

        $Summary += [PSCustomObject][ordered]@{
            VM=$Name; Result=$GateRes
            Backed1GB=$(if ($LpWait) { "$($LpWait.Backed1GB)/$($LpWait.Target1GB)" } else { $null })
            LpageFailed=$(if ($LpWait) { $LpWait.Failed } else { $null })
            BackedPct=$(if ($Wait) { $Wait.BackedPct } else { $null })
            ConsumedGB=$(if ($Wait) { $Wait.ConsumedGB } else { $null })
            TargetGB=$(if ($Wait) { $Wait.TargetGB } else { $Row.ConfiguredGB })
            Tools=$(if ($ToolsWait) { $ToolsWait.Result } else { $null })
            Elapsed=$ElapsedText
        }

        if ($GateRes -eq "Completed") {
            Write-Host "  [완료] 다음 VM 으로 갑니다." -ForegroundColor Green
        }
        elseif (-not $ContinueOnIncomplete) {
            Write-Warning "다음 VM 을 켜지 않고 멈춥니다. (-ContinueOnIncomplete 를 주면 계속 진행합니다)"
            break
        }
    }

    # ==========================================================================
    # 3. 결과
    # ==========================================================================
    Write-Host "`n[결과]" -ForegroundColor Green
    $Summary | Format-Table -AutoSize | Out-Host

    if (-not [string]::IsNullOrWhiteSpace($LogCsv) -and $AllPolls.Count -gt 0) {
        $AllPolls | Select-Object SampledAt, VM, VMHost, PowerState, ConfiguredGB, ConsumedGB, OverheadGB, BackedPct, Lpage1GB, Prealloc, Pin, VmxSwap |
                    Export-Csv -Path $LogCsv -NoTypeInformation -Encoding UTF8
        Write-Host "폴링 로그 $($AllPolls.Count) 행을 저장했습니다: $LogCsv" -ForegroundColor DarkGray
    }

    if (-not [string]::IsNullOrWhiteSpace($EmitHostCheckScript)) {
        New-EsxiBackingCheckScript -Path $EmitHostCheckScript -VMName ($Plan | ForEach-Object { $_.VM })
    }

    return $Summary
}


function New-EsxiBackingCheckScript {
    # --------------------------------------------------------------------------
    # 호스트(ESXi 셸)에서 돌릴 확인 스크립트를 만든다.
    # vCenter API 로는 페이지 크기를 볼 수 없어서, 그 부분만 호스트에 넘긴다.
    # 출력은 가공하지 않는다 — 원문을 그대로 남기고 판독은 사람이 한다.
    #
    # 본문은 리터럴 here-string(@'...'@) 이다. 셸의 $ 가 PowerShell 에서 먼저
    # 해석되면 안 되므로 보간을 아예 끄고, VM 목록만 자리표시자로 바꿔 넣는다.
    # 저장은 BOM 없는 UTF-8 · LF 줄바꿈으로 한다 (ESXi 의 sh 는 CR 을 못 읽는다).
    # --------------------------------------------------------------------------
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)] [string]$Path,
        [Parameter(Mandatory=$true)] [string[]]$VMName
    )

    # VM 이름은 한 줄에 하나씩 넣는다. 셸에서 따옴표째 단어분리되는 것을 막으려고
    # for 루프 대신 heredoc + read 로 읽는다 (이름에 공백이 있어도 안전).
    $VmList = ($VMName) -join "`n"

    $Body = @'
#!/bin/sh
# ESXi 호스트에서 실행 — VM 메모리가 어떤 페이지로 백킹되는지 확인한다.
# 생성: StartVmsWithBackingGate_v1_0.ps1 (TrackA)
# 사용: sh esxi_backing_check.sh > backing_$(hostname)_$(date +%Y%m%d_%H%M%S).txt 2>&1
#
# 주의 — 아래 vsish / memstats 출력에서 "1GB 페이지" 에 해당하는 필드가 무엇인지는
#        이 호스트 빌드에서 한 번 눈으로 확인하고 고정할 것. 확인 전까지는
#        어느 한 숫자를 뽑아 쓰지 말고 원문 전체를 증거로 남긴다.

echo "=== 0. 호스트 / 빌드 ==="
hostname
vmware -vl

echo
echo "=== 1. 호스트 대형 페이지 관련 고급 설정 ==="
esxcli system settings advanced list -o /LPage/LPageAlwaysTryForNPT
esxcli system settings advanced list -o /Mem/AllocGuestLargePage

echo
echo "=== 2. VM 별 world / 메모리 ==="
esxcli vm process list
memstats -r vm-stats -u mb
memstats -r group-stats -u mb

echo
echo "=== 3. 호스트 메모리 종합 (vsish) ==="
vsish -e get /memory/comprehensive

echo
echo "=== 4. 대형 페이지 관련 vsish 노드 탐색 ==="
# 이 호스트 빌드에 lpage 관련 노드가 어떤 이름으로 있는지 모른다.
# 그래서 노드 트리를 훑어서 이름으로 찾고, 찾은 것만 값을 읽는다.
# 한 번 찾아 이름을 확정한 뒤에는 이 절을 그 노드 직접 get 으로 바꿀 것.

# vsish 의 ls 는 디렉터리를 슬래시로 끝내고 잎 노드는 그냥 이름으로 준다.
walk() {
  base=$1
  depth=$2
  [ "$depth" -le 0 ] && return
  for e in $(vsish -e ls "$base" 2>/dev/null); do
    case "$e" in
      */) walk "$base$e" $((depth - 1)) ;;
       *) echo "$base$e" ;;
    esac
  done
}

echo "--- 4a. /memory/ 잎 노드 전체 ---"
walk /memory/ 3 | tee /tmp/vsish_memory_nodes.txt

echo
echo "--- 4b. 이름에 lpage / large / 1g / huge 가 들어간 노드 (전 트리) ---"
# /sched/ 와 /vmkModules/ 까지 본다. 깊이 제한이 없으면 끝나지 않는다.
# /sched/groups/ 는 VM·world 마다 그룹이 있어 노드가 많다 — 여기서 1~2분 걸릴 수 있다.
{ walk /memory/ 3; walk /sched/ 4; walk /vmkModules/ 3; } 2>/dev/null \
  | grep -i -E 'lpage|largepage|large_page|1g|hugepage' \
  | tee /tmp/vsish_lpage_nodes.txt

echo
echo "--- 4c. 찾은 노드의 값 ---"
while IFS= read -r n; do
  [ -z "$n" ] && continue
  echo "===== $n ====="
  vsish -e get "$n" 2>&1
done < /tmp/vsish_lpage_nodes.txt

echo
echo "--- 4d. /memory/ 잎 노드 값 전체 (위에서 이름으로 못 걸러진 것 대비) ---"
while IFS= read -r n; do
  [ -z "$n" ] && continue
  echo "===== $n ====="
  vsish -e get "$n" 2>&1
done < /tmp/vsish_memory_nodes.txt

echo
echo "--- 4e. memstats 가 제공하는 리포트 목록 (lpage 관련 리포트가 있는지) ---"
memstats -h 2>&1

echo
echo "=== 5. VM 별 vmx 백킹 키 + vmware.log 기록 ==="
while IFS= read -r v; do
  [ -z "$v" ] && continue
  echo "--- $v ---"
  d=$(vim-cmd vmsvc/getallvms 2>/dev/null | awk -v n="$v" '$2 == n {print $1}')
  if [ -z "$d" ]; then echo "  (vmid 를 찾지 못함)"; continue; fi
  echo "  vmid=$d"
  vim-cmd vmsvc/get.config $d 2>/dev/null | grep -i -E 'lpage|prealloc|sched.mem.pin|vmxSwapEnabled|memoryReservation|memoryMB'
  vmx=$(vim-cmd vmsvc/get.config $d 2>/dev/null | awk -F'"' '/vmPathName/ {print $2}')
  if [ -z "$vmx" ]; then echo "  (vmPathName 을 찾지 못함)"; continue; fi
  ds=$(echo "$vmx" | sed -e 's/^\[//' -e 's/\].*//')
  rel=$(echo "$vmx" | sed -e 's/^\[[^]]*\] *//')
  log="/vmfs/volumes/$ds/$(dirname "$rel")/vmware.log"
  if [ ! -f "$log" ]; then echo "  (vmware.log 없음: $log)"; continue; fi
  echo "  $log"
  grep -i -E '1GB|1G page|large page|lpage|prealloc' "$log" | tail -40
done <<'VMLIST_EOF'
__VMLIST__
VMLIST_EOF
'@

    $Body = $Body.Replace('__VMLIST__', $VmList) -replace "`r`n", "`n"
    if (-not $Body.EndsWith("`n")) { $Body += "`n" }

    $Full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.File]::WriteAllText($Full, $Body, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "호스트 확인 스크립트를 만들었습니다: $Full" -ForegroundColor DarkGray
    Write-Host "  ESXi 로 복사해 'sh $(Split-Path -Leaf $Full)' 로 실행하고, 출력 원문을 증거로 보관하십시오." -ForegroundColor DarkGray
}

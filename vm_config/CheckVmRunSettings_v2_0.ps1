function Get-VmRunSettings {
    # ==========================================================================
    # CheckVmRunSettings  v2.0  (2026-09-23)
    #
    #   v1.0 -> v2.0 : 구조 변경 (사용자 지시 0923)
    #     - 대상을 VM 이름이 아니라 호스트로 지정한다. 여러 개·와일드카드 지원
    #       (-VMHostName lice*, "esx03","esx04"). 그 호스트의 VM 전부를 읽는다.
    #     - 기대값 대조(OK/DIFF)를 없애고, 여러 호스트의 VM 설정을 한눈에 보는
    #       그룹별 표 4개로 출력한다.
    #         [1] VM 스펙 · vCPU 토폴로지  : vCPU · 소켓당 코어 · vNUMA 노드 수 · 메모리 · 전원
    #         [2] CPU Affinity            : sched.vcpuN.affinity / sched.nodeN.affinity 요약
    #                                       + NUMA 토폴로지 키 (numa.vcpu.coresPerNode 등)
    #         [3] 메모리                  : 예약 · 전량 잠금 · 백킹 키 4종(pin/prealloc/vmxSwap/1GPage)
    #                                       · 백킹 용량(호스트 점유 GB · %) · 오버헤드
    #         [4] Share 비율              : CPU/메모리 shares 의 level(normal/high/low/custom) 과 값,
    #                                       같은 호스트 안 최소값 대비 비율, CPU 예약/한도
    #     - CAT(L3 캐시 분할) 설정은 vCenter API 로 읽을 수 없다 (vsish 는 호스트 셸 전용).
    #       표에서 생략하고 안내 한 줄만 낸다. 호스트에서 set_cat_qos 의 STATE DUMP 나
    #       sched-stats -t qos-enforcement 로 본다.
    #
    #   읽기만 한다. 어떤 설정도 바꾸지 않는다.
    #
    #   사용 예
    #     . .\CheckVmRunSettings_v2_0.ps1
    #     Get-VmRunSettings -VMHostName esx03,esx04
    #     Get-VmRunSettings -VMHostName lice* -VMName *ev0*
    #     Get-VmRunSettings -VMHostName esx03 -AffinityDetail          # affinity 키 전체 값까지
    #     $r = Get-VmRunSettings -VMHostName lice* -OutCsv C:\tmp\vmset   # 표 4개를 CSV 4개로 저장
    #     $r.Memory | Where-Object BackingPct -lt 100                     # 반환 객체로 걸러 보기
    # ==========================================================================
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,  HelpMessage="호스트 이름 (여러 개, 와일드카드 가능: lice*)")]
        [string[]]$VMHostName,

        [Parameter(Mandatory=$false, HelpMessage="VM 이름 필터 (와일드카드, 기본 전부)")]
        [string[]]$VMName = @("*"),

        [Parameter(Mandatory=$false, HelpMessage="affinity 키 전체 값을 VM 별로 따로 출력")]
        [switch]$AffinityDetail,

        [Parameter(Mandatory=$false, HelpMessage="표 4개를 <경로>_spec/_affinity/_memory/_shares.csv 로 저장")]
        [string]$OutCsv = ""
    )

    # ---- 호스트 확정 (와일드카드·중복 정리) ------------------------------------
    $Hosts = @()
    foreach ($Pat in $VMHostName) {
        $Found = @(Get-VMHost -Name $Pat -ErrorAction SilentlyContinue)
        if ($Found.Count -eq 0) { Write-Warning "호스트 '$Pat' 에 해당하는 것이 없습니다." }
        $Hosts += $Found
    }
    $Hosts = @($Hosts | Sort-Object Name -Unique)
    if ($Hosts.Count -eq 0) { Write-Error "대상 호스트가 없습니다."; return }
    Write-Host "`n[대상 호스트 $($Hosts.Count)대] $(($Hosts | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Cyan

    $Spec = @(); $Aff = @(); $Mem = @(); $Shr = @(); $AffKeys = @()

    foreach ($H in $Hosts) {
        # 호스트 토폴로지 (참고 표시용)
        $Ci = $H.ExtensionData.Hardware.CpuInfo
        $HSock = [int]$Ci.NumCpuPackages; $HCores = [int]$Ci.NumCpuCores; $HThr = [int]$Ci.NumCpuThreads
        $HNodes = 0
        try { $HNodes = @($H.ExtensionData.Hardware.NumaInfo.NumaNode | Where-Object { $_ -and $_.CpuID }).Count } catch { $HNodes = 0 }
        if ($HNodes -lt 1) { $HNodes = $HSock }
        $HTText = if ($HCores -gt 0 -and ($HThr / $HCores) -gt 1) { "HT On" } else { "HT Off" }
        Write-Host "▶ $($H.Name) : $HSock 소켓 · $HCores 코어 · $HThr pCPU ($HTText) · NUMA 노드 $HNodes · 메모리 $([math]::Round($H.MemoryTotalGB,0)) GB · $($H.ConnectionState)" -ForegroundColor DarkGray

        $Vms = @(Get-VM -Location $H -ErrorAction SilentlyContinue)
        $Vms = @($Vms | Where-Object { $v = $_; ($VMName | Where-Object { $v.Name -like $_ }).Count -gt 0 } | Sort-Object Name)
        if ($Vms.Count -eq 0) { Write-Warning "  $($H.Name): 조건에 맞는 VM 없음"; continue }

        # 호스트 안 CPU shares 최소값 (비율 계산용) — 켜진 VM·꺼진 VM 구분 없이 설정값 기준
        $ShareVals = @()
        foreach ($V in $Vms) { try { $ShareVals += [int]$V.ExtensionData.Config.CpuAllocation.Shares.Shares } catch { } }
        $ShareMin = if ($ShareVals.Count -gt 0) { ($ShareVals | Measure-Object -Minimum).Minimum } else { 0 }

        foreach ($V in $Vms) {
            $Cfg = $V.ExtensionData.Config
            $Qs  = $V.ExtensionData.Summary.QuickStats
            $Adv = @{}
            foreach ($S in @(Get-AdvancedSetting -Entity $V -ErrorAction SilentlyContinue)) { if ($S) { $Adv[$S.Name] = "$($S.Value)" } }
            $Key = { param($k) if ($Adv.ContainsKey($k)) { $Adv[$k] } else { "-" } }

            # [1] 스펙 · 토폴로지
            $NumCpu = [int]$V.NumCpu
            $Cps = 0; try { $Cps = [int]$Cfg.Hardware.NumCoresPerSocket } catch { $Cps = 0 }
            $VNuma = if ($Cps -gt 0) { [int][math]::Ceiling($NumCpu / $Cps) } else { $null }
            $Spec += [PSCustomObject][ordered]@{
                Host = $H.Name; VM = $V.Name; Power = "$($V.PowerState)"
                vCPU = $NumCpu
                CoresPerSocket = $(if ($Cps -gt 0) { $Cps } else { "자동" })
                vNUMA_Nodes = $(if ($VNuma) { $VNuma } else { "자동" })
                MemoryGB = [math]::Round($V.MemoryGB, 0)
                LatencySens = "$($Cfg.LatencySensitivity.Level)"
                GuestOS = "$($Cfg.GuestFullName)"
            }

            # [2] Affinity
            $VcpuK = @($Adv.Keys | Where-Object { $_ -like "sched.vcpu*.affinity" } | Sort-Object { [int]($_ -replace '\D','') })
            $NodeK = @($Adv.Keys | Where-Object { $_ -like "sched.node*.affinity" } | Sort-Object { [int]($_ -replace '\D','') })
            $VcpuVals = @($VcpuK | ForEach-Object { $Adv[$_] })
            $Distinct = @($VcpuVals | Sort-Object -Unique)
            $VcpuSummary = if ($VcpuK.Count -eq 0) { "-" }
                           elseif ($Distinct.Count -le 4) { ($Distinct | ForEach-Object { "[$_]" }) -join " " }
                           else { "$($VcpuVals[0]) … $($VcpuVals[-1]) ($($Distinct.Count)종)" }
            $NodeSummary = if ($NodeK.Count -eq 0) { "-" } else { ($NodeK | ForEach-Object { "$($_ -replace 'sched\.node(\d+)\.affinity','n$1')=$($Adv[$_])" }) -join " " }
            $TopoKeys = @("numa.vcpu.coresPerNode","numa.autosize.vcpu.maxPerVirtualNode","cpuid.coresPerSocket","numa.nodeAffinity") | Where-Object { $Adv.ContainsKey($_) } | ForEach-Object { "$_=$($Adv[$_])" }
            $Aff += [PSCustomObject][ordered]@{
                Host = $H.Name; VM = $V.Name; Power = "$($V.PowerState)"
                vCPU = $NumCpu
                VcpuKeys = $VcpuK.Count
                NodeKeys = $NodeK.Count
                Mode = $(if ($VcpuK.Count -gt 0 -and $NodeK.Count -gt 0) { "vcpu+node" } elseif ($VcpuK.Count -gt 0) { "vcpu 핀" } elseif ($NodeK.Count -gt 0) { "node 단위" } else { "free float" })
                VcpuAffinity = $VcpuSummary
                NodeAffinity = $NodeSummary
                NumaTopoKeys = $(if ($TopoKeys) { $TopoKeys -join " " } else { "-" })
            }
            foreach ($k in ($VcpuK + $NodeK)) { $AffKeys += [PSCustomObject]@{ Host=$H.Name; VM=$V.Name; Key=$k; Value=$Adv[$k] } }

            # [3] 메모리
            $MemMB = 0; try { $MemMB = [double]$Cfg.Hardware.MemoryMB } catch { }
            $ResMB = 0; try { $ResMB = [double]$Cfg.MemoryAllocation.Reservation } catch { }
            $Locked = ""; try { $Locked = "$($Cfg.MemoryReservationLockedToMax)" } catch { }
            $HostUseMB = 0; $OvhMB = 0
            try { $HostUseMB = [double]$Qs.HostMemoryUsage } catch { }
            try { $OvhMB = [double]$Qs.ConsumedOverheadMemory } catch { }
            $Mem += [PSCustomObject][ordered]@{
                Host = $H.Name; VM = $V.Name; Power = "$($V.PowerState)"
                MemoryGB = [math]::Round($MemMB/1024, 0)
                ReservationGB = [math]::Round($ResMB/1024, 0)
                ReservedPct = $(if ($MemMB -gt 0) { [math]::Round(100*$ResMB/$MemMB, 0) } else { 0 })
                LockedToMax = $Locked
                Pin = (& $Key "sched.mem.pin")
                Prealloc = (& $Key "sched.mem.prealloc")
                VmxSwap = (& $Key "sched.swap.vmxSwapEnabled")
                Lpage1GB = (& $Key "sched.mem.lpage.enable1GPage")
                BackingGB = [math]::Round($HostUseMB/1024, 1)
                BackingPct = $(if ($MemMB -gt 0) { [math]::Round(100*$HostUseMB/$MemMB, 1) } else { 0 })
                OverheadGB = [math]::Round($OvhMB/1024, 1)
            }

            # [4] Shares
            $CpuLv = ""; $CpuSh = 0; $MemLv = ""; $MemSh = 0; $CpuRes = 0; $CpuLim = -1
            try { $CpuLv = "$($Cfg.CpuAllocation.Shares.Level)"; $CpuSh = [int]$Cfg.CpuAllocation.Shares.Shares } catch { }
            try { $MemLv = "$($Cfg.MemoryAllocation.Shares.Level)"; $MemSh = [int]$Cfg.MemoryAllocation.Shares.Shares } catch { }
            try { $CpuRes = [int64]$Cfg.CpuAllocation.Reservation; $CpuLim = [int64]$Cfg.CpuAllocation.Limit } catch { }
            $Ratio = if ($ShareMin -gt 0) { "{0:N0} : 1" -f ($CpuSh / $ShareMin) } else { "-" }
            $Shr += [PSCustomObject][ordered]@{
                Host = $H.Name; VM = $V.Name; Power = "$($V.PowerState)"
                CpuSharesLevel = $CpuLv
                CpuShares = $CpuSh
                CpuSharesPerVcpu = $(if ($NumCpu -gt 0) { [math]::Round($CpuSh / $NumCpu, 0) } else { 0 })
                CpuRatio_vs_HostMin = $Ratio
                MemSharesLevel = $MemLv
                MemShares = $MemSh
                CpuReservMHz = $CpuRes
                CpuLimitMHz = $(if ($CpuLim -eq -1) { "무제한" } else { "$CpuLim" })
            }
        }
    }

    # ---- 출력 ------------------------------------------------------------------
    $W = 260
    Write-Host "`n[1] VM 스펙 · vCPU 토폴로지" -ForegroundColor Green
    $Spec | Sort-Object Host, VM | Format-Table -AutoSize -Wrap | Out-String -Width $W | Write-Host
    Write-Host "[2] CPU Affinity  (VcpuAffinity: 값 종류가 4개 이하면 전부, 많으면 처음…끝 (종류 수))" -ForegroundColor Green
    $Aff | Sort-Object Host, VM | Format-Table -AutoSize -Wrap | Out-String -Width $W | Write-Host
    if ($AffinityDetail -and $AffKeys.Count -gt 0) {
        Write-Host "[2-상세] affinity 키 전체" -ForegroundColor Green
        $AffKeys | Sort-Object Host, VM, { [int]($_.Key -replace '\D','') } | Format-Table -AutoSize | Out-String -Width $W | Write-Host
    }
    Write-Host "[3] 메모리  (BackingGB/Pct = 호스트 물리 메모리 점유, 오버헤드 포함이라 100% 를 넘을 수 있음 · 꺼진 VM 은 0)" -ForegroundColor Green
    $Mem | Sort-Object Host, VM | Format-Table -AutoSize -Wrap | Out-String -Width $W | Write-Host
    Write-Host "[4] Share 비율  (CpuRatio_vs_HostMin = 같은 호스트 안 CPU shares 최소값 대비 · Level 이 custom 이 아니면 값은 vCPU 수에 비례해 자동 산정된 것)" -ForegroundColor Green
    $Shr | Sort-Object Host, VM | Format-Table -AutoSize -Wrap | Out-String -Width $W | Write-Host
    Write-Host "[CAT] L3 캐시 분할 설정은 vCenter 로 읽을 수 없어 생략 — 호스트에서 sched-stats -t qos-enforcement 또는 set_cat_qos 의 STATE DUMP 로 확인" -ForegroundColor DarkGray

    if (-not [string]::IsNullOrWhiteSpace($OutCsv)) {
        $Spec | Export-Csv -Path "${OutCsv}_spec.csv"     -NoTypeInformation -Encoding UTF8
        $Aff  | Export-Csv -Path "${OutCsv}_affinity.csv" -NoTypeInformation -Encoding UTF8
        $Mem  | Export-Csv -Path "${OutCsv}_memory.csv"   -NoTypeInformation -Encoding UTF8
        $Shr  | Export-Csv -Path "${OutCsv}_shares.csv"   -NoTypeInformation -Encoding UTF8
        if ($AffKeys.Count -gt 0) { $AffKeys | Export-Csv -Path "${OutCsv}_affinity_keys.csv" -NoTypeInformation -Encoding UTF8 }
        Write-Host "CSV 저장: ${OutCsv}_spec/_affinity/_memory/_shares(.csv)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{ Spec = $Spec; Affinity = $Aff; AffinityKeys = $AffKeys; Memory = $Mem; Shares = $Shr }
}

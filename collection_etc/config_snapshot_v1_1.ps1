# ==============================================================================
# config_snapshot_v1_1.ps1   v1.1 (2026-10-20)
#
#   v1.1: xlsx 를 Excel 없이 직접 생성하고 판독한다 (Excel COM 미사용). Excel 이 없거나 바쁜 PC 에서도 xlsx 가 나온다.
#
#   테스트 전 구성 스냅샷. 호스트 고급 설정, VM 스펙, VM ExtraConfig 는 vCenter 에서 읽고,
#   게스트 OS 값(guest_config_push.sh 가 올린 것)과 CAT 값(set_cat_qos --ops 가 올린 것)은
#   Operations 에서 읽어 한 번에 파일 1벌로 만든다. 호스트 고급 설정과 VM ExtraConfig 는
#   이력 보관을 위해 Operations 속성으로도 기록한다 (-NoOps 로 생략). affinity 키는 기록하지 않는다.
#
#   [함수]
#     New-ConfigSnapshot    스냅샷 생성 (파일 + 화면 표 + 직전 파일 대비 변경점 + Operations 기록)
#     Test-ConfigSnapshot   사전 점검 (vCenter 호스트/VM, Operations 토큰, 객체 조회, 올라온 Guest/CAT 속성 수)
#
#   [New-ConfigSnapshot 옵션]
#     -VMHostName <패턴,…>   대상 호스트 (와일드카드, 복수 가능). 그 호스트의 VM 전부가 대상
#     -VMName <패턴,…>       VM 이름 패턴으로 좁히기 (선택)
#     -Exclude <패턴,…>      제외할 VM (기본 vCLS*)
#     -OutDir <폴더>         저장 폴더 (예: C:\config). 생략하면 USER SETTINGS 의 $CfgSnap_OutDirDefault
#     -Format csv | xlsx     csv(기본): config_<yyyyMMdd-HHmm>_host.csv + config_<yyyyMMdd-HHmm>_vm.csv
#                            xlsx    : config_<yyyyMMdd-HHmm>.xlsx 한 파일, Host 시트 + VM 시트 (Excel 설치 불필요)
#     -NoOps                 Operations 에 기록하지 않음 (Guest, CAT 읽기는 함)
#     -OpsHost, -OpsUser, -PassFile, -OpsPassword(SecureString)   USER SETTINGS 대신 쓸 값
#     -Quiet                 화면 표 생략
#
#   [파일 형식]  세로 배치. 열 = 구분, 항목, 객체 이름(호스트 또는 VM)…
#     Host : 수집 시각 / 서버 기본 정보 / 서버 구성 정보 > BIOS / 서버 Advanced config / CAT
#     VM   : 수집 시각 / VM 기본 정보 / vm advanced config / Guest OS / CPU affinity (맨 뒤)
#     구간마다 첫 행이 "기준 시각 (…)" 이다. 그 구간의 값이 어느 시점 값인지 객체별로 적는다.
#       기준 시각 (vCenter 조회)          = 이 스크립트가 vCenter 를 조회한 시각 (= 수집 시각)
#       기준 시각 (set_cat_qos 적용)      = set_cat_qos --ops 가 CAT 를 적용하고 기록한 시각 (Applied At)
#       기준 시각 (guest_config_push 수집) = 게스트 안에서 guest_config_push.sh 가 값을 읽은 시각 (Collected At)
#     CPU affinity 행 수 = 대상 VM 중 가장 큰 vCPU 수. vCPU 가 적은 VM 은 빈칸
#
#   [Operations]
#     인증은 vmkperf_ops_push, ops_metric_push 와 같은 암호문 (OPS_PASS_ENC + OPS_ENC_KEY 를 그대로 복사).
#     기록: Custom Configuration|Host|<고급 설정 키>, Custom Configuration|Host|SNC
#           Custom Configuration|VM|<ExtraConfig 키>   (sched.mem.pin 과 affinity 키 제외)
#     읽기: Custom Configuration|CAT|*  (호스트 객체),  Custom Configuration|Guest|*  (VM 객체)
#     CAT 는 휘발성이라 호스트 BootTime 이 Applied At 보다 뒤면 Profile 에 "none (host rebooted …)",
#     VM BootTime 이 뒤면 Tagging 에 "[<vm> powered on … tags lost]" 를 붙인다.
#
#   사용 예
#     Connect-VIServer <vCenter>
#     . .\config_snapshot_v1_1.ps1
#     Test-ConfigSnapshot -VMHostName esx01
#     New-ConfigSnapshot -VMHostName esx01 -OutDir C:\config
#     New-ConfigSnapshot -VMHostName esx0* -OutDir C:\config -Format xlsx
#     New-ConfigSnapshot -VMHostName esx01 -OutDir C:\config -NoOps
# ==============================================================================

# ==== USER SETTINGS - 여기만 고친다 ===========================================
$Global:CfgSnap_OpsHost       = ""   # VCF Operations 주소
$Global:CfgSnap_OpsUser       = ""                      # Operations LOCAL 계정
$Global:CfgSnap_OpsAuthSource = "LOCAL"
$Global:CfgSnap_OpsInsecure   = $true                          # TLS 인증서 검증 생략
$Global:CfgSnap_OpsPassEnc    = ""   # ops_metric_push_v4_1.sh 의 OPS_PASS_ENC 값 그대로
$Global:CfgSnap_OpsEncKey     = ""   # ops_metric_push_v4_1.sh 의 OPS_ENC_KEY 값 그대로
$Global:CfgSnap_OutDirDefault = "C:\config"                    # -OutDir 생략 시 저장 폴더
$Global:CfgSnap_FormatDefault = "csv"                          # csv | xlsx
# 서버 Advanced config 행. 키를 더하면 행이 늘어난다
$Global:CfgSnap_HostAdvancedKeys = @("Numa.LocalityWeightActionAffinity", "Cpu.HTWholeCoreThreshold")
# vm advanced config 행. sched.mem.pin 은 vCenter 가 값을 돌려주지 않아 (조회 불가) 로 적힌다
$Global:CfgSnap_VmAdvancedKeys = @(
    "sched.mem.lpage.enable1GPage", "sched.mem.pin", "sched.mem.prealloc", "sched.mem.prealloc.pinnedMainMem", "sched.swap.vmxSwapEnabled",
    "numa.vcpu.preferHT", "numa.vcpu.maxPerVirtualNode",
    "monitor_control.halt_in_monitor", "monitor.idleLoopSpinBeforeHalt", "monitor.idleLoopMinSpinUS", "monitor_control.disable_pause_loop_exiting",
    "vpmc.enable")
# Guest OS 행 (guest_config_push.sh 가 Operations 에 올리는 이름과 같아야 한다). 기준 시각은 Collected At 속성
$Global:CfgSnap_GuestItems = @("THP enabled", "THP defrag", "khugepaged scan_sleep_millisecs", "khugepaged pages_to_scan",
    "kernel.numa_balancing", "hugepages 2MB nr_hugepages", "hugepages 1GB nr_hugepages", "default_hugepagesz (cmdline)", "kernel")
$Global:CfgSnap_GuestTimeItem = "Collected At"
# CAT 행 (set_cat_qos --ops 가 올리는 이름). 기준 시각은 Applied At 속성
$Global:CfgSnap_CatItems = @("Profile", "Masks", "LLC Instances", "Tagging")
$Global:CfgSnap_CatTimeItem = "Applied At"
# 기준 시각 행 이름
$Global:CfgSnap_TimeLabelVc    = "기준 시각 (vCenter 조회)"
$Global:CfgSnap_TimeLabelCat   = "기준 시각 (set_cat_qos 적용)"
$Global:CfgSnap_TimeLabelGuest = "기준 시각 (guest_config_push 수집)"
$Global:CfgSnap_PropRootHost  = "Custom Configuration|Host"
$Global:CfgSnap_PropRootVm    = "Custom Configuration|VM"
$Global:CfgSnap_PropRootGuest = "Custom Configuration|Guest"
$Global:CfgSnap_PropRootCat   = "Custom Configuration|CAT"
$Global:CfgSnap_VmTypeAttr    = "VM_TYPE"                      # 역할(PVM/SVM) 커스텀 속성 이름
# ==== USER SETTINGS 끝 ========================================================

$Global:CfgSnap_IrmSplat = @{}


# ---------------------------------------------------------------- Operations ----
function ConvertFrom-OpsEnc {
    # openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 -A 암호문을 .NET 으로 푼다
    param ([string]$Enc, [string]$Key)
    $bytes = [Convert]::FromBase64String($Enc)
    if ($bytes.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "Salted__") { throw "OPS_PASS_ENC 형식이 openssl Salted__ 가 아님" }
    $salt = New-Object byte[] 8
    [Array]::Copy($bytes, 8, $salt, 0, 8)
    $data = New-Object byte[] ($bytes.Length - 16)
    [Array]::Copy($bytes, 16, $data, 0, $data.Length)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes([Text.Encoding]::UTF8.GetBytes($Key), $salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $keyiv = $kdf.GetBytes(48)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [byte[]]$keyiv[0..31]
    $aes.IV = [byte[]]$keyiv[32..47]
    $dec = $aes.CreateDecryptor().TransformFinalBlock($data, 0, $data.Length)
    return [Text.Encoding]::UTF8.GetString($dec).TrimEnd("`r", "`n")
}

function Get-OpsPassword {
    param ([System.Security.SecureString]$OpsPassword, [string]$PassFile)
    if ($OpsPassword) { return [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($OpsPassword)) }
    if ($PassFile) { return (Get-Content -LiteralPath $PassFile -TotalCount 1).Trim() }
    if ($env:OPS_PASSWORD) { return $env:OPS_PASSWORD }
    if ($Global:CfgSnap_OpsPassEnc -and $Global:CfgSnap_OpsEncKey) { return (ConvertFrom-OpsEnc -Enc $Global:CfgSnap_OpsPassEnc -Key $Global:CfgSnap_OpsEncKey) }
    throw "Operations 비밀번호 없음: USER SETTINGS 의 CfgSnap_OpsPassEnc/CfgSnap_OpsEncKey, -PassFile, -OpsPassword, 환경변수 OPS_PASSWORD 중 하나"
}

function Initialize-OpsTls {
    param ([bool]$Insecure)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Global:CfgSnap_IrmSplat = @{}
    if ($Insecure) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $Global:CfgSnap_IrmSplat = @{ SkipCertificateCheck = $true } }
        else { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
}

function Connect-OpsApi {
    # 토큰 발급 + 인증 헤더 방식(OpsToken / vRealizeOpsToken) 확인. 세션 객체 반환
    param ([string]$OpsHost, [string]$User, [string]$Password, [bool]$Insecure = $true)
    Initialize-OpsTls -Insecure $Insecure
    $irm = $Global:CfgSnap_IrmSplat
    $base = "https://$OpsHost"
    $body = @{ username = $User; password = $Password; authSource = $Global:CfgSnap_OpsAuthSource } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod @irm -Method Post -Uri "$base/suite-api/api/auth/token/acquire" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json" -Headers @{ Accept = "application/json" } -TimeoutSec 20
    if (-not $resp.token) { throw "토큰 발급 실패" }
    $session = [PSCustomObject]@{ Base = $base; Token = "$($resp.token)"; Scheme = "" }
    foreach ($s in @("OpsToken", "vRealizeOpsToken")) {
        try {
            $null = Invoke-RestMethod @irm -Method Get -Uri "$base/suite-api/api/resources?pageSize=1&_no_links=true" -Headers @{ Authorization = "$s $($session.Token)"; Accept = "application/json" } -TimeoutSec 20
            $session.Scheme = $s
            break
        } catch { }
    }
    if (-not $session.Scheme) { throw "인증 헤더 거부 (OpsToken, vRealizeOpsToken 모두 실패)" }
    return $session
}

function Invoke-OpsApi {
    param ($Session, [string]$Method, [string]$Path, $Body = $null)
    $irm = $Global:CfgSnap_IrmSplat
    $h = @{ Authorization = "$($Session.Scheme) $($Session.Token)"; Accept = "application/json" }
    if ($null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
        return Invoke-RestMethod @irm -Method $Method -Uri "$($Session.Base)$Path" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType "application/json" -TimeoutSec 30
    }
    return Invoke-RestMethod @irm -Method $Method -Uri "$($Session.Base)$Path" -Headers $h -TimeoutSec 30
}

function Find-OpsResource {
    # 이름으로 객체 ID 조회. 정확 일치(대소문자 무시) 우선, 없으면 짧은 이름 + 도메인 형태도 허용. 없으면 $null
    param ($Session, [ValidateSet("HostSystem","VirtualMachine")][string]$Kind, [string]$Name)
    $q = "adapterKindKey=VMWARE&resourceKind=$Kind&name=$([Uri]::EscapeDataString($Name))&_no_links=true"
    $r = Invoke-OpsApi -Session $Session -Method Get -Path "/suite-api/api/resources?$q"
    $hit = @($r.resourceList | Where-Object { "$($_.resourceKey.name)".ToLower() -eq $Name.ToLower() })
    if ($hit.Count -gt 0) { return "$($hit[0].identifier)" }
    $short = $Name.Split(".")[0]
    $rx = "^" + [Regex]::Escape($short) + "(\..*)?$"
    $q2 = "adapterKindKey=VMWARE&resourceKind=$Kind&regex=$([Uri]::EscapeDataString($rx))&_no_links=true"
    $r2 = Invoke-OpsApi -Session $Session -Method Get -Path "/suite-api/api/resources?$q2"
    $hit2 = @($r2.resourceList | Where-Object { "$($_.resourceKey.name)" -match "(?i)$rx" })
    if ($hit2.Count -gt 0) { return "$($hit2[0].identifier)" }
    return $null
}

function Get-OpsProperties {
    # 객체 속성 전부를 해시로 (이름 → 값)
    param ($Session, [string]$ResourceId)
    $r = Invoke-OpsApi -Session $Session -Method Get -Path "/suite-api/api/resources/$ResourceId/properties"
    $h = @{}
    foreach ($p in @($r.property)) { if ($p -and $p.name) { $h["$($p.name)"] = "$($p.value)" } }
    return $h
}

function Set-OpsProperties {
    # 속성 기록. $Props = 해시 (statKey → 문자열 값). 기록한 개수 반환
    param ($Session, [string]$ResourceId, [hashtable]$Props)
    if ($Props.Count -eq 0) { return 0 }
    $ts = [int64]((Get-Date).ToUniversalTime() - [datetime]"1970-01-01").TotalMilliseconds
    $content = @()
    foreach ($k in $Props.Keys) { $content += @{ statKey = $k; timestamps = @($ts); values = @("$($Props[$k])") } }
    $null = Invoke-OpsApi -Session $Session -Method Post -Path "/suite-api/api/resources/$ResourceId/properties" -Body @{ "property-content" = $content }
    return $content.Count
}


# ---------------------------------------------------------------- vCenter 읽기 ----
function Get-PowerPolicyLabel {
    param ([string]$ShortName)
    switch ($ShortName) {
        "static"  { return "High Performance" }
        "dynamic" { return "Balanced" }
        "low"     { return "Low Power" }
        "custom"  { return "Custom" }
        default   { if ($ShortName) { return $ShortName } else { return "(조회 불가)" } }
    }
}

function Get-HostAdvValue {
    param ($VMHost, [string]$Key)
    try {
        $s = Get-AdvancedSetting -Entity $VMHost -Name $Key -ErrorAction Stop | Select-Object -First 1
        if ($s) { return "$($s.Value)" }
    } catch { }
    return "(없음)"
}

function Get-VmExtraConfig {
    # ExtraConfig 와 Get-AdvancedSetting 을 합친 해시 (키 → 값)
    param ($VM)
    $h = @{}
    foreach ($o in @($VM.ExtensionData.Config.ExtraConfig)) { if ($o -and $o.Key) { $h["$($o.Key)"] = "$($o.Value)" } }
    foreach ($s in @(Get-AdvancedSetting -Entity $VM -ErrorAction SilentlyContinue)) { if ($s -and $s.Name) { $h["$($s.Name)"] = "$($s.Value)" } }
    return $h
}

function Get-HostSnapshotData {
    # 호스트 1대의 값 (All: 행 이름 → 값)
    param ($VMHost)
    $hw = $VMHost.ExtensionData.Hardware
    $d = [ordered]@{}
    $d["ESX Hostname"] = $VMHost.Name
    $d["ESXi Version"] = "$($VMHost.Version) build-$($VMHost.Build)"
    $pk = [int]$hw.CpuInfo.NumCpuPackages
    $co = [int]$hw.CpuInfo.NumCpuCores
    $th = [int]$hw.CpuInfo.NumCpuThreads
    $d["CPU (sockets x cores)"] = "$pk x $([int]($co / [math]::Max($pk, 1)))"
    $d["Memory (GB)"] = "$([math]::Round($hw.MemorySize / 1GB, 0))"
    $pp = ""
    try { $pp = "$($VMHost.ExtensionData.Config.PowerSystemInfo.CurrentPolicy.ShortName)" } catch { }
    $d["Power Management"] = Get-PowerPolicyLabel -ShortName $pp
    $d["Hyperthreading"] = $(if ($co -gt 0 -and $th -ge 2 * $co) { "enabled" } else { "disabled" })
    $nn = 0
    try { $nn = [int]$hw.NumaInfo.NumNodes } catch { }
    $d["SNC"] = $(if ($nn -gt $pk) { "SNC-$([int]($nn / [math]::Max($pk, 1))) (NUMA nodes $nn)" } else { "disabled (NUMA nodes $nn)" })
    foreach ($k in $Global:CfgSnap_HostAdvancedKeys) { $d[$k] = Get-HostAdvValue -VMHost $VMHost -Key $k }
    foreach ($it in (@($Global:CfgSnap_CatItems) + $Global:CfgSnap_CatTimeItem)) { $d[$it] = "미수집" }
    $boot = $null
    try { $boot = $VMHost.ExtensionData.Runtime.BootTime } catch { }
    return [PSCustomObject]@{ Name = $VMHost.Name; All = $d; BootTime = $boot }
}

function Get-VmSnapshotData {
    # VM 1대의 값 (All: 행 이름 → 값). affinity 키는 Affinity 에 따로 둔다
    param ($VM, [string]$VMHostName)
    $cfg = $VM.ExtensionData.Config
    $ec = Get-VmExtraConfig -VM $VM
    $d = [ordered]@{}
    $d["host"] = $VMHostName
    $role = ""
    try { $role = "$((Get-Annotation -Entity $VM -CustomAttribute $Global:CfgSnap_VmTypeAttr -ErrorAction SilentlyContinue).Value)" } catch { }
    $d["role ($($Global:CfgSnap_VmTypeAttr))"] = $(if ($role) { $role } else { "(없음)" })
    $ncpu = [int]$cfg.Hardware.NumCPU
    $cps = 0
    try { $cps = [int]$cfg.Hardware.NumCoresPerSocket } catch { }
    $d["cpu"] = "$ncpu"
    $d["cores per socket / sockets"] = $(if ($cps -gt 0) { "$cps / $([int][math]::Ceiling($ncpu / $cps))" } else { "자동" })
    $d["memory (GB)"] = "$([math]::Round($cfg.Hardware.MemoryMB / 1024, 0))"
    $resMB = 0
    try { $resMB = [int64]$cfg.MemoryAllocation.Reservation } catch { }
    $locked = $false
    try { $locked = [bool]$cfg.MemoryReservationLockedToMax } catch { }
    $d["memory reservation"] = "$([math]::Round($resMB / 1024, 0))" + $(if ($locked) { " (locked)" } else { "" })
    $d["cpu shares"] = "$($cfg.CpuAllocation.Shares.Shares) ($($cfg.CpuAllocation.Shares.Level))"
    $d["mem shares"] = "$($cfg.MemoryAllocation.Shares.Shares) ($($cfg.MemoryAllocation.Shares.Level))"
    $ls = ""
    try { $ls = "$($cfg.LatencySensitivity.Level)" } catch { }
    $d["latency sensitivity"] = $(if ($ls) { $ls } else { "(조회 불가)" })
    foreach ($k in $Global:CfgSnap_VmAdvancedKeys) {
        if ($ec.ContainsKey($k) -and "$($ec[$k])" -ne "") { $d[$k] = "$($ec[$k])" }
        elseif ($k -eq "sched.mem.pin") { $d[$k] = "(조회 불가)" }
        else { $d[$k] = "(없음)" }
    }
    foreach ($it in (@($Global:CfgSnap_GuestItems) + $Global:CfgSnap_GuestTimeItem)) { $d[$it] = "미수집" }
    # CPU affinity 구간
    $aff = [ordered]@{}
    for ($i = 0; $i -lt $ncpu; $i++) {
        $k = "sched.vcpu$i.affinity"
        $aff[$k] = $(if ($ec.ContainsKey($k)) { "$($ec[$k])" } else { "(없음)" })
    }
    foreach ($k in @($ec.Keys | Where-Object { $_ -match '^sched\.node\d+\.affinity$' })) { $aff[$k] = "$($ec[$k])" }
    $aff["numa.nodeAffinity"] = $(if ($ec.ContainsKey("numa.nodeAffinity")) { "$($ec['numa.nodeAffinity'])" } else { "(없음)" })
    $boot = $null
    try { $boot = $VM.ExtensionData.Runtime.BootTime } catch { }
    return [PSCustomObject]@{ Name = $VM.Name; All = $d; Affinity = $aff; NumCpu = $ncpu; BootTime = $boot }
}

function ConvertTo-KstDate {
    # vCenter 의 DateTime(BootTime 등) 을 KST 로. Kind 가 Unspecified 면 UTC 로 본다
    param ($Utc)
    $d = [datetime]$Utc
    if ($d.Kind -eq [DateTimeKind]::Unspecified) { $d = [datetime]::SpecifyKind($d, [DateTimeKind]::Utc) }
    return $d.ToUniversalTime().AddHours(9)
}

function ConvertFrom-AppliedAt {
    # "2026-10-19 13:58:40" 또는 "2026-10-19 13:58:40 KST" → DateTime(KST). 실패하면 $null
    param ([string]$Text)
    $t = ($Text -replace '\s*KST\s*$', '').Trim()
    try { return [datetime]::ParseExact($t, "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}


# ---------------------------------------------------------------- 표 ----
function New-ValueMap {
    param ([string[]]$Names, [string]$Value)
    $m = @{}
    foreach ($n in $Names) { $m[$n] = $Value }
    return $m
}

function New-Section {
    # 구간 하나: Group 이름 + 행 목록. $Objects[i].All[항목] 에서 값을 가져온다
    # TimeItem 을 주면 그 이름의 "기준 시각" 행을 구간 첫 행으로 넣는다 (TimeMap: 객체 이름 → 시각 문자열)
    param ([string]$Group, [string[]]$Items, [object[]]$Objects, [string]$TimeItem = "", [hashtable]$TimeMap = $null)
    $m = [ordered]@{}
    if ($TimeItem -ne "") {
        $m[$TimeItem] = @{}
        foreach ($o in $Objects) { $m[$TimeItem][$o.Name] = $(if ($TimeMap -and $TimeMap.ContainsKey($o.Name)) { "$($TimeMap[$o.Name])" } else { "" }) }
    }
    foreach ($it in $Items) {
        $m[$it] = @{}
        foreach ($o in $Objects) { $m[$it][$o.Name] = $(if ($o.All.Contains($it)) { "$($o.All[$it])" } else { "" }) }
    }
    return @{ Group = $Group; Items = $m }
}

function New-VerticalRows {
    # 구간 목록 → 행 객체 목록. 구분은 구간의 첫 행에만 적는다
    param ([string[]]$ObjectNames, [object[]]$Sections)
    $rows = @()
    foreach ($sec in $Sections) {
        $first = $true
        foreach ($item in @($sec.Items.Keys)) {
            $o = [ordered]@{}
            $o["구분"] = $(if ($first) { $sec.Group } else { "" })
            $o["항목"] = $item
            foreach ($n in $ObjectNames) {
                $v = $sec.Items[$item][$n]
                $o[$n] = $(if ($null -eq $v) { "" } else { "$v" })
            }
            $rows += [PSCustomObject]$o
            $first = $false
        }
    }
    return $rows
}

function Get-CsvEncoding {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return "utf8BOM" }
    return "UTF8"
}

function Write-SnapshotCsv {
    param ([object[]]$Rows, [string]$Path)
    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding (Get-CsvEncoding)
}

# ---------------------------------------------------------------- xlsx: Excel 없이 OpenXML 로 직접 생성, 판독 ----
function Initialize-ZipTypes {
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
}

function ConvertTo-XlsxColumnName {
    # 1 -> A, 27 -> AA
    param ([int]$Index)
    $s = ""
    $n = $Index
    while ($n -gt 0) {
        $r = ($n - 1) % 26
        $s = [string][char](65 + $r) + $s
        $n = [int][math]::Floor(($n - 1) / 26)
    }
    return $s
}

function ConvertFrom-XlsxColumnName {
    # "AB12" -> 28
    param ([string]$Ref)
    $letters = ($Ref -replace '\d', '').ToUpper()
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
    return $n
}

function ConvertTo-XmlText {
    param ([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Add-ZipTextEntry {
    param ($Zip, [string]$Name, [string]$Content)
    $entry = $Zip.CreateEntry($Name)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.Write($Content)
    $writer.Dispose()
}

function Read-ZipEntryText {
    param ($Zip, [string]$Name)
    $entry = $Zip.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Dispose()
    return $text
}

function Get-XmlNodeText {
    param ($Node)
    if ($null -eq $Node) { return "" }
    if ($Node -is [string]) { return $Node }
    if ($Node -is [System.Xml.XmlNode]) { return $Node.InnerText }
    return "$Node"
}

function ConvertTo-XlsxSheetXml {
    # 행 객체 목록 -> worksheet XML. 1행 머리글 굵게, 구분 열은 다음 구분까지 세로 병합
    param ([object[]]$Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    $rowsArr = @($Rows)
    if ($rowsArr.Count -eq 0) {
        [void]$sb.Append('<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>(대상 없음)</t></is></c></row></sheetData></worksheet>')
        return $sb.ToString()
    }
    $cols = @($rowsArr[0].PSObject.Properties.Name)
    $nc = $cols.Count
    [void]$sb.Append('<cols><col min="1" max="1" width="26" customWidth="1"/><col min="2" max="2" width="44" customWidth="1"/>')
    if ($nc -gt 2) { [void]$sb.Append(('<col min="3" max="{0}" width="30" customWidth="1"/>' -f $nc)) }
    [void]$sb.Append('</cols><sheetData><row r="1">')
    for ($c = 0; $c -lt $nc; $c++) {
        [void]$sb.Append(('<c r="{0}1" t="inlineStr" s="1"><is><t xml:space="preserve">{1}</t></is></c>' -f (ConvertTo-XlsxColumnName ($c + 1)), (ConvertTo-XmlText $cols[$c])))
    }
    [void]$sb.Append('</row>')
    $merges = @()
    $start = 2
    for ($r = 0; $r -lt $rowsArr.Count; $r++) {
        $xr = $r + 2
        $g = "$($rowsArr[$r].($cols[0]))"
        if ($g -ne "" -and $r -gt 0) {
            if ($xr - 1 -gt $start) { $merges += ("A{0}:A{1}" -f $start, ($xr - 1)) }
            $start = $xr
        }
        [void]$sb.Append(('<row r="{0}">' -f $xr))
        for ($c = 0; $c -lt $nc; $c++) {
            $v = "$($rowsArr[$r].($cols[$c]))"
            if ($v -eq "") { continue }
            $style = ""
            if ($c -eq 0) { $style = ' s="2"' }
            [void]$sb.Append(('<c r="{0}{1}" t="inlineStr"{2}><is><t xml:space="preserve">{3}</t></is></c>' -f (ConvertTo-XlsxColumnName ($c + 1)), $xr, $style, (ConvertTo-XmlText $v)))
        }
        [void]$sb.Append('</row>')
    }
    $lastRow = $rowsArr.Count + 1
    if ($lastRow -gt $start) { $merges += ("A{0}:A{1}" -f $start, $lastRow) }
    [void]$sb.Append('</sheetData>')
    if ($merges.Count -gt 0) {
        [void]$sb.Append(('<mergeCells count="{0}">' -f $merges.Count))
        foreach ($m in $merges) { [void]$sb.Append(('<mergeCell ref="{0}"/>' -f $m)) }
        [void]$sb.Append('</mergeCells>')
    }
    [void]$sb.Append('</worksheet>')
    return $sb.ToString()
}

$Global:CfgSnap_XlsxContentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
$Global:CfgSnap_XlsxRootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
$Global:CfgSnap_XlsxWorkbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Host" sheetId="1" r:id="rId1"/><sheet name="VM" sheetId="2" r:id="rId2"/></sheets></workbook>'
$Global:CfgSnap_XlsxWorkbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
$Global:CfgSnap_XlsxStyles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="10"/><name val="Malgun Gothic"/></font><font><b/><sz val="10"/><name val="Malgun Gothic"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'

function Write-SnapshotXlsx {
    # Host, VM 시트를 가진 xlsx 를 직접 만든다 (Excel 설치 불필요). 실패하면 $false
    param ([object[]]$HostRows, [object[]]$VmRows, [string]$Path)
    Initialize-ZipTypes
    $tmp = "$Path.tmp"
    $fs = $null
    $zip = $null
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        Add-ZipTextEntry -Zip $zip -Name "[Content_Types].xml" -Content $Global:CfgSnap_XlsxContentTypes
        Add-ZipTextEntry -Zip $zip -Name "_rels/.rels" -Content $Global:CfgSnap_XlsxRootRels
        Add-ZipTextEntry -Zip $zip -Name "xl/workbook.xml" -Content $Global:CfgSnap_XlsxWorkbook
        Add-ZipTextEntry -Zip $zip -Name "xl/_rels/workbook.xml.rels" -Content $Global:CfgSnap_XlsxWorkbookRels
        Add-ZipTextEntry -Zip $zip -Name "xl/styles.xml" -Content $Global:CfgSnap_XlsxStyles
        Add-ZipTextEntry -Zip $zip -Name "xl/worksheets/sheet1.xml" -Content (ConvertTo-XlsxSheetXml -Rows $HostRows)
        Add-ZipTextEntry -Zip $zip -Name "xl/worksheets/sheet2.xml" -Content (ConvertTo-XlsxSheetXml -Rows $VmRows)
        $zip.Dispose()
        $zip = $null
        $fs.Dispose()
        $fs = $null
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch {
        Write-Warning "xlsx 작성 실패: $($_.Exception.Message)"
        try { if ($zip) { $zip.Dispose() } } catch { }
        try { if ($fs) { $fs.Dispose() } } catch { }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Read-SnapshotXlsx {
    # xlsx 의 시트 하나를 행 객체 목록으로 (변경점 비교용). 실패하면 $null
    param ([string]$Path, [string]$Sheet)
    Initialize-ZipTypes
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $wb = [xml](Read-ZipEntryText -Zip $zip -Name "xl/workbook.xml")
        $rels = [xml](Read-ZipEntryText -Zip $zip -Name "xl/_rels/workbook.xml.rels")
        $sheetNode = @($wb.workbook.sheets.sheet | Where-Object { "$($_.name)" -eq $Sheet })
        if ($sheetNode.Count -eq 0) { return $null }
        $rid = "$($sheetNode[0].GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'))"
        if ($rid -eq "") { $rid = "$($sheetNode[0].id)" }
        $rel = @($rels.Relationships.Relationship | Where-Object { "$($_.Id)" -eq $rid })
        if ($rel.Count -eq 0) { return $null }
        $target = "$($rel[0].Target)"
        if ($target.StartsWith("/")) { $target = $target.TrimStart("/") } else { $target = "xl/" + $target }
        $shared = @()
        $ssText = Read-ZipEntryText -Zip $zip -Name "xl/sharedStrings.xml"
        if ($ssText) {
            $ss = [xml]$ssText
            foreach ($si in @($ss.sst.si)) { $shared += (Get-XmlNodeText $si) }
        }
        $sx = [xml](Read-ZipEntryText -Zip $zip -Name $target)
        $table = @{}
        $maxCol = 0
        $maxRow = 0
        foreach ($row in @($sx.worksheet.sheetData.row)) {
            if ($null -eq $row) { continue }
            foreach ($cell in @($row.c)) {
                if ($null -eq $cell) { continue }
                $ref = "$($cell.GetAttribute('r'))"
                if ($ref -eq "") { continue }
                $ci = ConvertFrom-XlsxColumnName -Ref $ref
                $ri = [int]($ref -replace '\D', '')
                $type = "$($cell.GetAttribute('t'))"
                $val = ""
                switch ($type) {
                    "s"         { $idx = [int](Get-XmlNodeText $cell.v); if ($idx -lt $shared.Count) { $val = $shared[$idx] } }
                    "inlineStr" { $val = Get-XmlNodeText $cell.is }
                    default     { $val = Get-XmlNodeText $cell.v }
                }
                if (-not $table.ContainsKey($ri)) { $table[$ri] = @{} }
                $table[$ri][$ci] = $val
                if ($ci -gt $maxCol) { $maxCol = $ci }
                if ($ri -gt $maxRow) { $maxRow = $ri }
            }
        }
        if ($maxRow -lt 2 -or -not $table.ContainsKey(1)) { return $null }
        $cols = @()
        for ($c = 1; $c -le $maxCol; $c++) { $cols += $(if ($table[1].ContainsKey($c)) { "$($table[1][$c])" } else { "" }) }
        $rows = @()
        for ($r = 2; $r -le $maxRow; $r++) {
            $o = [ordered]@{}
            for ($c = 1; $c -le $maxCol; $c++) {
                if ($cols[$c - 1] -eq "") { continue }
                $o[$cols[$c - 1]] = $(if ($table.ContainsKey($r) -and $table[$r].ContainsKey($c)) { "$($table[$r][$c])" } else { "" })
            }
            $rows += [PSCustomObject]$o
        }
        return $rows
    } catch {
        Write-Warning "직전 xlsx 읽기 실패: $($_.Exception.Message)"
        return $null
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-PreviousSnapshotRows {
    # 같은 폴더의 직전 파일을 찾아 행 목록으로. 없으면 $null
    param ([string]$OutDir, [string]$Format, [string]$Kind, [string]$CurrentFile)
    if ($Format -eq "xlsx") {
        $prev = @(Get-ChildItem -LiteralPath $OutDir -Filter "config_*.xlsx" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $CurrentFile -and $_.Name -match '^config_\d{8}-\d{4}\.xlsx$' } | Sort-Object Name | Select-Object -Last 1)
        if ($prev.Count -eq 0) { return $null }
        $rows = Read-SnapshotXlsx -Path $prev[0].FullName -Sheet $(if ($Kind -eq "host") { "Host" } else { "VM" })
        if ($null -eq $rows) { return $null }
        return [PSCustomObject]@{ Label = $prev[0].Name; Rows = @($rows) }
    }
    $prev = @(Get-ChildItem -LiteralPath $OutDir -Filter "config_*_$Kind.csv" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $CurrentFile -and $_.Name -match "^config_\d{8}-\d{4}_$Kind\.csv$" } | Sort-Object Name | Select-Object -Last 1)
    if ($prev.Count -eq 0) { return $null }
    $rows = @(Import-Csv -LiteralPath $prev[0].FullName -Encoding (Get-CsvEncoding))
    if ($rows.Count -eq 0) { return $null }
    return [PSCustomObject]@{ Label = $prev[0].Name; Rows = $rows }
}

function Show-SnapshotDiff {
    # 직전 파일 대비 값이 바뀐 항목만 화면에 출력
    param ([string]$Kind, [object[]]$Rows, $Prev)
    if ($null -eq $Prev) { Write-Host "[변경점] $Kind : 비교할 직전 파일 없음" -ForegroundColor DarkGray; return }
    $skip = @("구분", "항목")
    $oldCols = @($Prev.Rows[0].PSObject.Properties.Name | Where-Object { $skip -notcontains $_ })
    $idx = @{}
    $g = ""
    foreach ($r in $Prev.Rows) { if ("$($r.'구분')" -ne "") { $g = "$($r.'구분')" }; $idx["$g|$($r.'항목')"] = $r }
    $changes = @()
    $g = ""
    foreach ($r in $Rows) {
        if ("$($r.'구분')" -ne "") { $g = "$($r.'구분')" }
        if ("$($r.'항목')" -eq "" -or "$($r.'항목')" -like "기준 시각*") { continue }   # 수집 시각, 기준 시각 행은 비교하지 않는다
        $o = $idx["$g|$($r.'항목')"]
        if ($null -eq $o) { continue }
        foreach ($c in @($r.PSObject.Properties.Name | Where-Object { $skip -notcontains $_ })) {
            if ($oldCols -notcontains $c) { continue }
            if ("$($o.$c)" -ne "$($r.$c)") { $changes += [PSCustomObject]@{ 객체 = $c; 항목 = $r.'항목'; 이전 = "$($o.$c)"; 현재 = "$($r.$c)" } }
        }
    }
    if ($changes.Count -eq 0) { Write-Host "[변경점] $Kind : 직전($($Prev.Label)) 대비 변경 없음" -ForegroundColor DarkGray }
    else {
        Write-Host "[변경점] $Kind : 직전($($Prev.Label)) 대비 $($changes.Count)건" -ForegroundColor Yellow
        $changes | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
    }
}


# ---------------------------------------------------------------- 메인 ----
function New-ConfigSnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)] [string[]]$VMHostName,
        [Parameter(Mandatory=$false)] [string[]]$VMName = @(),
        [Parameter(Mandatory=$false)] [string[]]$Exclude = @("vCLS*"),
        [Parameter(Mandatory=$false)] [string]$OutDir = "",
        [Parameter(Mandatory=$false)] [ValidateSet("", "csv", "xlsx")] [string]$Format = "",
        [Parameter(Mandatory=$false)] [switch]$NoOps,
        [Parameter(Mandatory=$false)] [string]$OpsHost = "",
        [Parameter(Mandatory=$false)] [string]$OpsUser = "",
        [Parameter(Mandatory=$false)] [string]$PassFile = "",
        [Parameter(Mandatory=$false)] [System.Security.SecureString]$OpsPassword,
        [Parameter(Mandatory=$false)] [switch]$Quiet
    )
    if (-not $OutDir) { $OutDir = $Global:CfgSnap_OutDirDefault }
    if (-not $Format) { $Format = $Global:CfgSnap_FormatDefault }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
    $now = Get-Date
    $stamp = $now.ToString("yyyyMMdd-HHmm")
    $collectedAt = $now.ToString("yyyy-MM-dd HH:mm:ss")

    # ---- 1. 대상 ----
    $hosts = @()
    foreach ($p in $VMHostName) {
        $f = @(Get-VMHost -Name $p -ErrorAction SilentlyContinue)
        if ($f.Count -eq 0) { Write-Warning "호스트 '$p' 없음" }
        $hosts += $f
    }
    $hosts = @($hosts | Sort-Object Name -Unique)
    if ($hosts.Count -eq 0) { Write-Error "대상 호스트 없음 (Connect-VIServer 확인)"; return }
    $vmsByHost = @{}
    foreach ($h in $hosts) {
        $vms = @(Get-VM -Location $h -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($VMName.Count -gt 0) { $vms = @($vms | Where-Object { $v = $_; @($VMName | Where-Object { $v.Name -like $_ }).Count -gt 0 }) }
        if ($Exclude.Count -gt 0) { $vms = @($vms | Where-Object { $v = $_; @($Exclude | Where-Object { $v.Name -like $_ }).Count -eq 0 }) }
        $vmsByHost[$h.Name] = $vms
    }
    $nVm = 0
    foreach ($h in $hosts) { $nVm += @($vmsByHost[$h.Name]).Count }
    Write-Host "[스냅샷] $collectedAt  호스트 $($hosts.Count)대, VM $nVm 대, 저장 $OutDir ($Format)" -ForegroundColor Cyan

    # ---- 2. Operations 세션 ----
    $ops = $null
    try {
        $oh = $(if ($OpsHost) { $OpsHost } else { $Global:CfgSnap_OpsHost })
        $ou = $(if ($OpsUser) { $OpsUser } else { $Global:CfgSnap_OpsUser })
        $pw = Get-OpsPassword -OpsPassword $OpsPassword -PassFile $PassFile
        $ops = Connect-OpsApi -OpsHost $oh -User $ou -Password $pw -Insecure $Global:CfgSnap_OpsInsecure
        Write-Host "[Operations] $oh 접속 ($($ops.Scheme))$(if ($NoOps) { ', 기록 생략(-NoOps)' })" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Operations 접속 실패: $($_.Exception.Message). Guest, CAT 구간은 미수집으로 적고 기록은 생략"
        $ops = $null
    }

    # ---- 3. 호스트 ----
    $hostData = @()
    foreach ($h in $hosts) {
        $hd = Get-HostSnapshotData -VMHost $h
        if ($ops) {
            try {
                $rid = Find-OpsResource -Session $ops -Kind HostSystem -Name $h.Name
                if ($rid) {
                    $props = Get-OpsProperties -Session $ops -ResourceId $rid
                    foreach ($it in (@($Global:CfgSnap_CatItems) + $Global:CfgSnap_CatTimeItem)) {
                        $k = "$($Global:CfgSnap_PropRootCat)|$it"
                        if ($props.ContainsKey($k)) { $hd.All[$it] = $props[$k] }
                    }
                    if (-not $NoOps) {
                        $w = @{}
                        foreach ($k in $Global:CfgSnap_HostAdvancedKeys) { $w["$($Global:CfgSnap_PropRootHost)|$k"] = $hd.All[$k] }
                        $w["$($Global:CfgSnap_PropRootHost)|SNC"] = $hd.All["SNC"]
                        $n = Set-OpsProperties -Session $ops -ResourceId $rid -Props $w
                        Write-Host "[Operations] $($h.Name) Host 속성 $n 개 기록" -ForegroundColor DarkGray
                    }
                } else { Write-Warning "Operations 에 HostSystem '$($h.Name)' 없음 (CAT 미수집)" }
            } catch { Write-Warning "$($h.Name) Operations 처리 실패: $($_.Exception.Message)" }
        }
        # CAT 유효성: 적용 뒤 호스트가 재부팅됐으면 CAT 는 초기화된 상태
        if ($hd.All["Applied At"] -ne "미수집" -and $hd.BootTime) {
            $ap = ConvertFrom-AppliedAt -Text $hd.All["Applied At"]
            if ($ap) {
                $bootKst = ConvertTo-KstDate -Utc $hd.BootTime
                if ($bootKst -gt $ap) { $hd.All["Profile"] = "none (host rebooted $($bootKst.ToString('yyyy-MM-dd HH:mm')) after apply, CAT reset; last=$($hd.All['Profile']))" }
            }
        }
        $hostData += $hd
    }

    # ---- 4. VM ----
    $vmData = @()
    foreach ($h in $hosts) {
        $hd = @($hostData | Where-Object { $_.Name -eq $h.Name })[0]
        foreach ($vm in @($vmsByHost[$h.Name])) {
            $vd = Get-VmSnapshotData -VM $vm -VMHostName $h.Name
            if ($ops) {
                try {
                    $rid = Find-OpsResource -Session $ops -Kind VirtualMachine -Name $vm.Name
                    if ($rid) {
                        $props = Get-OpsProperties -Session $ops -ResourceId $rid
                        foreach ($it in (@($Global:CfgSnap_GuestItems) + $Global:CfgSnap_GuestTimeItem)) {
                            $k = "$($Global:CfgSnap_PropRootGuest)|$it"
                            if ($props.ContainsKey($k)) { $vd.All[$it] = $props[$k] }
                        }
                        if (-not $NoOps) {
                            $w = @{}
                            foreach ($k in $Global:CfgSnap_VmAdvancedKeys) { if ($k -ne "sched.mem.pin") { $w["$($Global:CfgSnap_PropRootVm)|$k"] = $vd.All[$k] } }
                            $n = Set-OpsProperties -Session $ops -ResourceId $rid -Props $w
                            Write-Host "[Operations] $($vm.Name) VM 속성 $n 개 기록" -ForegroundColor DarkGray
                        }
                    } else { Write-Warning "Operations 에 VirtualMachine '$($vm.Name)' 없음 (Guest 미수집)" }
                } catch { Write-Warning "$($vm.Name) Operations 처리 실패: $($_.Exception.Message)" }
            }
            # CAT 태그 유효성: 적용 뒤 VM 이 다시 켜졌으면 그 VM 의 태그는 사라진 상태
            if ($hd -and $hd.All["Tagging"] -ne "미수집" -and $hd.All["Applied At"] -ne "미수집" -and $vd.BootTime -and ("$($hd.All['Tagging'])" -like "*$($vm.Name)*")) {
                $ap = ConvertFrom-AppliedAt -Text $hd.All["Applied At"]
                if ($ap) {
                    $bootKst = ConvertTo-KstDate -Utc $vd.BootTime
                    if ($bootKst -gt $ap) { $hd.All["Tagging"] = "$($hd.All['Tagging']) [$($vm.Name) powered on $($bootKst.ToString('yyyy-MM-dd HH:mm')) after apply, tags lost]" }
                }
            }
            $vmData += $vd
        }
    }

    # ---- 5. 표 ----
    $hostNames = @($hostData | ForEach-Object { $_.Name })
    $tVcHost = New-ValueMap -Names $hostNames -Value $collectedAt
    $tCat = @{}
    foreach ($hd in $hostData) { $tCat[$hd.Name] = "$($hd.All[$Global:CfgSnap_CatTimeItem])" }
    $sec = @()
    $sec += @{ Group = "수집 시각"; Items = [ordered]@{ "" = $tVcHost } }
    $sec += New-Section -Group "서버 기본 정보" -Items @("ESX Hostname", "ESXi Version", "CPU (sockets x cores)", "Memory (GB)") -Objects $hostData -TimeItem $Global:CfgSnap_TimeLabelVc -TimeMap $tVcHost
    $sec += New-Section -Group "서버 구성 정보 > BIOS" -Items @("Power Management", "Hyperthreading", "SNC") -Objects $hostData -TimeItem $Global:CfgSnap_TimeLabelVc -TimeMap $tVcHost
    $sec += New-Section -Group "서버 Advanced config" -Items $Global:CfgSnap_HostAdvancedKeys -Objects $hostData -TimeItem $Global:CfgSnap_TimeLabelVc -TimeMap $tVcHost
    $sec += New-Section -Group "CAT" -Items $Global:CfgSnap_CatItems -Objects $hostData -TimeItem $Global:CfgSnap_TimeLabelCat -TimeMap $tCat
    $hostRows = @(New-VerticalRows -ObjectNames $hostNames -Sections $sec)

    $vmNames = @($vmData | ForEach-Object { $_.Name })
    $vmRows = @()
    if ($vmData.Count -gt 0) {
        $tVcVm = New-ValueMap -Names $vmNames -Value $collectedAt
        $tGuest = @{}
        foreach ($vd in $vmData) { $tGuest[$vd.Name] = "$($vd.All[$Global:CfgSnap_GuestTimeItem])" }
        $vsec = @()
        $vsec += @{ Group = "수집 시각"; Items = [ordered]@{ "" = $tVcVm } }
        $vsec += New-Section -Group "VM 기본 정보" -Items @("host", "role ($($Global:CfgSnap_VmTypeAttr))", "cpu", "cores per socket / sockets", "memory (GB)", "memory reservation", "cpu shares", "mem shares", "latency sensitivity") -Objects $vmData -TimeItem $Global:CfgSnap_TimeLabelVc -TimeMap $tVcVm
        $vsec += New-Section -Group "vm advanced config" -Items $Global:CfgSnap_VmAdvancedKeys -Objects $vmData -TimeItem $Global:CfgSnap_TimeLabelVc -TimeMap $tVcVm
        $vsec += New-Section -Group "Guest OS" -Items $Global:CfgSnap_GuestItems -Objects $vmData -TimeItem $Global:CfgSnap_TimeLabelGuest -TimeMap $tGuest
        # CPU affinity: vcpu 행은 가장 큰 vCPU 수만큼, node 행은 발견된 키 (최소 node0, node1), 마지막 numa.nodeAffinity
        $maxCpu = 0
        foreach ($vd in $vmData) { if ($vd.NumCpu -gt $maxCpu) { $maxCpu = $vd.NumCpu } }
        $nodeKeys = @("sched.node0.affinity", "sched.node1.affinity")
        foreach ($vd in $vmData) { foreach ($k in @($vd.Affinity.Keys)) { if ($k -match '^sched\.node\d+\.affinity$' -and $nodeKeys -notcontains $k) { $nodeKeys += $k } } }
        $nodeKeys = @($nodeKeys | Sort-Object { [int]($_ -replace '\D', '') })
        $affKeys = @()
        for ($i = 0; $i -lt $maxCpu; $i++) { $affKeys += "sched.vcpu$i.affinity" }
        $affKeys += $nodeKeys
        $affKeys += "numa.nodeAffinity"
        $vaff = [ordered]@{}
        $vaff[$Global:CfgSnap_TimeLabelVc] = $tVcVm
        foreach ($k in $affKeys) {
            $vaff[$k] = @{}
            foreach ($vd in $vmData) {
                if ($vd.Affinity.Contains($k)) { $vaff[$k][$vd.Name] = "$($vd.Affinity[$k])" }
                elseif ($k -match '^sched\.vcpu(\d+)\.affinity$' -and [int]$Matches[1] -ge $vd.NumCpu) { $vaff[$k][$vd.Name] = "" }
                else { $vaff[$k][$vd.Name] = "(없음)" }
            }
        }
        $vsec += @{ Group = "CPU affinity"; Items = $vaff }
        $vmRows = @(New-VerticalRows -ObjectNames $vmNames -Sections $vsec)
    }

    # ---- 6. 파일 ----
    $written = @()
    $hp = Join-Path $OutDir "config_${stamp}_host.csv"
    $vp = Join-Path $OutDir "config_${stamp}_vm.csv"
    $xp = Join-Path $OutDir "config_$stamp.xlsx"
    if ($Format -eq "xlsx") {
        $prevHost = Get-PreviousSnapshotRows -OutDir $OutDir -Format xlsx -Kind host -CurrentFile $xp
        $prevVm = Get-PreviousSnapshotRows -OutDir $OutDir -Format xlsx -Kind vm -CurrentFile $xp
        if (Write-SnapshotXlsx -HostRows $hostRows -VmRows $vmRows -Path $xp) { $written += $xp }
        else { Write-Warning "xlsx 작성 실패, csv 로 저장합니다"; $Format = "csv" }
    }
    if ($Format -eq "csv") {
        $prevHost = Get-PreviousSnapshotRows -OutDir $OutDir -Format csv -Kind host -CurrentFile $hp
        $prevVm = Get-PreviousSnapshotRows -OutDir $OutDir -Format csv -Kind vm -CurrentFile $vp
        Write-SnapshotCsv -Rows $hostRows -Path $hp
        $written += $hp
        if ($vmRows.Count -gt 0) { Write-SnapshotCsv -Rows $vmRows -Path $vp; $written += $vp }
    }

    # ---- 7. 화면 ----
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "[Host]" -ForegroundColor Green
        $hostRows | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
        if ($vmRows.Count -gt 0) {
            Write-Host "[VM]" -ForegroundColor Green
            $vmRows | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
        }
    }
    Show-SnapshotDiff -Kind "host" -Rows $hostRows -Prev $prevHost
    if ($vmRows.Count -gt 0) { Show-SnapshotDiff -Kind "vm" -Rows $vmRows -Prev $prevVm }
    Write-Host "[저장] $($written -join '  ')" -ForegroundColor Green
}

function Test-ConfigSnapshot {
    # 사전 점검: vCenter 호스트/VM, Operations 토큰, 객체 조회, 올라온 Guest/CAT 속성 수
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)] [string[]]$VMHostName,
        [Parameter(Mandatory=$false)] [string]$OpsHost = "",
        [Parameter(Mandatory=$false)] [string]$OpsUser = "",
        [Parameter(Mandatory=$false)] [string]$PassFile = "",
        [Parameter(Mandatory=$false)] [System.Security.SecureString]$OpsPassword
    )
    $ok = $true
    $hosts = @()
    foreach ($p in $VMHostName) { $hosts += @(Get-VMHost -Name $p -ErrorAction SilentlyContinue) }
    $hosts = @($hosts | Sort-Object Name -Unique)
    if ($hosts.Count -eq 0) { Write-Host "[NG] vCenter 에서 호스트 없음: $($VMHostName -join ', ') (Connect-VIServer 확인)" -ForegroundColor Red; return }
    foreach ($h in $hosts) {
        $vms = @(Get-VM -Location $h -ErrorAction SilentlyContinue)
        Write-Host "[OK] 호스트 $($h.Name)  VM $($vms.Count)대: $(($vms | ForEach-Object { $_.Name }) -join ', ')"
        foreach ($k in $Global:CfgSnap_HostAdvancedKeys) { Write-Host "     $k = $(Get-HostAdvValue -VMHost $h -Key $k)" -ForegroundColor DarkGray }
    }
    try {
        $oh = $(if ($OpsHost) { $OpsHost } else { $Global:CfgSnap_OpsHost })
        $ou = $(if ($OpsUser) { $OpsUser } else { $Global:CfgSnap_OpsUser })
        $pw = Get-OpsPassword -OpsPassword $OpsPassword -PassFile $PassFile
        $ops = Connect-OpsApi -OpsHost $oh -User $ou -Password $pw -Insecure $Global:CfgSnap_OpsInsecure
        Write-Host "[OK] Operations $oh 토큰 ($($ops.Scheme))"
        foreach ($h in $hosts) {
            $rid = Find-OpsResource -Session $ops -Kind HostSystem -Name $h.Name
            if ($rid) {
                $props = Get-OpsProperties -Session $ops -ResourceId $rid
                $nCat = @($props.Keys | Where-Object { $_ -like "$($Global:CfgSnap_PropRootCat)|*" }).Count
                Write-Host "[OK] HostSystem $($h.Name) -> $rid  (속성 $($props.Count)개, CAT 속성 $nCat 개$(if ($nCat -eq 0) { ', set_cat_qos --ops 미실행' }))"
            } else { Write-Host "[NG] Operations 에 HostSystem '$($h.Name)' 없음" -ForegroundColor Red; $ok = $false }
            foreach ($vm in @(Get-VM -Location $h -ErrorAction SilentlyContinue)) {
                $vid = Find-OpsResource -Session $ops -Kind VirtualMachine -Name $vm.Name
                if ($vid) {
                    $props = Get-OpsProperties -Session $ops -ResourceId $vid
                    $nG = @($props.Keys | Where-Object { $_ -like "$($Global:CfgSnap_PropRootGuest)|*" }).Count
                    Write-Host "[OK] VirtualMachine $($vm.Name) -> $vid  (속성 $($props.Count)개, Guest 속성 $nG 개$(if ($nG -eq 0) { ', guest_config_push.sh 미실행' }))"
                } else { Write-Host "[NG] Operations 에 VirtualMachine '$($vm.Name)' 없음" -ForegroundColor Red; $ok = $false }
            }
        }
    } catch { Write-Host "[NG] Operations: $($_.Exception.Message)" -ForegroundColor Red; $ok = $false }
    if ($ok) { Write-Host "RESULT: ready" -ForegroundColor Green } else { Write-Host "RESULT: NG 항목 확인" -ForegroundColor Yellow }
}

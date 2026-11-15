# ==============================================================================
# Export-EsxiSettingsReference_v1_0.ps1   v1.0 (2026-10-26)
#
#   ESXi 호스트의 Advanced Settings 전수와 Kernel Settings 전수를 lamw/esxi-advanced-and-kernel-settings
#   저장소와 같은 열 구성의 markdown(.md) + csv 로 내보낸다. 저장소에 없는 판(ESXi 9.1 등)을 같은 형식으로
#   만들어 8.0 U3 · 9.0.1 파일과 바로 대조하기 위한 것이다.
#
#   읽는 경로는 전부 vCenter API 다 (SSH 미사용).
#     Advanced : HostAdvancedOptionManager.SupportedOption (정의·기본값·범위) + QueryOptions() (현재값)
#     Kernel   : Get-EsxCli -V2  → system.settings.kernel.list      (Name·Description·Default·Runtime·Configured)
#     ESXCLI 열: Get-EsxCli -V2  → system.settings.advanced.list   에 경로(/A/B → A.B)가 있으면 True
#
#   [출력]  <OutDir>\esxi-<버전숫자>-advanced-settings.md / .csv,  esxi-<버전숫자>-kernel-settings.md / .csv
#     Advanced md 열: Name | Description | Default | Current | Min | Max | ESXCLI
#     Kernel   md 열: Name | Description | Default | Runtime | Configured
#     첫 줄 제목: "# ESXi <버전> Build <빌드> Advanced Settings",  셋째 줄 "Total: N"  (저장소 파일과 동일)
#     긴 값(300자 초과)은 저장소와 같이 "TOO LONG TO PRINT" 로 적는다. csv 에는 원문을 그대로 둔다.
#
#   사용 예
#     Connect-VIServer <vCenter>
#     . .\Export-EsxiSettingsReference_v1_0.ps1
#     Export-EsxiSettingsReference -VMHostName esx46 -OutDir C:\config
#     Export-EsxiSettingsReference -VMHostName esx* -OutDir C:\config      # 호스트마다 파일 1벌
#
#   옵션
#     -VMHostName <패턴,…>   대상 호스트 (와일드카드, 복수 가능). 호스트마다 파일 1벌
#     -OutDir <폴더>         저장 폴더. 생략하면 USER SETTINGS 의 $EsxRef_OutDirDefault
#     -Tag <문자열>          파일명 버전 자리를 직접 지정 (예: 910). 생략하면 호스트 Version 에서 점을 뺀 값
#     -NoKernel              Kernel Settings 생략
#     -Quiet                 화면 요약 생략
# ==============================================================================

# ==== USER SETTINGS - 여기만 고친다 ===========================================
$Global:EsxRef_OutDirDefault = "C:\config"   # -OutDir 생략 시 저장 폴더
$Global:EsxRef_TooLong       = 300           # md 에서 이 길이를 넘는 값은 TOO LONG TO PRINT
# ==== USER SETTINGS 끝 ========================================================

function Format-EsxRefCell {
    # md 표 칸용. 파이프·줄바꿈 제거, 긴 값은 TOO LONG TO PRINT
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    $s = "$Value" -replace "`r", "" -replace "`n", " " -replace "\|", "\|"
    if ($s.Length -gt $Global:EsxRef_TooLong) { return "TOO LONG TO PRINT" }
    return $s
}

function Get-EsxRefAdvancedRows {
    # SupportedOption(정의) + QueryOptions(현재값) → 행 목록
    param([Parameter(Mandatory)]$VMHost, [hashtable]$EsxcliPaths)
    $om = Get-View -Id $VMHost.ExtensionData.ConfigManager.AdvancedOption -ErrorAction Stop
    $current = @{}
    foreach ($ov in @($om.QueryOptions($null))) { if ($ov.Key) { $current[$ov.Key] = $ov.Value } }
    $rows = @()
    foreach ($def in @($om.SupportedOption | Sort-Object Key)) {
        $t = $def.OptionType
        $default = $null; $min = "N/A"; $max = "N/A"
        if ($t) {
            if ($t.PSObject.Properties["DefaultValue"]) { $default = $t.DefaultValue }
            if ($t -is [VMware.Vim.IntOption] -or $t -is [VMware.Vim.LongOption] -or $t -is [VMware.Vim.FloatOption]) {
                $min = "$($t.Min)"; $max = "$($t.Max)"
            }
        }
        $cur = $null
        if ($current.ContainsKey($def.Key)) { $cur = $current[$def.Key] }
        $rows += [pscustomobject]@{
            Name        = $def.Key
            Description = $def.Summary
            Default     = $default
            Current     = $cur
            Min         = $min
            Max         = $max
            ESXCLI      = if ($EsxcliPaths -and $EsxcliPaths.ContainsKey($def.Key)) { "True" } else { "False" }
            Type        = if ($t) { $t.GetType().Name } else { "" }
        }
    }
    return $rows
}

function Get-EsxRefKernelRows {
    param([Parameter(Mandatory)]$Esxcli)
    $rows = @()
    foreach ($k in @($Esxcli.system.settings.kernel.list.Invoke() | Sort-Object Name)) {
        $rows += [pscustomobject]@{
            Name        = $k.Name
            Description = $k.Description
            Default     = $k.Default
            Runtime     = $k.Runtime
            Configured  = $k.Configured
            Type        = $k.Type
        }
    }
    return $rows
}

function Write-EsxRefMarkdown {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Title,
          [Parameter(Mandatory)][string[]]$Columns, [Parameter(Mandatory)]$Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# $Title")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Total: $(@($Rows).Count)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| " + ($Columns -join " | ") + " |")
    [void]$sb.AppendLine("|" + (($Columns | ForEach-Object { "---" }) -join "|") + "|")
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) { Format-EsxRefCell $r.$c }
        [void]$sb.AppendLine("| " + ($cells -join " | ") + " |")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
}

function Export-EsxiSettingsReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$VMHostName,
        [string]$OutDir,
        [string]$Tag,
        [switch]$NoKernel,
        [switch]$Quiet
    )
    if (-not $OutDir) { $OutDir = $Global:EsxRef_OutDirDefault }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $hosts = @()
    foreach ($p in $VMHostName) { $hosts += @(Get-VMHost -Name $p -ErrorAction SilentlyContinue) }
    $hosts = @($hosts | Sort-Object Name -Unique)
    if ($hosts.Count -eq 0) { Write-Error "대상 호스트 없음: $($VMHostName -join ', ') (Connect-VIServer 확인)"; return }

    $out = @()
    foreach ($h in $hosts) {
        $ver = "$($h.Version)"; $build = "$($h.Build)"
        $tag = if ($Tag) { $Tag } else { ($ver -replace "\.", "") }
        $stamp = Get-Date -Format "yyyyMMdd-HHmm"
        if (-not $Quiet) { Write-Host "[$($h.Name)] ESXi $ver build $build 읽는 중 ..." }

        $esxcli = $null; $advPaths = @{}
        try {
            $esxcli = Get-EsxCli -VMHost $h -V2 -ErrorAction Stop
            foreach ($a in @($esxcli.system.settings.advanced.list.Invoke())) {
                if ($a.Path) { $advPaths[($a.Path.TrimStart("/") -replace "/", ".")] = $true }
            }
        } catch { Write-Warning "[$($h.Name)] Get-EsxCli 실패 — ESXCLI 열은 전부 False, Kernel Settings 생략: $($_.Exception.Message)" }

        $adv = Get-EsxRefAdvancedRows -VMHost $h -EsxcliPaths $advPaths
        $advMd  = Join-Path $OutDir "esxi-$tag-advanced-settings.md"
        $advCsv = Join-Path $OutDir "esxi-$tag-advanced-settings_$($h.Name.Split('.')[0])_$stamp.csv"
        Write-EsxRefMarkdown -Path $advMd -Title "ESXi $ver Build $build Advanced Settings" `
            -Columns @("Name", "Description", "Default", "Current", "Min", "Max", "ESXCLI") -Rows $adv
        $adv | Select-Object Name, Description, Default, Current, Min, Max, ESXCLI, Type |
            Export-Csv -Path $advCsv -NoTypeInformation -Encoding UTF8
        $out += [pscustomobject]@{ Host = $h.Name; Version = $ver; Build = $build; Kind = "Advanced"; Count = $adv.Count; File = $advMd }

        if (-not $NoKernel -and $esxcli) {
            $ker = Get-EsxRefKernelRows -Esxcli $esxcli
            $kerMd  = Join-Path $OutDir "esxi-$tag-kernel-settings.md"
            $kerCsv = Join-Path $OutDir "esxi-$tag-kernel-settings_$($h.Name.Split('.')[0])_$stamp.csv"
            Write-EsxRefMarkdown -Path $kerMd -Title "ESXi $ver Build $build Kernel Settings" `
                -Columns @("Name", "Description", "Default", "Runtime", "Configured") -Rows $ker
            $ker | Select-Object Name, Description, Default, Runtime, Configured, Type |
                Export-Csv -Path $kerCsv -NoTypeInformation -Encoding UTF8
            $out += [pscustomobject]@{ Host = $h.Name; Version = $ver; Build = $build; Kind = "Kernel"; Count = $ker.Count; File = $kerMd }
        }
    }
    if (-not $Quiet) { $out | Format-Table -AutoSize | Out-String | Write-Host }
    return $out
}

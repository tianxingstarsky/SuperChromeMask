# ============================================================
#  SuperMask 打包脚本: 源码 -> 单文件exe
#  流程: 合并 lib 模块 + 主程序 => 独立 bundled ps1 => ps2exe
#  产物: build\SuperMask.exe (GUI), build\EmergencyRestore.exe
# ============================================================
[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [switch]$SkipBuild   # 只生成 bundled ps1, 不调 ps2exe(调试用)
)
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null

function Read-Utf8 { param($p) [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) }

# ---- 1. 合并 lib(按依赖顺序) + 主程序(去掉 dot-source 行) ----
$libOrder = @('common.ps1', 'locations.ps1', 'geoip.ps1', 'cdp.ps1', 'browser.ps1', 'sysmask.ps1')
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('# ============================================================')
[void]$sb.AppendLine("#  SuperMask SuperMask v$Version - 单文件打包版 (由 build\make-exe.ps1 生成, 勿手改)")
[void]$sb.AppendLine('# ============================================================')
foreach ($f in $libOrder) {
    [void]$sb.AppendLine(("# ---- lib/$f ----"))
    [void]$sb.AppendLine((Read-Utf8 (Join-Path $root "lib\$f")))
}
$main = Read-Utf8 (Join-Path $root 'SuperMask.ps1')
$mainLines = $main -split "`r?`n" | Where-Object { $_ -notlike '. (Join-Path*' }
[void]$sb.AppendLine(($mainLines -join "`r`n"))
$bundled = Join-Path $build 'SuperMask-bundled.ps1'
[IO.File]::WriteAllText($bundled, $sb.ToString(), [Text.UTF8Encoding]::new($true))
Write-Host "bundled -> $bundled"

# 语法自检 bundled
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($bundled, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" }; throw 'bundled 语法错误' }
Write-Host 'bundled syntax OK'

if ($SkipBuild) { return }

# ---- 2. ps2exe ----
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host 'installing ps2exe module...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$verInfo = @{ version = $Version; company = 'SuperMask' }

Invoke-ps2exe -inputFile $bundled -outputFile (Join-Path $build 'SuperMask.exe') `
    -noConsole -title 'SuperMask 超级面具' -description 'SuperMask 超级面具 - 浏览器地理伪装, 用完即恢复' `
    -product 'SuperMask' @verInfo -verbose:$false | Out-Null
Write-Host "built -> build\SuperMask.exe"

Invoke-ps2exe -inputFile (Join-Path $root 'EmergencyRestore.ps1') -outputFile (Join-Path $build 'EmergencyRestore.exe') `
    -title 'SuperMask 紧急恢复' -description 'SuperMask 紧急恢复 - 还原系统时区/清理临时文件/移除守卫' `
    -product 'SuperMask' @verInfo -verbose:$false | Out-Null
Write-Host "built -> build\EmergencyRestore.exe"

Get-ChildItem $build -Filter *.exe | ForEach-Object { Write-Host ('  {0}  {1:N0} KB' -f $_.Name, ($_.Length / 1KB)) }
Write-Host "done."

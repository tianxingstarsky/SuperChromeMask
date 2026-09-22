# ============================================================
#  SuperMask - 超级面具  公共库
#  状态文件 / 用户偏好 / 日志 / 路径安全 / 网络工具
#  设计原则: 运行时优先, 不修改系统文件, 用完即恢复
# ============================================================
# 注意: 不要在此处使用 $PSScriptRoot —— ps2exe 打包后它是空字符串,
# 会导致 exe 启动即报"无法将参数绑定到参数Path"并终止(主窗口不出现)

$script:SMStateDir       = Join-Path $env:LOCALAPPDATA 'SuperMask'
$script:SMStateFile      = Join-Path $script:SMStateDir 'session.json'
$script:SMConfigFile     = Join-Path $script:SMStateDir 'config.json'
$script:SMTempRoot       = Join-Path $env:TEMP 'SuperMask'
$script:SMProfileKeepRoot= Join-Path $script:SMStateDir 'profiles'
$script:SMGuardName      = 'SuperMaskRestoreGuard.cmd'

foreach ($d in @($script:SMStateDir, $script:SMTempRoot)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------- 日志 ----------------
$script:SMLogSink = $null
function Set-LogSink { param($Sink) $script:SMLogSink = $Sink }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
    if ($script:SMLogSink) { & $script:SMLogSink $line $Level }
    else { Write-Host $line }
}

# ---------------- 会话状态(崩溃恢复的依据) ----------------
function Get-SessionState {
    if (Test-Path $script:SMStateFile) {
        try { return (Get-Content $script:SMStateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}
function Save-SessionState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:SMStateFile -Encoding UTF8 -Force
}
function Clear-SessionState {
    Remove-Item $script:SMStateFile -Force -ErrorAction SilentlyContinue
}

# ---------------- 用户偏好 ----------------
function Get-AppConfig {
    if (Test-Path $script:SMConfigFile) {
        try { return (Get-Content $script:SMConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}
function Save-AppConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $script:SMConfigFile -Encoding UTF8 -Force
}

# ---------------- 路径安全: 只允许删除本工具管理的目录 ----------------
function Test-SafeManagedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if ($full -match '\.\.') { return $false }
        $allowed = @(
            [IO.Path]::GetFullPath($script:SMTempRoot),
            [IO.Path]::GetFullPath($script:SMProfileKeepRoot)
        )
        foreach ($a in $allowed) {
            if ($full.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    } catch { return $false }
}

function Remove-ManagedTree {
    param([string]$Path)
    if (-not (Test-SafeManagedPath $Path)) { Write-Log "拒绝删除非托管路径: $Path" 'WARN'; return $false }
    if (-not (Test-Path $Path)) { return $true }
    for ($i = 0; $i -lt 6; $i++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $true }
        catch { Start-Sleep -Milliseconds 400 }
    }
    Write-Log "目录清理失败(可能仍被占用, 可稍后手动删除): $Path" 'WARN'
    return $false
}

# 清理历史残留的临时配置目录(超过24小时未动)
function Cleanup-OldTempDirs {
    try {
        if (-not (Test-Path $script:SMTempRoot)) { return }
        $cutoff = (Get-Date).AddDays(-1)
        Get-ChildItem $script:SMTempRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'profile_*' -and $_.LastWriteTime -lt $cutoff
        } | ForEach-Object { Remove-ManagedTree $_.FullName | Out-Null }
    } catch {}
}

# ---------------- 网络 ----------------
function Get-FreeTcpPort {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return $l.LocalEndpoint.Port } finally { $l.Stop() }
}

function Get-StartupFolder { [Environment]::GetFolderPath('Startup') }

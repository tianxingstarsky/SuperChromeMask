# ============================================================
#  SuperMask - 超级面具  紧急恢复(完全独立, 不依赖主程序)
#  作用: 读取状态文件 → 还原系统时区 → 结束面具浏览器 →
#        删除临时配置文件 → 移除开机守卫 → 清除状态
#  适用: 主程序损坏/目录被删/任何异常残留的最后一道保险
# ============================================================
$ErrorActionPreference = 'Continue'
$stateDir  = Join-Path $env:LOCALAPPDATA 'SuperMask'
$stateFile = Join-Path $stateDir 'session.json'
$guardPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'SuperMaskRestoreGuard.cmd'

Write-Host ''
Write-Host '===== SuperMask 紧急恢复 =====' -ForegroundColor Cyan
Write-Host ''

# 无论有没有状态文件, 都顺手清掉可能残留的守卫
$guardRemoved = $false
if (Test-Path $guardPath) {
    Remove-Item $guardPath -Force -ErrorAction SilentlyContinue
    $guardRemoved = $true
}

if (-not (Test-Path $stateFile)) {
    if ($guardRemoved) { Write-Host '[0/4] 已移除残留的开机还原守卫。' }
    Write-Host '未发现活动会话状态文件 — 系统应已处于默认状态。'
    Write-Host ("当前系统时区: " + (& tzutil.exe /g))
    Read-Host '按回车退出'
    exit 0
}

$s = $null
try { $s = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
if (-not $s -or -not $s.active) {
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host '会话状态为非活动, 已清理状态文件, 无需恢复。'
    Read-Host '按回车退出'
    exit 0
}

# 1. 还原系统时区
if ($s.systemMask.enabled -and $s.systemMask.tzBackup) {
    & tzutil.exe /s $s.systemMask.tzBackup | Out-Null
    Write-Host ('[1/4] 系统时区已还原为默认: ' + $s.systemMask.tzBackup) -ForegroundColor Green
} else {
    Write-Host '[1/4] 未启用系统时区伪装, 跳过'
}

# 2. 结束面具浏览器
if ($s.pid) {
    & taskkill.exe /PID $s.pid /T /F 2>$null | Out-Null
    Write-Host ('[2/4] 已结束面具浏览器进程树 (PID ' + $s.pid + ')') -ForegroundColor Green
} else {
    Write-Host '[2/4] 无浏览器进程记录, 跳过'
}

# 3. 删除临时配置文件(带路径安全校验)
if ($s.profileDir -and -not $s.keepProfile) {
    $safe = $false
    try {
        $full = [IO.Path]::GetFullPath($s.profileDir)
        if ($full -notmatch '\.\.') {
            foreach ($root in @((Join-Path $env:TEMP 'SuperMask'), (Join-Path $env:LOCALAPPDATA 'SuperMask\profiles'))) {
                if ($full.StartsWith([IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) { $safe = $true }
            }
        }
    } catch {}
    if ($safe) {
        if (Test-Path $s.profileDir) {
            Remove-Item -Recurse -Force $s.profileDir -ErrorAction SilentlyContinue
            Write-Host '[3/4] 已删除临时配置文件' -ForegroundColor Green
        } else { Write-Host '[3/4] 临时配置文件已不存在' }
    } else { Write-Host '[3/4] 配置文件路径异常, 出于安全跳过(可手动删除)' -ForegroundColor Yellow }
} else {
    Write-Host '[3/4] 保留模式或无记录, 跳过'
}

# 4. 移除开机守卫 + 清除状态
if ($guardRemoved) { Write-Host '[4/4] 已移除开机还原守卫' -ForegroundColor Green }
else { Write-Host '[4/4] 无开机守卫残留' }
Remove-Item $stateFile -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '全部恢复完成!' -ForegroundColor Green
Write-Host ('当前系统时区: ' + (& tzutil.exe /g))
Write-Host '(浏览器级伪装随浏览器进程消失, 天然无需处理)'
Read-Host '按回车退出'

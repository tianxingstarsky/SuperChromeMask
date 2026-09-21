# ============================================================
#  SuperMask - 超级面具  系统级时区伪装(可选, 默认关闭)
#  这是唯一会修改系统状态的选项, 配套四重闭环:
#    1. 修改前: 备份当前时区并落盘到状态文件
#    2. 停止时: 自动还原备份
#    3. 崩溃/重启: 开机守卫(启动文件夹)自动还原
#    4. 极端情况: 紧急恢复脚本 / 下次启动时自动检测恢复
#  守卫命令使用 -EncodedCommand(纯 ASCII), 与系统代码页无关,
#  且完全自包含 —— 即使本工具目录被删除也能恢复
# ============================================================

function Get-SystemTimezone {
    return (& tzutil.exe /g | Where-Object { $_ } | Select-Object -First 1)
}

function Set-SystemTimezone {
    param([string]$WinTzId)
    $out = & tzutil.exe /s $WinTzId 2>&1
    if ($LASTEXITCODE -ne 0) { throw "tzutil 设置失败: $out" }
}

# 生成"开机自动还原守卫"并写入启动文件夹, 返回守卫文件路径
function New-GuardCommand {
    $restoreScript = @'
$sf  = Join-Path $env:LOCALAPPDATA 'SuperMask\session.json'
$log = Join-Path $env:LOCALAPPDATA 'SuperMask\boot-restore.log'
function L($m){ Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format s),$m) -Encoding UTF8 }
L 'boot guard started'
try {
  if (Test-Path $sf) {
    $s = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($s.active) {
      if ($s.systemMask.enabled -and $s.systemMask.tzBackup) {
        try { & tzutil.exe /s $s.systemMask.tzBackup | Out-Null; L ("timezone restored: " + $s.systemMask.tzBackup) } catch { L ("timezone restore failed: " + $_) }
      }
      if ($s.pid) { try { & taskkill.exe /PID $s.pid /T /F 2>$null | Out-Null; L 'browser process tree killed' } catch {} }
      $prof = $s.profileDir
      if ($prof -and -not $s.keepProfile) {
        $full = [IO.Path]::GetFullPath($prof)
        $roots = @((Join-Path $env:TEMP 'SuperMask'), (Join-Path $env:LOCALAPPDATA 'SuperMask\profiles'))
        foreach ($r in $roots) {
          if ($full.StartsWith([IO.Path]::GetFullPath($r), [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path $full) { try { Remove-Item -Recurse -Force $full -ErrorAction Stop; L 'temp profile removed' } catch { L 'temp profile remove failed (delete manually)' } }
          }
        }
      }
      Remove-Item $sf -Force -ErrorAction SilentlyContinue
      L 'state cleared, restore complete'
    } else { L 'session inactive, nothing to restore' }
  } else { L 'no state file found' }
  $self = Join-Path ([Environment]::GetFolderPath('Startup')) 'SuperMaskRestoreGuard.cmd'
  if (Test-Path $self) { Remove-Item $self -Force -ErrorAction SilentlyContinue; L 'guard self-deleted' }
} catch { L ("guard error: " + $_) }
'@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restoreScript))
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc`r`n"
    $guardPath = Join-Path (Get-StartupFolder) $script:SMGuardName
    [IO.File]::WriteAllText($guardPath, $cmd, [Text.Encoding]::ASCII)
    return $guardPath
}

function Remove-GuardCommand {
    param([string]$GuardPath)
    $removed = $false
    foreach ($p in @($GuardPath, (Join-Path (Get-StartupFolder) $script:SMGuardName))) {
        if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue; $removed = $true }
    }
    if ($removed) { Write-Log '已移除开机自动还原守卫' }
}

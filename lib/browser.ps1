# ============================================================
#  SuperMask - 超级面具  浏览器管理
#  发现浏览器 / 以"临时配置文件 + 运行时参数"启动独立实例 /
#  结束进程树 / 清理
#  关键: --user-data-dir 指向临时目录 → 与真实浏览器完全隔离,
#        互不影响; 所有伪装均通过启动参数与调试协议注入, 不改文件
# ============================================================

function Find-InstalledBrowsers {
    $pf   = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $la   = $env:LOCALAPPDATA
    $candidates = @(
        @{ n = 'Chrome'; p = (Join-Path $pf   'Google\Chrome\Application\chrome.exe') },
        @{ n = 'Chrome'; p = (Join-Path $pf86 'Google\Chrome\Application\chrome.exe') },
        @{ n = 'Chrome'; p = (Join-Path $la   'Google\Chrome\Application\chrome.exe') },
        @{ n = 'Edge';   p = (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe') },
        @{ n = 'Edge';   p = (Join-Path $pf   'Microsoft\Edge\Application\msedge.exe') },
        @{ n = 'Edge';   p = (Join-Path $la   'Microsoft\Edge\Application\msedge.exe') }
    )
    $found = @{}
    foreach ($c in $candidates) {
        if ($c.p -and (Test-Path $c.p)) { $found[$c.p.ToLowerInvariant()] = @{ Name = $c.n; Path = $c.p } }
    }
    # 注册表 App Paths 兜底
    foreach ($rn in @('chrome.exe', 'msedge.exe')) {
        try {
            $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$rn" -ErrorAction SilentlyContinue
            $exe = $ap.'(default)'
            if ($exe -and (Test-Path $exe)) {
                $nm = if ($rn -eq 'chrome.exe') { 'Chrome' } else { 'Edge' }
                $found[$exe.ToLowerInvariant()] = @{ Name = $nm; Path = $exe }
            }
        } catch {}
    }
    # Chrome 优先排序
    return @($found.Values | Sort-Object -Property @{ Expression = { if ($_.Name -eq 'Chrome') { 0 } else { 1 } } }, Path)
}

# 用临时配置文件 + 运行时参数启动被伪装的浏览器, 返回主进程 PID
function Start-MaskedBrowser {
    param([string]$BrowserPath, $Mask, [int]$Port, [string]$ProfileDir,
          [bool]$ProtectWebRTC, [string]$Proxy)
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    $argList = @(
        "--user-data-dir=`"$ProfileDir`"",   # 独立临时配置 → 与真实浏览器隔离, 用完即删
        '--no-first-run',
        '--no-default-browser-check',
        '--hide-crash-restore-bubble',
        '--disable-blink-features=AutomationControlled',
        "--remote-debugging-port=$Port",
        "--lang=$($Mask.lang)"                # 界面语言随伪装地点
    )
    if ($ProtectWebRTC) {
        # 阻止 WebRTC 暴露真实 IP:
        #  - disable_non_proxied_udp: UDP 候选只允许经代理
        #  - STUN over TCP 的直连泄漏由"显式 --proxy-server"解决(见 Start-MaskSession 中的增强逻辑)
        #  - JS 层禁用 RTCPeerConnection(见 cdp.ps1, 确定性拦截)
        $argList += @(
            '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
            '--disable-quic'    # 堵住 QUIC/HTTP3(UDP 443) 直连旁路, HTTP 代理管不住的泄漏点
        )
    }
    if ($Proxy) {
        $argList += @(
            "--proxy-server=`"$Proxy`"",
            '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1'   # DNS 走代理, 防泄漏
        )
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $BrowserPath
    $psi.Arguments = ($argList -join ' ')
    $psi.UseShellExecute = $true
    $p = [Diagnostics.Process]::Start($psi)
    return $p.Id
}

# 结束整个浏览器进程树(临时配置文件随之解锁)
function Stop-MaskedBrowserProcess {
    param([int]$ProcId)
    if ($ProcId -le 0) { return }
    try { & taskkill.exe /PID $ProcId /T /F 2>$null | Out-Null } catch {}
    try { Wait-Process -Id $ProcId -Timeout 10 -ErrorAction SilentlyContinue } catch {}
    # 兜底: 等句柄释放
    Start-Sleep -Milliseconds 500
}

function Test-BrowserAlive {
    param([int]$ProcId, [int]$Port)
    try { if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { return $true } } catch {}
    # 主 PID 结束但进程树仍在的极端情况: 看调试端口是否存活
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 1; return $true } catch {}
    return $false
}

# ============================================================
#  超级面具 SuperMask v1.2.2
#  给浏览器戴上"地理位置面具": 坐标 / 时区 / 语言 / WebRTC 一键伪装
#
#  核心承诺:
#    · 纯运行时注入(调试协议 + 启动参数), 不修改系统文件
#    · 独立临时配置文件, 与真实浏览器完全隔离, 退出即焚
#    · 关闭软件 / 关闭浏览器 / 电脑重启 → 自动恢复默认状态
#    · 可选系统时区伪装配有: 备份 + 停止还原 + 开机守卫 + 紧急恢复
#
#  用法:
#    GUI: 双击 StartSuperMask.bat
#    CLI: powershell -File SuperMask.ps1 -CLI -ListLocations
#         powershell -File SuperMask.ps1 -CLI -Start -Location tokyo
#         powershell -File SuperMask.ps1 -CLI -Status | -Verify | -Stop | -Restore
# ============================================================
param(
    [switch]$CLI, [switch]$Start, [switch]$Stop, [switch]$Status, [switch]$Verify,
    [switch]$Restore, [switch]$ListLocations, [switch]$SelfTest,
    [string]$Location, [string]$CustomLocation,
    [string]$BrowserName, [string]$BrowserPath,
    [switch]$NoWebRTCProtect, [switch]$Hardening,
    [switch]$SyncSystemTimezone, [string]$Proxy, [switch]$NoVerifyPages, [string]$UserAgent
)

$ErrorActionPreference = 'Continue'
$script:Root = $PSScriptRoot
. (Join-Path $script:Root 'lib\common.ps1')
. (Join-Path $script:Root 'lib\locations.ps1')
. (Join-Path $script:Root 'lib\cdp.ps1')
. (Join-Path $script:Root 'lib\browser.ps1')
. (Join-Path $script:Root 'lib\sysmask.ps1')
. (Join-Path $script:Root 'lib\geoip.ps1')

$script:VerifyUrls = @('https://browserleaks.com/geo', 'https://browserleaks.com/webrtc', 'https://browserleaks.com/javascript')
$script:CdpErrLog  = @{}
$script:AutoLocName = '自动 · 同步VPN/代理出口(推荐)'

# ---------------- 地点解析与校验 ----------------
function Resolve-MaskFromPreset {
    param([string]$Id)
    $p = Get-PresetLocation $Id
    if (-not $p) { throw "未知预设地点: $Id (运行 -ListLocations 查看)" }
    return @{
        id = $p.id; name = $p.name; lat = [double]$p.lat; lon = [double]$p.lon
        timezone = $p.tz; winTz = $p.winTz; locale = $p.locale; lang = $p.lang
        accuracy = 30; userAgent = ''; acceptLanguage = ''; hardening = $false
    }
}

function Resolve-MaskCustom {
    param([double]$Lat, [double]$Lon, [string]$Tz, [string]$Locale, [string]$Lang,
          [string]$Name = '自定义地点', [string]$WinTz = '')
    if (-not ($Tz -match '^[A-Za-z]+/[A-Za-z0-9_+\-]+(/[A-Za-z0-9_+\-]+)?$')) {
        throw "IANA 时区格式不正确: $Tz  (示例: Asia/Tokyo)"
    }
    if (-not ($Locale -match '^[a-z]{2,3}(-[A-Z][A-Za-z])?$')) {
        throw "区域 locale 格式不正确: $Locale  (示例: ja-JP / en-US)"
    }
    if (-not $Lang) { $Lang = $Locale }
    if (-not $WinTz) { $WinTz = Convert-IanaToWindowsTz $Tz }
    if (-not $WinTz) { $WinTz = '' }   # 同步系统时区时才必须
    return @{
        id = 'custom'; name = $Name; lat = $Lat; lon = $Lon
        timezone = $Tz; winTz = $WinTz; locale = $Locale; lang = $Lang
        accuracy = 30; userAgent = ''; acceptLanguage = ''; hardening = $false
    }
}

# CLI 自定义格式: "纬度,经度,IANA时区,locale[,界面语言[,显示名]]"
function Resolve-MaskFromCustomString {
    param([string]$Spec)
    $parts = @($Spec -split ',')
    if ($parts.Count -lt 4) { throw '自定义地点格式: 纬度,经度,IANA时区,locale[,语言[,名称]]  例: 35.68,139.65,Asia/Tokyo,ja-JP' }
    $lat = 0.0; $lon = 0.0
    if (-not [double]::TryParse($parts[0], [ref]$lat) -or -not [double]::TryParse($parts[1], [ref]$lon)) {
        throw '纬度/经度必须是数字'
    }
    $lang = if ($parts.Count -ge 5 -and $parts[4]) { $parts[4] } else { '' }
    $name = if ($parts.Count -ge 6 -and $parts[5]) { $parts[5] } else { '自定义地点' }
    return (Resolve-MaskCustom -Lat $lat -Lon $lon -Tz $parts[2].Trim() -Locale $parts[3].Trim() -Lang $lang -Name $name)
}

# ---------------- 会话: 启动(先落盘状态, 再做变更, 保证任何时刻可恢复) ----------------
function Start-MaskSession {
    param($Mask, $Browser, [bool]$WebRTCProtect, [string]$Proxy,
          [bool]$SyncTz, [bool]$HardeningOn, [string]$UserAgentStr, [bool]$OpenVerifyPages)

    $existing = Get-SessionState
    if ($existing -and $existing.active) { throw '已有活动会话在运行, 请先停止(或执行 -Stop / 紧急恢复)' }

    Cleanup-OldTempDirs

    # 1. 配置目录: 永远"退出即焚"临时目录 —— 面具浏览器无登录状态, 每次全新身份
    $profileDir = Join-Path $script:SMTempRoot 'profile_run'
    Remove-ManagedTree $profileDir | Out-Null
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    $port = Get-FreeTcpPort

    # 2. 先把状态写盘(此后任何一步失败/断电都能恢复)
    $fullMask = $Mask.Clone()
    $fullMask.userAgent    = $UserAgentStr
    $fullMask.acceptLanguage = if ($UserAgentStr) { $Mask.locale } else { '' }
    $fullMask.hardening    = $HardeningOn
    $fullMask.webrtcBlock  = $WebRTCProtect
    $fullMask.blockLogin   = $true   # 面具浏览器禁止登录 Google 账号(防账号关联)
    $session = [ordered]@{
        version    = 1; active = $true
        startedUtc = (Get-Date).ToUniversalTime().ToString('s')
        browserName = $Browser.Name; browserPath = $Browser.Path
        pid = 0; port = $port
        profileDir = $profileDir; keepProfile = $false
        location = $fullMask
        systemMask = @{ enabled = $false; tzBackup = ''; appliedTz = '' }
        guardPath = ''
    }
    Save-SessionState $session
    $script:CdpErrLog = @{}

    # 3. 可选: 系统时区伪装 (备份 → 应用 → 安装开机守卫)
    if ($SyncTz) {
        $winTz = $Mask.winTz
        if (-not $winTz -or -not (Test-WindowsTimezoneId $winTz)) {
            if ($Mask.id -eq 'auto') {
                Write-Log "出口时区 $($Mask.timezone) 无对应的 Windows 时区映射, 已跳过系统时区同步(浏览器级伪装不受影响)" 'WARN'
                $SyncTz = $false
            } else {
                throw ("Windows 时区 ID 无效或为空: '$winTz'  (自定义地点请填写 winTz, 可用 tzutil /l 查看)")
            }
        }
    }
    if ($SyncTz) {
        $backupTz = Get-SystemTimezone
        $session.systemMask = @{ enabled = $true; tzBackup = $backupTz; appliedTz = $winTz }
        Save-SessionState $session
        try {
            Set-SystemTimezone $winTz
            Write-Log "系统时区已切换: $backupTz -> $winTz (备份已记录, 停止时自动还原)"
        } catch {
            $session.systemMask.enabled = $false
            Save-SessionState $session
            Write-Log "系统时区切换失败(可能无权限): $_ — 将继续浏览器级伪装" 'WARN'
        }
        if ($session.systemMask.enabled) {
            $session.guardPath = New-GuardCommand
            Save-SessionState $session
            Write-Log '已安装开机自动还原守卫(电脑重启后会自动恢复默认时区并自删除)'
        }
    }

    # 4. 启动浏览器(全部为运行时参数, 不写系统文件)
    # 强制全量走VPN: Chrome 的 WebRTC 会尝试 STUN 直连(不受系统代理约束),
    # QUIC/HTTP3(UDP443) 也是 HTTP 代理管不住的旁路 —— 因此:
    #   a) 给面具浏览器"显式代理"(全部连接强制经VPN, 代理挂=断网, 无静默回退)
    #   b) 优先 SOCKS5(可承载UDP)  c) 禁QUIC  d) JS禁WebRTC
    $effectiveProxy = $Proxy
    if ($WebRTCProtect -and -not $effectiveProxy) {
        $sysProxy = Get-SystemProxy
        if ($sysProxy) {
            $effectiveProxy = Get-NormalizedProxy $sysProxy
            $note = $(if ($effectiveProxy -like 'socks5://*') { 'SOCKS5,可承载UDP' } else { 'HTTP' })
            Write-Log "强制VPN模式: 面具浏览器全量代理 → $effectiveProxy [$note] (网页/DNS/后台全部经VPN, 禁QUIC旁路, 代理断开即断网不回退)"
        } else {
            Write-Log '未检测到系统代理(TUN模式或直连), WebRTC 由处理策略+JS禁用限制(TUN下流量本身经VPN)' 'WARN'
        }
    }
    $session.pid = Start-MaskedBrowser -BrowserPath $Browser.Path -Mask $fullMask -Port $port `
        -ProfileDir $profileDir -ProtectWebRTC $WebRTCProtect -Proxy $effectiveProxy
    Save-SessionState $session
    Write-Log ("浏览器已启动: {0}  PID={1}  调试端口={2}  临时配置: {3}" -f $Browser.Name, $session.pid, $port, $profileDir)

    # 5. 连接调试协议并应用覆写
    try {
        $cdp = Initialize-Cdp $port
    } catch {
        Write-Log "调试接口初始化失败: $_" 'ERROR'
        Stop-MaskSession $session $null
        throw $_
    }
    try { $null = Invoke-Cdp $cdp.Browser 'Target.createTarget' @{ url = 'about:blank' } } catch {}
    $r = Invoke-CdpApplyMask $cdp $fullMask
    if ($r.Count -lt 1) {
        $detail = if ($r.Errors.Count) { $r.Errors[0] } else { '未知原因' }
        Stop-MaskSession $session $cdp
        throw "伪装覆写未能应用到任何页面: $detail"
    }
    Write-Log ("已对 {0} 个页面应用伪装: 坐标({1},{2}) 时区{3} 语言{4}" -f $r.Count, $fullMask.lat, $fullMask.lon, $fullMask.timezone, $fullMask.locale)

    # 6. 出口 IP 核验(面具不改IP, IP由VPN/代理决定; 自动模式还做一致性比对)
    $ipInfo = Get-ExitIpGeo
    if ($ipInfo) {
        if ($fullMask.id -eq 'auto') {
            $tzMatch = ($ipInfo.timezone -eq $fullMask.timezone)
            Write-Log ("出口核验: {0} → {1}, {2} ({3})  时区 {4} {5}" -f `
                $ipInfo.ip, $ipInfo.city, $ipInfo.region, $ipInfo.country, $ipInfo.timezone, `
                $(if ($tzMatch) { '与伪装一致 [OK]' } else { '与伪装不一致, 建议重启面具重新同步 [X]' }))
        } else {
            $tzMatch = ($ipInfo.timezone -eq $fullMask.timezone)
            Write-Log ("当前出口IP: {0}  归属 {1}, {2} ({3})  时区 {4}  — {5}" -f `
                $ipInfo.ip, $ipInfo.city, $ipInfo.region, $ipInfo.country, $ipInfo.timezone, `
                $(if ($tzMatch) { '与伪装地点一致 [OK]' } else { ('与伪装地点(' + $fullMask.timezone + ')不一致, 存在暴露风险, 建议改用「自动同步」 [X]') }))
        }
    } else {
        Write-Log '出口IP探测失败(网络或代理不可用), 跳过一致性核验' 'WARN'
    }

    # 7. 打开验证页面
    if ($OpenVerifyPages) {
        foreach ($u in $script:VerifyUrls) {
            try { $null = Invoke-Cdp $cdp.Browser 'Target.createTarget' @{ url = $u } } catch {}
        }
        Write-Log '已打开验证页面: browserleaks 地理/WebRTC/JS指纹'
    }

    return @{ session = $session; cdp = $cdp; mask = $fullMask }
}

# ---------------- 会话: 停止并恢复默认状态(闭环) ----------------
function Stop-MaskSession {
    param($Session, $Cdp)
    # 1. 断开调试连接(覆写随浏览器进程消失)
    Close-Cdp $Cdp
    # 2. 结束浏览器进程树
    if ($Session.pid -and $Session.pid -gt 0) {
        Write-Log "结束面具浏览器进程树 (PID $($Session.pid))..."
        Stop-MaskedBrowserProcess ([int]$Session.pid)
    }
    # 3. 清理临时配置文件(永远退出即焚, 不留登录状态)
    if (Remove-ManagedTree $Session.profileDir) { Write-Log '临时配置文件已删除, 无任何登录状态残留(真实浏览器配置全程未受影响)' }
    # 4. 还原系统时区
    if ($Session.systemMask -and $Session.systemMask.enabled -and $Session.systemMask.tzBackup) {
        try {
            Set-SystemTimezone $Session.systemMask.tzBackup
            Write-Log "系统时区已还原为默认: $($Session.systemMask.tzBackup)"
        } catch {
            Write-Log "系统时区还原失败: $_  请运行 紧急恢复(EmergencyRestore.bat) 或手动: tzutil /s `"$($Session.systemMask.tzBackup)`"" 'ERROR'
        }
    }
    # 5. 移除开机守卫
    if ($Session.guardPath) { Remove-GuardCommand $Session.guardPath }
    # 6. 清除状态文件 → 恢复闭环完成
    Clear-SessionState
    Write-Log '[完成] 已全部恢复默认状态'
}

# 检测并恢复上次未正常关闭的会话
function Invoke-StaleRecovery {
    $s = Get-SessionState
    if (-not $s -or -not $s.active) { Write-Log '没有发现未恢复的会话, 无需恢复'; return $true }
    Write-Log '发现上次会话未正常关闭, 正在恢复默认状态...' 'WARN'
    return (Stop-MaskSession $s $null)
}

# WebRTC 泄漏探测: 在页面里用多路 STUN 收集 srflx/relay 候选(即公网映射地址),
# 与 VPN 出口 IP 比对 —— 这正是 browserleaks 检测 WebRTC 泄漏的原理
function Invoke-WebRtcLeakCheck {
    param($Conn, [string]$ExitIp)
    $json = Invoke-CdpEval $Conn "(function(){return new Promise(function(res){ try { var ips=[]; var seen={}; var pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'},{urls:'stun:stun.cloudflare.com:3478'},{urls:'stun:stun.qq.com:3478'}]}); pc.createDataChannel('m'); pc.onicecandidate=function(e){ if(e && e.candidate){ var c=e.candidate.candidate||''; if(c.indexOf('typ srflx')>-1||c.indexOf('typ relay')>-1){ var m=c.match(/([0-9]{1,3}(?:\.[0-9]{1,3}){3})/); if(m && !seen[m[1]]){ seen[m[1]]=1; ips.push(m[1]); } } } }; var pp=pc.createOffer().then(function(o){ return pc.setLocalDescription(o); }); setTimeout(function(){ try{pc.close()}catch(e){}; res(JSON.stringify(ips)); }, 6000); } catch(e){ res('[]'); } })})()" -AwaitPromise -TimeoutMs 9500
    $ips = @()
    try { $ips = @((ConvertFrom-Json $json)) } catch {}
    $lines = @()
    if ($ips.Count -eq 0) {
        $lines += 'WebRTC 泄漏检查: 无公网候选(WebRTC已禁用或禁非代理UDP) [OK]'
    } else {
        foreach ($ip in $ips) {
            if ($ExitIp -and $ip -eq $ExitIp) {
                $lines += ("WebRTC 泄漏检查: 公网映射 {0} = VPN出口 [OK]" -f $ip)
            } elseif (-not $ExitIp) {
                $lines += ("WebRTC 泄漏检查: 公网映射 {0}  (出口未知, 请自行比对)" -f $ip)
            } else {
                $lines += ("WebRTC 泄漏检查: 公网映射 {0} ≠ VPN出口 {1} [X] — 疑似泄漏, 检查VPN/代理" -f $ip, $ExitIp)
            }
        }
    }
    return $lines
}

# ---------------- 伪装效果核验(读回浏览器实际看到的值) ----------------
function Invoke-FullVerify {
    param($Cdp, $Mask)
    $lines = @()
    $pages = @($Cdp.Pages.Keys)
    if ($pages.Count -eq 0) { return @('没有已连接的页面 — 请在面具浏览器里打开任意网页后再验证') }
    # 建立页面ID→URL 映射(空源页面如 about:/chrome: 无法使用地理API, 跳过该项)
    $urlById = @{}
    foreach ($t in (Get-CdpPages $Cdp)) { $urlById[[string]$t.id] = [string]$t.url }
    # 出口IP(用于 WebRTC 泄漏比对); 探测失败则仅报告映射地址
    $exitIp = ''
    try { $g = Get-ExitIpGeo; if ($g) { $exitIp = [string]$g.ip } } catch {}
    $checked = 0
    $webrtcDone = $false
    foreach ($tid in $pages) {
        $conn = $Cdp.Pages[$tid]
        if (-not $conn -or $conn.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { continue }
        try {
            $infoJson = Invoke-CdpEval $conn "JSON.stringify({tz:Intl.DateTimeFormat().resolvedOptions().timeZone,off:new Date().getTimezoneOffset(),lang:navigator.language,langs:(navigator.languages||[]).join('|')})"
            $info = $infoJson | ConvertFrom-Json
            $tzOk   = ($info.tz -eq $Mask.timezone)
            $langOk = ($info.lang -eq $Mask.locale)
            $pageUrl = $urlById[$tid]
            $nullOrigin = ($pageUrl -like 'about:*' -or $pageUrl -like 'chrome:*' -or $pageUrl -like 'edge:*')
            $geoOk = $false; $geoLat = 0; $geoLon = 0; $geoNote = ''
            if ($nullOrigin) {
                $geoNote = ' (空源页面跳过)'
            } else {
                $geoJson = Invoke-CdpEval $conn "(function(){return new Promise(function(res){navigator.geolocation.getCurrentPosition(function(p){res(JSON.stringify({lat:p.coords.latitude,lon:p.coords.longitude,acc:p.coords.accuracy}))},function(e){res('ERR_'+e.code)},{timeout:8000,maximumAge:0})})})()" -AwaitPromise -TimeoutMs 11000
                if ($geoJson -and $geoJson -notlike 'ERR_*') {
                    $g = $geoJson | ConvertFrom-Json
                    $geoLat = [double]$g.lat; $geoLon = [double]$g.lon
                    $geoOk = ([math]::Abs($geoLat - [double]$Mask.lat) -lt 0.05 -and [math]::Abs($geoLon - [double]$Mask.lon) -lt 0.05)
                } elseif ($geoJson) { $geoNote = ' (' + $geoJson + ')' }
            }
            $lines += ('页面 {0}:  时区 {1}{2}   语言 {3}{4}   地理API {5}' -f `
                $tid.Substring(0, [math]::Min(8, $tid.Length)), `
                $info.tz,  $(if ($tzOk) { ' [OK]' } else { ' [X]' }), `
                $info.lang, $(if ($langOk) { ' [OK]' } else { ' [X]' }), `
                $(if ($nullOrigin) { '跳过' + $geoNote } else { ('({0}, {1}){2}{3}' -f $geoLat, $geoLon, $(if ($geoOk) { ' [OK]' } else { ' [X]' }), $geoNote) }))
            $checked++
            # WebRTC 泄漏探测(在第一个真实页面上执行一次, 模拟 browserleaks 的检测方式)
            if (-not $webrtcDone -and -not $nullOrigin) {
                $webrtcDone = $true
                try { $lines += (Invoke-WebRtcLeakCheck $conn $exitIp) }
                catch { $lines += ("WebRTC 泄漏检查: 探测失败({0})" -f $_.Exception.Message) }
            }
        } catch { $lines += ("页面 {0} 核验异常: {1}" -f $tid, $_.Exception.Message) }
    }
    $lines += ('期望值: 时区 {0} / 语言 {1} / 坐标 {2}, {3}   — 已核验 {4} 页' -f $Mask.timezone, $Mask.locale, $Mask.lat, $Mask.lon, $checked)
    return $lines
}

function Add-LoggedError {
    param([string]$Key, [string]$Msg)
    if (-not $script:CdpErrLog.ContainsKey($Key)) {
        $script:CdpErrLog[$Key] = $true
        Write-Log $Msg 'WARN'
    }
}

# ============================================================
#  CLI 模式
# ============================================================
if ($CLI -or $ListLocations -or $Start -or $Stop -or $Status -or $Verify -or $Restore -or $SelfTest) {
    if (-not $SelfTest) {
        if ($ListLocations) {
            Write-Host ('{0,-12} {1,-14} {2,10} {3,11}  {4,-20} {5}' -f 'ID', '名称', '纬度', '经度', 'IANA时区', 'locale')
            foreach ($l in $script:Locations) {
                Write-Host ('{0,-12} {1,-14} {2,10} {3,11}  {4,-20} {5}' -f $l.id, $l.name, $l.lat, $l.lon, $l.tz, $l.locale)
            }
            Write-Host ''
            Write-Host '自动同步: -Location auto   (先启动VPN → 读取系统代理探测出口IP → 坐标/时区/语言全自动)'
            Write-Host '自定义:   -CustomLocation "纬度,经度,IANA时区,locale[,语言[,名称]]"'
            exit 0
        }
        if ($Restore) { Invoke-StaleRecovery; exit 0 }
        if ($Status) {
            $s = Get-SessionState
            if (-not $s -or -not $s.active) { Write-Host '没有活动会话 — 系统处于默认状态'; exit 0 }
            Write-Host ('活动会话: {0}  开始于 {1} UTC' -f $s.location.name, $s.startedUtc)
            Write-Host ('  浏览器: {0}  PID={1}  调试端口={2}' -f $s.browserName, $s.pid, $s.port)
            Write-Host ('  伪装: 坐标({0},{1}) 时区{2} locale {3}' -f $s.location.lat, $s.location.lon, $s.location.timezone, $s.location.locale)
            Write-Host ('  临时配置: {0}  (退出即焚)' -f $s.profileDir)
            Write-Host ('  系统时区伪装: {0}{1}' -f $(if ($s.systemMask.enabled) { '开启, 备份=' + $s.systemMask.tzBackup } else { '关闭' }), `
                $(if ($s.guardPath) { ', 开机守卫已安装' } else { '' }))
            exit 0
        }
        if ($Stop) {
            $s = Get-SessionState
            if (-not $s -or -not $s.active) { Write-Host '没有活动会话'; exit 0 }
            Stop-MaskSession $s $null
            exit 0
        }
        if ($Verify) {
            $s = Get-SessionState
            if (-not $s -or -not $s.active) { Write-Host '没有活动会话, 请先 -Start'; exit 1 }
            $cdp = Initialize-Cdp ([int]$s.port)
            $null = Invoke-CdpApplyMask $cdp $s.location
            Invoke-FullVerify $cdp $s.location | ForEach-Object { Write-Host $_ }
            Close-Cdp $cdp
            exit 0
        }
        # -Start
        $stale = Get-SessionState
        if ($stale -and $stale.active) {
            Write-Host '检测到上次会话未正常关闭, 先自动恢复...' -ForegroundColor Yellow
            Invoke-StaleRecovery
        }
        if ($CustomLocation) { $mask = Resolve-MaskFromCustomString $CustomLocation }
        elseif ($Location -eq 'auto') {
            Write-Host '正在读取系统代理并探测 VPN/代理出口位置...'
            $geo = Get-ExitIpGeo
            if (-not $geo) {
                Write-Host '出口IP探测失败: 请确认 VPN/代理已启动且系统代理可达, 或改用 -Location <预设ID> 手动指定' -ForegroundColor Red
                exit 1
            }
            $mask = Resolve-MaskFromGeo $geo
            Write-Host ("出口: {0} → {1}, {2} ({3})  时区 {4}  [经{5}探测]" -f $geo.ip, $geo.city, $geo.region, $geo.country, $geo.timezone, $geo.via) -ForegroundColor Cyan
            Write-Host ("同步面具: 坐标({0},{1})  时区 {2}  语言 {3}" -f $mask.lat, $mask.lon, $mask.timezone, $mask.locale) -ForegroundColor Cyan
        }
        elseif ($Location)   { $mask = Resolve-MaskFromPreset $Location }
        else { Write-Host '请指定 -Location auto / -Location <预设ID> 或 -CustomLocation "..." (-ListLocations 查看)'; exit 1 }

        $browsers = Find-InstalledBrowsers
        $browser = $null
        if ($BrowserPath) { $browser = @{ Name = '自定义'; Path = $BrowserPath } }
        elseif ($BrowserName) {
            foreach ($b in $browsers) { if ($b.Name -ieq $BrowserName) { $browser = $b; break } }
            if (-not $browser) { Write-Host "未找到浏览器: $BrowserName"; exit 1 }
        } else {
            if ($browsers.Count -eq 0) { Write-Host '未找到 Chrome/Edge, 请用 -BrowserPath 指定浏览器路径'; exit 1 }
            $browser = $browsers[0]
        }
        $run = Start-MaskSession -Mask $mask -Browser $browser `
            -WebRTCProtect (-not $NoWebRTCProtect) -Proxy $Proxy `
            -SyncTz ($SyncSystemTimezone) -HardeningOn ($Hardening) -UserAgentStr $UserAgent `
            -OpenVerifyPages (-not $NoVerifyPages)
        Write-Host ''
        Write-Host ('面具运行中: {0} — 关闭浏览器窗口或按 Ctrl+C 结束并自动恢复' -f $mask.name) -ForegroundColor Green
        try {
            while ($true) {
                Start-Sleep -Seconds 2
                if (-not (Test-BrowserAlive ([int]$run.session.pid) ([int]$run.session.port))) {
                    Write-Log '检测到浏览器已关闭'
                    break
                }
                $r = Invoke-CdpApplyMask $run.cdp $run.mask
                foreach ($e in $r.Errors) { Add-LoggedError ('cycle:' + $e) $e }
            }
        } finally {
            Write-Log '正在恢复默认状态...'
            Stop-MaskSession $run.session $run.cdp
        }
        exit 0
    }
    # -SelfTest: 自检(不做任何系统变更)
    Write-Host '=== SuperMask 自检 ==='
    $browsers = Find-InstalledBrowsers
    foreach ($b in $browsers) { Write-Host ("[OK] 发现浏览器 {0}: {1}" -f $b.Name, $b.Path) }
    if ($browsers.Count -eq 0) { Write-Host '[X] 未找到浏览器' -ForegroundColor Red }
    $m1 = Resolve-MaskFromPreset 'tokyo'
    Write-Host ("[OK] 预设解析: {0} ({1},{2}) {3} / {4}" -f $m1.name, $m1.lat, $m1.lon, $m1.timezone, $m1.locale)
    $m2 = Resolve-MaskFromCustomString '31.23,121.47,Asia/Shanghai,zh-CN,zh-CN,上海'
    Write-Host ("[OK] 自定义解析: {0} winTz={1}" -f $m2.name, $m2.winTz)
    $p = Get-FreeTcpPort
    Write-Host ("[OK] 空闲端口: {0}" -f $p)
    $tz = Get-SystemTimezone
    Write-Host ("[OK] 当前系统时区: {0}" -f $tz)
    Write-Host ("[OK] Windows时区校验(tzutil /l): {0}" -f (Test-WindowsTimezoneId $tz))
    $sysProxy = Get-SystemProxy
    Write-Host ("[OK] 系统代理: {0}" -f $(if ($sysProxy) { $sysProxy } else { '未设置(将直连探测出口)' }))
    $fakeGeo = @{ ip='1.2.3.4'; city='Los Angeles'; region='California'; country='US'; lat=34.05; lon=-118.24; timezone='America/Los_Angeles' }
    $m3 = Resolve-MaskFromGeo $fakeGeo
    Write-Host ("[OK] 出口同步解析: {0} ({1},{2}) {3} / {4} winTz={5}" -f $m3.name, $m3.lat, $m3.lon, $m3.timezone, $m3.locale, $m3.winTz)
    $sf = Get-SessionState
    Write-Host ("[OK] 状态文件读取: {0}" -f $(if ($sf) { '存在' } else { '不存在(正常)' }))
    Write-Host ("[OK] 路径安全检查(应False): {0}" -f (Test-SafeManagedPath 'C:\Windows\System32'))
    Write-Host ("[OK] 路径安全检查(应True):  {0}" -f (Test-SafeManagedPath (Join-Path $script:SMTempRoot 'profile_run')))
    Write-Host '=== 自检完成 ==='
    exit 0
}

# ============================================================
#  GUI 模式 (默认)
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-HelpText {
    return @'
【超级面具 — 快速上手】

1. 先启动 VPN/代理(等待其就绪), 再打开本工具
2. 选择伪装地点:
   · 自动·同步VPN/代理出口(推荐): 读取系统代理探测出口IP,
     坐标/时区/语言全自动与出口保持一致, 零破绽
   · 城市预设 / 自定义: 手动指定任意地点
3. 选择浏览器(Chrome/Edge), 点「启动面具」
4. 在弹出的面具浏览器中正常上网 — 网站看到的是伪装位置
5. 用完后点「停止并恢复」, 或直接关掉浏览器窗口(自动恢复)

【它伪装了什么】
· GPS 地理坐标   navigator.geolocation 返回伪装地点(免授权弹窗)
· 时区           Intl/Date 返回伪装时区(网站查时区=IP不符的主要手段)
· 语言/区域      navigator.language(s) / Intl / Accept-Language
· 强制VPN模式    面具浏览器全量流量走代理: 自动探测SOCKS5(可承载
                 UDP)优先, 禁QUIC/HTTP3旁路, JS禁WebRTC, DNS随代理;
                 代理断开即断网不静默回退 → 不留任何直连泄漏
· (实验)指纹加固 JS 兜底时区语言 + Canvas 噪声

【自动同步原理】
读取系统代理(Clash/V2rayN等的"系统代理"均写入注册表) →
经代理查询出口IP地理位置(ipinfo/ip-api双源) →
按出口城市坐标+时区+国家语言生成面具; TUN模式VPN则直连探测
切换VPN节点后请重启面具以重新同步

【恢复保证】
· 浏览器级伪装: 浏览器一关即消失, 不写任何文件, 重启自然清零
· 临时配置文件: 退出即焚, 与真实浏览器完全隔离, 无登录状态
· 登录屏蔽       面具浏览器禁止登录 Google 账号(防账号关联泄露身份)
· 系统时区(默认关): 停止时自动还原; 重启有开机守卫自动还原;
  实在不行还有 EmergencyRestore.bat 一键紧急恢复

【注意事项】
· 面具浏览器默认走系统代理/VPN出口; 代理框留空即可,
  填写则强制面具浏览器走指定代理
· 仅供隐私保护/测试学习使用, 请遵守当地法律与网站条款
'@
}

# ---------- 窗体与控件 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '超级面具 SuperMask v1.2.2 — 浏览器地理伪装 · 用完即恢复'
$form.ClientSize = New-Object System.Drawing.Size(600, 768)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function New-Label { param([string]$Text, [int]$X, [int]$Y, [int]$W = 90)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, 20)
    return $l
}
function New-TextBox { param([int]$X, [int]$Y, [int]$W)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y); $t.Size = New-Object System.Drawing.Size($W, 22)
    return $t
}

# --- 地点 ---
$grpLocation = New-Object System.Windows.Forms.GroupBox
$grpLocation.Text = '伪装地点'; $grpLocation.Location = New-Object System.Drawing.Point(10, 10)
$grpLocation.Size = New-Object System.Drawing.Size(580, 152)
$form.Controls.Add($grpLocation)
$grpLocation.Controls.Add((New-Label '伪装地点:' 15 28))
$cmbLocation = New-Object System.Windows.Forms.ComboBox
$cmbLocation.Location = New-Object System.Drawing.Point(90, 25); $cmbLocation.Size = New-Object System.Drawing.Size(240, 22)
$cmbLocation.DropDownStyle = 'DropDownList'
[void]$cmbLocation.Items.Add($script:AutoLocName)
foreach ($l in $script:Locations) { [void]$cmbLocation.Items.Add($l.name) }
[void]$cmbLocation.Items.Add('自定义…')
$grpLocation.Controls.Add($cmbLocation)
$lblLocHint = New-Label '预设一键伪装' 345 28 220
$grpLocation.Controls.Add($lblLocHint)

$grpLocation.Controls.Add((New-Label '纬度' 15 62 40))
$tbLat = New-TextBox 55 59 75;  $grpLocation.Controls.Add($tbLat)
$grpLocation.Controls.Add((New-Label '经度' 145 62 40))
$tbLon = New-TextBox 185 59 75; $grpLocation.Controls.Add($tbLon)
$grpLocation.Controls.Add((New-Label 'IANA 时区' 270 62 62))
$tbTz = New-TextBox 335 59 115; $grpLocation.Controls.Add($tbTz)
$grpLocation.Controls.Add((New-Label '(如 Asia/Tokyo)' 455 62 115))
$grpLocation.Controls.Add((New-Label '区域 locale' 15 102 70))
$tbLocale = New-TextBox 90 99 70;  $grpLocation.Controls.Add($tbLocale)
$grpLocation.Controls.Add((New-Label '界面语言' 175 102 55))
$tbLang = New-TextBox 232 99 55;  $grpLocation.Controls.Add($tbLang)
$grpLocation.Controls.Add((New-Label 'Win时区ID' 300 102 62))
$tbWinTz = New-TextBox 365 99 130; $grpLocation.Controls.Add($tbWinTz)
$grpLocation.Controls.Add((New-Label '同步系统时区时用,可留空' 498 102 80))

# --- 浏览器 ---
$grpBrowser = New-Object System.Windows.Forms.GroupBox
$grpBrowser.Text = '浏览器'; $grpBrowser.Location = New-Object System.Drawing.Point(10, 170)
$grpBrowser.Size = New-Object System.Drawing.Size(580, 64)
$form.Controls.Add($grpBrowser)
$grpBrowser.Controls.Add((New-Label '浏览器:' 15 28))
$cmbBrowser = New-Object System.Windows.Forms.ComboBox
$cmbBrowser.Location = New-Object System.Drawing.Point(75, 25); $cmbBrowser.Size = New-Object System.Drawing.Size(385, 22)
$cmbBrowser.DropDownStyle = 'DropDownList'
$grpBrowser.Controls.Add($cmbBrowser)
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新'; $btnRefresh.Location = New-Object System.Drawing.Point(470, 23); $btnRefresh.Size = New-Object System.Drawing.Size(90, 26)
$grpBrowser.Controls.Add($btnRefresh)

# --- 选项 ---
$grpOptions = New-Object System.Windows.Forms.GroupBox
$grpOptions.Text = '伪装选项'; $grpOptions.Location = New-Object System.Drawing.Point(10, 242)
$grpOptions.Size = New-Object System.Drawing.Size(580, 152)
$form.Controls.Add($grpOptions)
function New-CheckBox { param([string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Checked)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, 22); $c.Checked = $Checked
    return $c
}
$ckWebRTC     = New-CheckBox '强制VPN模式: Chrome全量流量走代理(SOCKS5优先) + 禁WebRTC/QUIC(推荐; 网页通话不可用)' 15 24 550 $true
$ckHardening  = New-CheckBox '指纹加固(实验): JS 兜底时区/语言 + Canvas 噪声' 15 48 550 $false
$ckKeep       = $null  # 登录功能已移除: 面具浏览器禁止登录, 配置永远退出即焚
$ckSyncTz     = New-CheckBox '同步伪装系统时区(默认关; 停止自动还原 + 重启开机守卫)' 15 96 550 $false
$ckOpenVerify = New-CheckBox '启动后自动打开验证页面(browserleaks)' 15 120 280 $true
$grpOptions.Controls.AddRange(@($ckWebRTC, $ckHardening, $ckSyncTz, $ckOpenVerify))
$grpOptions.Controls.Add((New-Label '代理(可选):' 310 122 65))
$tbProxy = New-TextBox 378 119 185
$tbProxy.MaxLength = 120
$grpOptions.Controls.Add($tbProxy)

# --- 运行控制 ---
$grpRun = New-Object System.Windows.Forms.GroupBox
$grpRun.Text = '运行'; $grpRun.Location = New-Object System.Drawing.Point(10, 402)
$grpRun.Size = New-Object System.Drawing.Size(580, 68)
$form.Controls.Add($grpRun)
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '▶ 启动面具'; $btnStart.Location = New-Object System.Drawing.Point(15, 24); $btnStart.Size = New-Object System.Drawing.Size(130, 34)
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '■ 停止并恢复'; $btnStop.Location = New-Object System.Drawing.Point(155, 24); $btnStop.Size = New-Object System.Drawing.Size(130, 34)
$btnStop.Enabled = $false
$btnVerify = New-Object System.Windows.Forms.Button
$btnVerify.Text = '✓ 验证伪装'; $btnVerify.Location = New-Object System.Drawing.Point(295, 24); $btnVerify.Size = New-Object System.Drawing.Size(130, 34)
$btnVerify.Enabled = $false
$btnHelp = New-Object System.Windows.Forms.Button
$btnHelp.Text = '使用说明'; $btnHelp.Location = New-Object System.Drawing.Point(435, 24); $btnHelp.Size = New-Object System.Drawing.Size(125, 34)
$grpRun.Controls.AddRange(@($btnStart, $btnStop, $btnVerify, $btnHelp))

# --- 状态 ---
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = '状态'; $grpStatus.Location = New-Object System.Drawing.Point(10, 478)
$grpStatus.Size = New-Object System.Drawing.Size(580, 58)
$form.Controls.Add($grpStatus)
$lblState = New-Label '未运行 — 选择地点后点「启动面具」' 15 24 545
$grpStatus.Controls.Add($lblState)

# --- 日志 ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = '日志'; $grpLog.Location = New-Object System.Drawing.Point(10, 544)
$grpLog.Size = New-Object System.Drawing.Size(580, 216)
$form.Controls.Add($grpLog)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.Location = New-Object System.Drawing.Point(10, 20); $txtLog.Size = New-Object System.Drawing.Size(560, 184)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$grpLog.Controls.Add($txtLog)

# ---------- 运行状态与逻辑 ----------
$script:Run = $null
$script:Sw  = $null
$script:browserList = @()

Set-LogSink {
    param($Line, $Level)
    if ($txtLog.IsHandleCreated -or $txtLog.Handle) {
        $txtLog.AppendText($Line + [Environment]::NewLine)
    } else { Write-Host $Line }
}

$runControls = @($cmbLocation, $tbLat, $tbLon, $tbTz, $tbLocale, $tbLang, $tbWinTz,
    $cmbBrowser, $btnRefresh, $ckWebRTC, $ckHardening, $ckSyncTz, $ckOpenVerify, $tbProxy)
function Set-RunState {
    param([bool]$Running)
    foreach ($c in $runControls) { $c.Enabled = -not $Running }
    $btnStart.Enabled = -not $Running
    $btnStop.Enabled  = $Running
    $btnVerify.Enabled = $Running
    if ($Running) { $script:Sw = [Diagnostics.Stopwatch]::StartNew() }
}

function Invoke-Teardown {
    if (-not $script:Run) { return }
    $r = $script:Run
    $script:Run = $null
    try { Stop-MaskSession $r.session $r.cdp }
    catch { Write-Log "恢复过程异常: $_" 'ERROR' }
    Set-RunState $false
    $lblState.Text = '未运行 — 已恢复默认状态'
}

function Update-CustomFields {
    if ($cmbLocation.Text -eq $script:AutoLocName) {
        foreach ($t in @($tbLat, $tbLon, $tbTz, $tbLocale, $tbLang, $tbWinTz)) { $t.Text = '' }
        $lblLocHint.Text = '先启动VPN → 启动时自动探测出口并同步(见日志)'
    } elseif ($cmbLocation.Text -eq '自定义…') {
        foreach ($t in @($tbLat, $tbLon, $tbTz, $tbLocale, $tbLang, $tbWinTz)) {
            if ([string]::IsNullOrWhiteSpace($t.Text)) { $t.Text = '' }
        }
        $lblLocHint.Text = '填写坐标/时区/locale (界面语言与Win时区可留空)'
    } else {
        foreach ($l in $script:Locations) {
            if ($l.name -eq $cmbLocation.Text) {
                $tbLat.Text = [string]$l.lat; $tbLon.Text = [string]$l.lon
                $tbTz.Text = $l.tz; $tbLocale.Text = $l.locale
                $tbLang.Text = $l.lang; $tbWinTz.Text = $l.winTz
                break
            }
        }
        $lblLocHint.Text = '预设一键伪装(自定义可改)'
    }
}

function Get-MaskFromUi {
    if ($cmbLocation.Text -eq $script:AutoLocName) {
        Write-Log '正在读取系统代理并探测 VPN/代理出口位置...'
        $geo = Get-ExitIpGeo
        if (-not $geo) {
            throw '出口IP探测失败: 请确认 VPN/代理已启动且系统代理可达, 或改用手动地点'
        }
        $mask = Resolve-MaskFromGeo $geo
        # 把探测结果显示到自定义栏, 用户可见即将生效的参数
        $tbLat.Text = [string]$mask.lat; $tbLon.Text = [string]$mask.lon
        $tbTz.Text = $mask.timezone;   $tbLocale.Text = $mask.locale
        $tbLang.Text = $mask.lang;     $tbWinTz.Text = [string]$mask.winTz
        Write-Log ("出口[{0}]: {1} → {2}, {3} ({4})  坐标({5},{6})" -f $geo.via, $geo.ip, $geo.city, $geo.region, $geo.country, $mask.lat, $mask.lon)
        Write-Log ("已同步面具: 时区 {0}  语言 {1}  (与出口IP完全一致)" -f $mask.timezone, $mask.locale)
        return $mask
    }
    if ($cmbLocation.Text -eq '自定义…') {
        $lat = 0.0; $lon = 0.0
        if (-not [double]::TryParse($tbLat.Text.Trim(), [ref]$lat) -or -not [double]::TryParse($tbLon.Text.Trim(), [ref]$lon)) {
            throw '自定义地点: 纬度/经度必须是数字'
        }
        $mask = Resolve-MaskCustom -Lat $lat -Lon $lon -Tz $tbTz.Text.Trim() -Locale $tbLocale.Text.Trim() `
            -Lang $tbLang.Text.Trim() -Name '自定义地点' -WinTz $tbWinTz.Text.Trim()
    } else {
        foreach ($l in $script:Locations) {
            if ($l.name -eq $cmbLocation.Text) { return (Resolve-MaskFromPreset $l.id) }
        }
        throw '请选择伪装地点'
    }
    return $mask
}

function Refresh-BrowserList {
    $script:browserList = Find-InstalledBrowsers
    $cmbBrowser.Items.Clear()
    foreach ($b in $script:browserList) { [void]$cmbBrowser.Items.Add(('{0} — {1}' -f $b.Name, $b.Path)) }
    if ($script:browserList.Count -gt 0) { $cmbBrowser.SelectedIndex = 0 }
    if ($script:browserList.Count -eq 0) { Write-Log '未找到 Chrome/Edge 浏览器' 'WARN' }
}

# ---------- 事件 ----------
$cmbLocation.Add_SelectedIndexChanged({ Update-CustomFields })
$btnRefresh.Add_Click({ Refresh-BrowserList })

$btnStart.Add_Click({
    if ($script:Run) { return }
    $cursor = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $mask = Get-MaskFromUi
        if ($script:browserList.Count -eq 0) { throw '未检测到浏览器, 请先「刷新」' }
        $browser = $script:browserList[$cmbBrowser.SelectedIndex]
        if (-not $browser) { throw '请选择浏览器' }
        if ($ckSyncTz.Checked -and $mask.id -ne 'auto' -and [string]::IsNullOrWhiteSpace($mask.winTz)) {
            throw '同步系统时区需要有效的 Windows 时区 ID(预设自动带; 自定义地点请填写 Win时区ID 或留空关闭该选项)'
        }
        Write-Log ('正在启动面具: {0} → {1}' -f $mask.name, $browser.Name)
        $script:Run = Start-MaskSession -Mask $mask -Browser $browser `
            -WebRTCProtect $ckWebRTC.Checked -Proxy $tbProxy.Text.Trim() `
            -SyncTz $ckSyncTz.Checked -HardeningOn $ckHardening.Checked -UserAgentStr '' `
            -OpenVerifyPages $ckOpenVerify.Checked
        Set-RunState $true
        $lblState.Text = ('运行中 · {0} · {1} · PID {2}' -f $mask.name, $browser.Name, $script:Run.session.pid)
        # 记住偏好
        try {
            Save-AppConfig @{ lastLocation = $cmbLocation.Text; lastBrowser = $cmbBrowser.Text;
                webrtc = $ckWebRTC.Checked; hardening = $ckHardening.Checked;
                syncTz = $ckSyncTz.Checked; openVerify = $ckOpenVerify.Checked; proxy = $tbProxy.Text }
        } catch {}
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, "启动失败: $_", '超级面具',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        Write-Log "启动失败: $_" 'ERROR'
        if ($script:Run) { Invoke-Teardown } else { Set-RunState $false }
    } finally { [System.Windows.Forms.Cursor]::Current = $cursor }
})

$btnStop.Add_Click({ Invoke-Teardown })

$btnVerify.Add_Click({
    if (-not $script:Run) { return }
    try {
        $lines = Invoke-FullVerify $script:Run.cdp $script:Run.mask
        foreach ($l in $lines) { Write-Log $l }
        $bad = @($lines | Where-Object { $_ -like '*[X]*' })
        $msg = if ($bad.Count -eq 0 -and $lines.Count -gt 1) { '伪装核验通过: 时区/语言/地理API 均已生效' }
               else { '部分项未生效, 请查看日志(可能页面尚未加载完成)' }
        [void][System.Windows.Forms.MessageBox]::Show($form, $msg, '验证结果',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $(if ($bad.Count) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }))
    } catch { Write-Log "验证异常: $_" 'ERROR' }
})

$btnHelp.Add_Click({
    $hf = New-Object System.Windows.Forms.Form
    $hf.Text = '使用说明'; $hf.ClientSize = New-Object System.Drawing.Size(620, 520)
    $hf.StartPosition = 'CenterScreen'
    $ht = New-Object System.Windows.Forms.TextBox
    $ht.Multiline = $true; $ht.ReadOnly = $true; $ht.ScrollBars = 'Vertical'
    $ht.Dock = 'Fill'; $ht.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $ht.Text = Get-HelpText
    $hf.Controls.Add($ht)
    [void]$hf.ShowDialog($form)
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    if (-not $script:Run) { return }
    try {
        $r = $script:Run
        if (-not (Test-BrowserAlive ([int]$r.session.pid) ([int]$r.session.port))) {
            Write-Log '检测到面具浏览器已关闭, 自动恢复默认状态...'
            Invoke-Teardown
            return
        }
        $res = Invoke-CdpApplyMask $r.cdp $r.mask
        foreach ($e in $res.Errors) { Add-LoggedError ('cycle:' + $e) $e }
        $dur = if ($script:Sw) { '{0:mm\:ss}' -f $script:Sw.Elapsed } else { '--:--' }
        $lblState.Text = ('运行中 · {0} · 已覆写 {1} 页 · 已运行 {2}' -f $r.mask.name, $res.Count, $dur)
    } catch { Write-Log "轮询异常: $_" 'WARN' }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Run) {
        $ans = [System.Windows.Forms.MessageBox]::Show($form,
            '面具正在运行。关闭窗口将停止伪装并恢复默认状态(会关闭面具浏览器), 确认?',
            '超级面具', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ans -eq [System.Windows.Forms.DialogResult]::No) { $e.Cancel = $true; return }
        Invoke-Teardown
    }
    $timer.Stop()
})

# ---------- 初始化 ----------
Refresh-BrowserList
$cmbLocation.SelectedIndex = 0
try {
    $cfg = Get-AppConfig
    if ($cfg) {
        if ($cfg.lastLocation) {
            $idx = $cmbLocation.Items.IndexOf($cfg.lastLocation)
            if ($idx -ge 0) { $cmbLocation.SelectedIndex = $idx }
        }
        if ($cfg.lastBrowser) {
            $idx = $cmbBrowser.Items.IndexOf($cfg.lastBrowser)
            if ($idx -ge 0) { $cmbBrowser.SelectedIndex = $idx }
        }
        if ($null -ne $cfg.webrtc)     { $ckWebRTC.Checked     = [bool]$cfg.webrtc }
        if ($null -ne $cfg.hardening)  { $ckHardening.Checked  = [bool]$cfg.hardening }

        if ($null -ne $cfg.syncTz)     { $ckSyncTz.Checked     = [bool]$cfg.syncTz }
        if ($null -ne $cfg.openVerify) { $ckOpenVerify.Checked = [bool]$cfg.openVerify }
        if ($cfg.proxy)                { $tbProxy.Text         = [string]$cfg.proxy }
    }
} catch {}
Update-CustomFields
Cleanup-OldTempDirs

# 启动时检测上次未恢复的会话
$stale = Get-SessionState
if ($stale -and $stale.active) {
    Write-Log '检测到上次会话未正常关闭(可能经历过崩溃/断电), 需要恢复默认状态' 'WARN'
    $ans = [System.Windows.Forms.MessageBox]::Show($form,
        "检测到上次面具会话未正常关闭。`n如系统时区被修改过, 现在将自动还原并清理(可能关闭残留的面具浏览器)。`n`n立即恢复?", '超级面具 - 恢复',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-StaleRecovery }
}

Write-Log '超级面具就绪: 选择地点 → 启动面具。一切伪装仅在运行时生效, 关闭即恢复。'
[void][System.Windows.Forms.Application]::Run($form)

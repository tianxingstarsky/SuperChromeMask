# ============================================================
#  SuperMask - 超级面具  CDP 客户端 (纯标准库 WebSocket, 零依赖)
#  通过 Chrome DevTools 协议在运行时注入:
#    - Emulation.setGeolocationOverride  地理坐标(GPS)
#    - Emulation.setTimezoneOverride     时区
#    - Emulation.setLocaleOverride       语言/区域
#    - Network.setUserAgentOverride      UA/Accept-Language(可选)
#    - Browser.grantPermissions          自动授予地理定位权限(免弹窗)
#  一切均为会话级覆写: 浏览器关闭即消失, 不写任何文件
# ============================================================

# ---------------- WebSocket / CDP 基础 ----------------
function New-CdpConnection {
    param([string]$Url)
    try {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        # 注意: PS5.1 中链式异步调用会把 VoidTaskResult 泄漏到管道, 必须 $null = 抑制
        $null = $ws.ConnectAsync([Uri]$Url, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        return [pscustomobject]@{ Socket = $ws; NextId = 0 }
    } catch { return $null }
}

function Close-CdpConnection {
    param($Conn)
    try { if ($Conn -and $Conn.Socket) { $Conn.Socket.Abort() } } catch {}
}

function Invoke-Cdp {
    param($Conn, [string]$Method, $Params, [int]$TimeoutMs = 4000)
    if (-not $Conn -or $Conn.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw 'CDP 连接已关闭'
    }
    $Conn.NextId++
    $id = $Conn.NextId
    $payload = [ordered]@{ id = $id; method = $Method }
    if ($null -ne $Params) { $payload['params'] = $Params }
    $json = ConvertTo-Json $payload -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $null = $Conn.Socket.SendAsync([ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $buf = [byte[]]::new(65536)
    while ($true) {
        $msg = [System.Collections.Generic.List[byte]]::new()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ($true) {   # 收一条完整消息(可能分片)
            $remain = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remain -lt 1) { $Conn.Socket.Abort(); throw "CDP 超时: $Method" }
            $task = $Conn.Socket.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
            if (-not $task.Wait($remain)) { $Conn.Socket.Abort(); throw "CDP 超时: $Method" }
            $res = $task.Result
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                $Conn.Socket.Abort(); throw 'CDP 连接被浏览器关闭'
            }
            for ($i = 0; $i -lt $res.Count; $i++) { $msg.Add($buf[$i]) }
            if ($res.EndOfMessage) { break }
        }
        $text = [Text.Encoding]::UTF8.GetString($msg.ToArray(), 0, $msg.Count)
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { continue }
        if ($obj -and $obj.PSObject.Properties['id'] -and [int]$obj.id -eq $id) {
            if ($obj.PSObject.Properties['error'] -and $obj.error) {
                throw ('CDP 错误({0}): {1}' -f $Method, ($obj.error | ConvertTo-Json -Compress))
            }
            return $obj
        }
        # 其它 id / 事件消息 → 忽略, 继续等待本命令的响应
    }
}

function Invoke-CdpEval {
    param($Conn, [string]$Expression, [switch]$AwaitPromise, [int]$TimeoutMs = 5000)
    $p = @{ expression = $Expression; returnByValue = $true }
    if ($AwaitPromise) { $p.awaitPromise = $true }
    $r = Invoke-Cdp $Conn 'Runtime.evaluate' $p -TimeoutMs $TimeoutMs
    if ($r.result -and $r.result.exceptionDetails) { return $null }
    if ($r.result -and $r.result.result) { return $r.result.result.value }
    return $null
}

# ---------------- 浏览器级会话管理 ----------------
function Initialize-Cdp {
    param([int]$Port)
    $ver = $null
    for ($i = 0; $i -lt 50; $i++) {
        try { $ver = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; break }
        catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $ver) { throw '浏览器调试端口 15 秒内未就绪(浏览器可能被策略禁止调试)' }
    $browser = New-CdpConnection $ver.webSocketDebuggerUrl
    if (-not $browser) { throw '无法连接浏览器调试接口(WebSocket)' }
    # 全局授予 geolocation 权限 → 页面请求定位时不再弹窗, 直接返回伪装坐标
    try { Invoke-Cdp $browser 'Browser.grantPermissions' @{ permissions = @('geolocation') } | Out-Null }
    catch { Write-Log "授予地理定位权限失败: $_" 'WARN' }
    return [pscustomobject]@{ Port = $Port; Browser = $browser; Pages = @{}; Applied = @{}; UserAgent = $ver.'User-Agent' }
}

function Close-Cdp {
    param($Cdp)
    if (-not $Cdp) { return }
    try {
        foreach ($k in @($Cdp.Pages.Keys)) { Close-CdpConnection $Cdp.Pages[$k] }
        $Cdp.Pages.Clear(); $Cdp.Applied.Clear()
        Close-CdpConnection $Cdp.Browser
    } catch {}
}

function Get-CdpPages {
    param($Cdp)
    try {
        return @((Invoke-RestMethod -Uri "http://127.0.0.1:$($Cdp.Port)/json/list" -TimeoutSec 3) |
            Where-Object { $_.type -eq 'page' -and $_.url -notlike 'devtools:*' })
    } catch { return @() }
}

# ---------------- 指纹加固脚本(实验, 可选) ----------------
function New-HardeningScript {
    param($Mask, [double]$OffsetMinutes)
    $localesJson = ConvertTo-Json @($Mask.locale) -Compress
    return @"
(function () {
  if (window.__supermask__) return; window.__supermask__ = 1;
  var TZ = '$($Mask.timezone)', OFF = $OffsetMinutes, LOC = $localesJson;
  try { var _ro = Intl.DateTimeFormat.prototype.resolvedOptions;
        Intl.DateTimeFormat.prototype.resolvedOptions = function () {
          var o = _ro.call(this); o.timeZone = TZ; return o; }; } catch (e) {}
  try { Date.prototype.getTimezoneOffset = function () { return OFF; }; } catch (e) {}
  try { Object.defineProperty(navigator, 'language',  { get: function () { return LOC[0]; }, configurable: true });
        Object.defineProperty(navigator, 'languages', { get: function () { return LOC.slice(); }, configurable: true }); } catch (e) {}
  try {
    var seed = (Math.random() * 4294967296) >>> 0;
    function rnd() { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; }
    var _td = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function () {
      try {
        var w = this.width, h = this.height; if (!w || !h) return _td.apply(this, arguments);
        var c = document.createElement('canvas'); c.width = w; c.height = h;
        var x = c.getContext('2d'); if (!x) return _td.apply(this, arguments);
        x.drawImage(this, 0, 0);
        var d = x.getImageData(0, 0, w, h);
        for (var i = 0; i < d.data.length; i += 4) { if (rnd() < 0.01) d.data[i] = (d.data[i] + ((rnd() * 3) | 0) + 1) & 255; }
        x.putImageData(d, 0, 0);
        return _td.apply(c, arguments);
      } catch (e) { return _td.apply(this, arguments); }
    };
  } catch (e) {}
})();
"@
}

# ---------------- WebRTC 禁用脚本(防IP泄漏的关键防线) ----------------
# 实测: Chrome 在"HTTP代理无法转发UDP"时会绕过 disable_non_proxied_udp 策略直连 STUN,
# 网络层参数挡不住; 从 JS 层禁用 RTCPeerConnection 才是确定性拦截 ——
# 网页(browserleaks等)无法构造 PeerConnection, 也就无法发起 STUN 探测公网IP
function New-WebRtcBlockScript {
    return @'
(function () {
  if (window.__supermask_nowbrtc__) return; window.__supermask_nowbrtc__ = 1;
  var msg = 'WebRTC is disabled by SuperMask (anti-leak)';
  function blocked() { throw new DOMException(msg, 'NotSupportedError'); }
  try { window.RTCPeerConnection = blocked; } catch (e) {}
  try { window.webkitRTCPeerConnection = blocked; } catch (e) {}
  try { window.RTCIceCandidate = blocked; } catch (e) {}
  try { window.RTCSessionDescription = blocked; } catch (e) {}
})();
'@
}

# ---------------- 向所有页面应用伪装覆写 ----------------
# 返回 @{ Count = 成功页面数; Errors = 错误列表 }
function Invoke-CdpApplyMask {
    param($Cdp, $Mask)
    $targets = Get-CdpPages $Cdp
    $alive = @{}
    $count = 0
    $errors = @()
    foreach ($t in $targets) {
        $tid = [string]$t.id
        $alive[$tid] = $true
        $conn = $null
        if ($Cdp.Pages.ContainsKey($tid)) { $conn = $Cdp.Pages[$tid] }
        if (-not $conn -or $conn.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            if ($conn) { Close-CdpConnection $conn }
            $conn = New-CdpConnection $t.webSocketDebuggerUrl
            if (-not $conn) { continue }
            $Cdp.Pages[$tid] = $conn
            $Cdp.Applied.Remove($tid)   # 新连接 → 重新注入加固脚本
        }
        $pageErr = $null
        # 注: locale/timezone 覆写是排他的; 若其它客户端(如常驻控制器)已设置同样覆写,
        #     会报 "already in effect" —— 此时伪装已在生效, 视为成功
        try {
            $null = Invoke-Cdp $conn 'Emulation.setGeolocationOverride' @{ latitude = $Mask.lat; longitude = $Mask.lon; accuracy = $Mask.accuracy }
        } catch { if ($_.Exception.Message -notlike '*already in effect*') { $pageErr = "地理覆写失败: $($_.Exception.Message)" } }
        try {
            $null = Invoke-Cdp $conn 'Emulation.setTimezoneOverride' @{ timezoneId = $Mask.timezone }
        } catch { if ($_.Exception.Message -notlike '*already in effect*') { $pageErr = "时区覆写失败($($Mask.timezone)): $($_.Exception.Message)" } }
        try {
            $null = Invoke-Cdp $conn 'Emulation.setLocaleOverride' @{ locale = $Mask.locale }
        } catch { if ($_.Exception.Message -notlike '*already in effect*') { $pageErr = "语言覆写失败($($Mask.locale)): $($_.Exception.Message)" } }
        if ($Mask.userAgent) {
            try {
                $null = Invoke-Cdp $conn 'Network.setUserAgentOverride' @{ userAgent = $Mask.userAgent; acceptLanguage = $Mask.acceptLanguage }
            } catch { $pageErr = "UA覆写失败: $($_.Exception.Message)" }
        }
        if (-not $pageErr) {
            if (-not $Cdp.Applied.ContainsKey($tid)) {
                try {
                    if ($Mask.webrtcBlock) {
                        $wsrc = New-WebRtcBlockScript
                        $null = Invoke-Cdp $conn 'Page.addScriptToEvaluateOnNewDocument' @{ source = $wsrc }
                        $null = Invoke-CdpEval $conn $wsrc
                    }
                    if ($Mask.hardening) {
                        $off = Invoke-CdpEval $conn 'new Date().getTimezoneOffset()'
                        if ($null -ne $off) {
                            $src = New-HardeningScript $Mask ([double]$off)
                            $null = Invoke-Cdp $conn 'Page.addScriptToEvaluateOnNewDocument' @{ source = $src }
                            $null = Invoke-CdpEval $conn $src
                        }
                    }
                } catch {}
                $Cdp.Applied[$tid] = $true
            }
            $count++
        } else {
            $errors += ('[{0}] {1}' -f $t.url, $pageErr)
            Close-CdpConnection $conn
            $Cdp.Pages.Remove($tid); $Cdp.Applied.Remove($tid)
        }
    }
    foreach ($k in @($Cdp.Pages.Keys)) {
        if (-not $alive.ContainsKey($k)) {
            Close-CdpConnection $Cdp.Pages[$k]
            $Cdp.Pages.Remove($k); $Cdp.Applied.Remove($k)
        }
    }
    return @{ Count = $count; Errors = $errors }
}

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
        # 注意1: PS5.1 中链式异步调用会把 VoidTaskResult 泄漏到管道, 必须 $null = 抑制
        # 注意2: ConnectAsync 必须带超时 —— 页面销毁/挂起时握手可能永远不完成,
        #        无超时会卡死控制器整个轮询循环(实测发生过)
        $task = $ws.ConnectAsync([Uri]$Url, [Threading.CancellationToken]::None)
        if (-not $task.Wait(3000)) {
            try { $ws.Abort() } catch {}
            try { $ws.Dispose() } catch {}
            return $null
        }
        $null = $task.GetAwaiter().GetResult()
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
    $sendTask = $Conn.Socket.SendAsync([ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None)
    if (-not $sendTask.Wait(3000)) {
        try { $Conn.Socket.Abort() } catch {}
        throw "CDP 发送超时: $Method"
    }
    $null = $sendTask.GetAwaiter().GetResult()

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

# ---------------- 登录屏蔽脚本 ----------------
# 面具浏览器禁止登录账号: 登录会把真实身份与面具指纹绑定, 伪装失去意义。
# Network.setBlockedURLs 附加会话前有竞态(页面可能已加载),
# 文档开头脚本则确定性生效: 命中登录域名 → window.stop() 中止加载并替换提示页
function New-LoginBlockScript {
    return @'
(function () {
  if (window.__supermask_nologin__) return; window.__supermask_nologin__ = 1;
  var hosts = ['accounts.google.com', 'accounts.youtube.com', 'accounts.youtube.cn'];
  var h = location.hostname;
  for (var i = 0; i < hosts.length; i++) {
    if (h === hosts[i]) {
      try { window.stop(); } catch (e) {}
      var b = document.body || document.documentElement;
      while (b.firstChild) { b.removeChild(b.firstChild); }
      b.setAttribute('style', 'font-family:Segoe UI,Microsoft YaHei,sans-serif;background:#16162a;color:#e8e8f0;display:flex;align-items:center;justify-content:center;height:100vh;margin:0');
      var wrap = document.createElement('div');
      wrap.style.textAlign = 'center'; wrap.style.maxWidth = '520px'; wrap.style.padding = '24px';
      var icon = document.createElement('div'); icon.style.fontSize = '44px'; icon.textContent = '\uD83D\uDD12';
      var h1 = document.createElement('h1'); h1.textContent = '\u767b\u5f55\u5df2\u7981\u7528';
      var p1 = document.createElement('p'); p1.textContent = '\u9762\u5177\u6d4f\u89c8\u5668\u7981\u6b62\u767b\u5f55\u4efb\u4f55\u8d26\u53f7 \u2014\u2014 \u767b\u5f55\u4f1a\u628a\u4f60\u7684\u771f\u5b9e\u8eab\u4efd\u4e0e\u9762\u5177\u6307\u7eb9\u5173\u8054\uff0c\u4f7f\u4f2a\u88c5\u5931\u53bb\u610f\u4e49\u3002';
      var p2 = document.createElement('p'); p2.textContent = 'SuperMask \u9632\u8d26\u53f7\u5173\u8054\u4fdd\u62a4'; p2.style.opacity = '0.55'; p2.style.fontSize = '13px';
      wrap.appendChild(icon); wrap.appendChild(h1); wrap.appendChild(p1); wrap.appendChild(p2);
      b.appendChild(wrap);
      document.title = 'SuperMask \u767b\u5f55\u5df2\u7981\u7528';
      return;
    }
  }
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
            # 注入各类脚本; 失败不标记 Applied → 下轮轮询重试(竞态导致的瞬时失败可自愈)
            if (-not $Cdp.Applied.ContainsKey($tid)) {
                $injOk = $true
                if ($Mask.blockLogin) {
                    try {
                        # Page.enable 必须先调用: 实测不启用 Page 域时,
                        # addScriptToEvaluateOnNewDocument 注册的脚本在导航/重载后不会触发
                        $null = Invoke-Cdp $conn 'Page.enable' @{}
                        $lsrc = New-LoginBlockScript
                        $null = Invoke-Cdp $conn 'Page.addScriptToEvaluateOnNewDocument' @{ source = $lsrc }
                        $null = Invoke-CdpEval $conn $lsrc
                        $null = Invoke-Cdp $conn 'Network.enable' @{}
                        $null = Invoke-Cdp $conn 'Network.setBlockedURLs' @{ urls = @(
                            '*accounts.google.com/*', '*accounts.youtube.com/*', '*accounts.youtube.cn/*'
                        ) }
                    } catch { $injOk = $false }
                }
                if ($injOk -and $Mask.webrtcBlock) {
                    try {
                        $null = Invoke-Cdp $conn 'Page.enable' @{}
                        $wsrc = New-WebRtcBlockScript
                        $null = Invoke-Cdp $conn 'Page.addScriptToEvaluateOnNewDocument' @{ source = $wsrc }
                        $null = Invoke-CdpEval $conn $wsrc
                    } catch { $injOk = $false }
                }
                if ($injOk -and $Mask.hardening) {
                    try {
                        $null = Invoke-Cdp $conn 'Page.enable' @{}
                        $off = Invoke-CdpEval $conn 'new Date().getTimezoneOffset()'
                        if ($null -ne $off) {
                            $src = New-HardeningScript $Mask ([double]$off)
                            $null = Invoke-Cdp $conn 'Page.addScriptToEvaluateOnNewDocument' @{ source = $src }
                            $null = Invoke-CdpEval $conn $src
                        }
                    } catch { $injOk = $false }
                }
                if ($injOk) { $Cdp.Applied[$tid] = $true }
            }
            # 登录页强化(每个周期执行, 幂等): 实测 addScriptToEvaluateOnNewDocument
            # 在 Google 重定向后的新文档上不一定触发, 周期性执行才保证登录页必然被掏空
            if ($Mask.blockLogin) {
                $u = [string]$t.url
                if ($u -like '*accounts.google.com*' -or $u -like '*accounts.youtube.com*' -or $u -like '*accounts.youtube.cn*') {
                    try { $null = Invoke-CdpEval $conn (New-LoginBlockScript) -TimeoutMs 3000 } catch {}
                }
            }
            # WebRTC 拦截同样每周期重新注入(幂等): 首次注入若遇页面加载竞态失败,
            # 或站点重定向后 doc-start 脚本未触发, 周期性重注入可自愈
            if ($Mask.webrtcBlock) {
                $u2 = [string]$t.url
                if ($u2 -like 'http*') {
                    try { $null = Invoke-CdpEval $conn (New-WebRtcBlockScript) -TimeoutMs 3000 } catch {}
                }
            }
            $count++        } else {
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

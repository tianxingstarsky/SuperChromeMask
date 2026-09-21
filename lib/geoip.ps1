# ============================================================
#  SuperMask - 超级面具  出口IP地理位置自动同步
#  工作流: 先启动 VPN/代理 → 再启动面具 → 选"自动"即与出口一致
#  探测: 优先经系统代理(WinINET, Clash/V2rayN 等都写在这里),
#        失败再直连; 数据源 ipinfo.io → ip-api.com 双保险
# ============================================================

# 读取当前系统代理, 返回 'http://host:port' 或 $null
function Get-SystemProxy {
    try {
        $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($k.ProxyEnable -eq 1 -and $k.ProxyServer) {
            $ps = [string]$k.ProxyServer
            $use = $null
            if ($ps -match '=') {
                # 按协议格式: http=host:port;https=host:port;socks=host:port
                foreach ($part in ($ps -split ';')) { if ($part -like 'https=*') { $use = ($part -replace '^https=', '').Trim(); break } }
                if (-not $use) {
                    foreach ($part in ($ps -split ';')) { if ($part -like 'http=*') { $use = ($part -replace '^http=', '').Trim(); break } }
                }
            } else { $use = $ps.Trim() }
            if ($use) {
                if ($use -notmatch '^https?://') { $use = 'http://' + $use }
                return $use
            }
        }
    } catch {}
    return $null
}

# 探测出口IP的地理位置
# 返回 @{ ip; city; region; country; lat; lon; timezone; via } 或 $null(全部失败)
function Get-ExitIpGeo {
    $proxy = Get-SystemProxy
    $tried = @{}
    # 第一轮: 走系统代理(若有); 第二轮: 直连(代理不可达时兜底, 并如实标注)
    foreach ($direct in @($false, $true)) {
        $via = $(if (-not $direct -and $proxy) { '系统代理' } else { '直连' })
        foreach ($u in @('https://ipinfo.io/json',
                         'http://ip-api.com/json/?fields=status,message,countryCode,country,regionName,city,lat,lon,timezone,query')) {
            $key = $u + '|' + $via
            if ($tried.ContainsKey($key)) { continue }
            $tried[$key] = $true
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $p = @{ Uri = $u; TimeoutSec = 10; UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) SuperMask/1.0' }
                if (-not $direct -and $proxy) { $p.Proxy = $proxy }
                $r = Invoke-RestMethod @p
                if ($u -like '*ipinfo*') {
                    $ll = ([string]$r.loc) -split ','
                    if (-not $r.ip -or $ll.Count -lt 2) { continue }
                    return @{ ip = [string]$r.ip; city = [string]$r.city; region = [string]$r.region
                              country = [string]$r.country; lat = [double]$ll[0]; lon = [double]$ll[1]
                              timezone = [string]$r.timezone; via = $via }
                } else {
                    if ($r.status -ne 'success' -or -not $r.query) { continue }
                    return @{ ip = [string]$r.query; city = [string]$r.city; region = [string]$r.regionName
                              country = [string]$r.countryCode; lat = [double]$r.lat; lon = [double]$r.lon
                              timezone = [string]$r.timezone; via = $via }
                }
            } catch {}
        }
    }
    return $null
}

# 国家代码 → 区域 locale (界面语言/Accept-Language 随出口国家)
$script:CountryToLocale = @{
    CN='zh-CN'; HK='zh-HK'; TW='zh-TW'; MO='zh-HK'; JP='ja-JP'; KR='ko-KR'
    SG='en-SG'; MY='ms-MY'; TH='th-TH'; VN='vi-VN'; ID='id-ID'; PH='en-PH'; IN='en-IN'
    US='en-US'; CA='en-CA'; GB='en-GB'; IE='en-IE'; AU='en-AU'; NZ='en-NZ'
    FR='fr-FR'; BE='nl-BE'; NL='nl-NL'; DE='de-DE'; AT='de-AT'; CH='de-CH'
    IT='it-IT'; ES='es-ES'; PT='pt-PT'; BR='pt-BR'; MX='es-MX'; AR='es-AR'; CL='es-CL'; CO='es-CO'; PE='es-PE'
    RU='ru-RU'; UA='uk-UA'; PL='pl-PL'; SE='sv-SE'; NO='nb-NO'; DK='da-DK'; FI='fi-FI'
    CZ='cs-CZ'; RO='ro-RO'; GR='el-GR'; HU='hu-HU'; TR='tr-TR'
    AE='en-AE'; SA='ar-SA'; IL='he-IL'; EG='ar-EG'; ZA='en-ZA'; NG='en-NG'; KE='en-KE'
}

# 出口地理信息 → 完整面具参数(坐标/时区/locale/界面语言/Win时区)
function Resolve-MaskFromGeo {
    param($Geo)
    if (-not $Geo.timezone) { throw '出口IP未返回时区信息, 无法自动同步 — 请改用手动地点' }
    if (-not $Geo.lat -and $Geo.lat -ne 0) { throw '出口IP未返回坐标信息, 无法自动同步 — 请改用手动地点' }
    $locale = 'en-US'
    if ($script:CountryToLocale.ContainsKey($Geo.country)) { $locale = $script:CountryToLocale[$Geo.country] }
    $winTz = Convert-IanaToWindowsTz $Geo.timezone
    $place = $Geo.city; if ([string]::IsNullOrWhiteSpace($place)) { $place = $Geo.country }
    return @{
        id = 'auto'; name = ('自动 · ' + $place + ' (' + $Geo.country + ')')
        lat = [math]::Round([double]$Geo.lat, 4); lon = [math]::Round([double]$Geo.lon, 4)
        timezone = $Geo.timezone; winTz = $winTz
        locale = $locale; lang = $locale
        accuracy = 100; userAgent = ''; acceptLanguage = ''; hardening = $false
    }
}

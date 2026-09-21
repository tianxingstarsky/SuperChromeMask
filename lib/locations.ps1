# ============================================================
#  SuperMask - 超级面具  地点预设库
#  id / 名称 / 纬度 / 经度 / IANA时区 / Windows时区 / 区域locale / 界面语言
# ============================================================

$script:Locations = @(
    @{ id='tokyo';      name='日本 · 东京';      lat=35.6762;  lon=139.6503;  tz='Asia/Tokyo';       winTz='Tokyo Standard Time';       locale='ja-JP'; lang='ja' }
    @{ id='osaka';      name='日本 · 大阪';      lat=34.6937;  lon=135.5023;  tz='Asia/Tokyo';       winTz='Tokyo Standard Time';       locale='ja-JP'; lang='ja' }
    @{ id='seoul';      name='韩国 · 首尔';      lat=37.5665;  lon=126.9780;  tz='Asia/Seoul';       winTz='Korea Standard Time';       locale='ko-KR'; lang='ko' }
    @{ id='singapore';  name='新加坡';           lat=1.3521;   lon=103.8198;  tz='Asia/Singapore';   winTz='Singapore Standard Time';   locale='en-SG'; lang='en-SG' }
    @{ id='hongkong';   name='香港';             lat=22.3193;  lon=114.1694;  tz='Asia/Hong_Kong';   winTz='China Standard Time';       locale='zh-HK'; lang='zh-HK' }
    @{ id='taipei';     name='台湾 · 台北';      lat=25.0330;  lon=121.5654;  tz='Asia/Taipei';      winTz='Taipei Standard Time';      locale='zh-TW'; lang='zh-TW' }
    @{ id='newyork';    name='美国 · 纽约';      lat=40.7128;  lon=-74.0060;  tz='America/New_York'; winTz='Eastern Standard Time';     locale='en-US'; lang='en-US' }
    @{ id='losangeles'; name='美国 · 洛杉矶';    lat=34.0522;  lon=-118.2437; tz='America/Los_Angeles'; winTz='Pacific Standard Time';  locale='en-US'; lang='en-US' }
    @{ id='london';     name='英国 · 伦敦';      lat=51.5074;  lon=-0.1278;   tz='Europe/London';    winTz='GMT Standard Time';         locale='en-GB'; lang='en-GB' }
    @{ id='paris';      name='法国 · 巴黎';      lat=48.8566;  lon=2.3522;    tz='Europe/Paris';     winTz='Romance Standard Time';     locale='fr-FR'; lang='fr' }
    @{ id='berlin';     name='德国 · 柏林';      lat=52.5200;  lon=13.4050;   tz='Europe/Berlin';    winTz='W. Europe Standard Time';   locale='de-DE'; lang='de' }
    @{ id='sydney';     name='澳大利亚 · 悉尼';  lat=-33.8688; lon=151.2093;  tz='Australia/Sydney'; winTz='AUS Eastern Standard Time'; locale='en-AU'; lang='en-AU' }
    @{ id='toronto';    name='加拿大 · 多伦多';  lat=43.6532;  lon=-79.3832;  tz='America/Toronto';  winTz='Eastern Standard Time';     locale='en-CA'; lang='en-CA' }
    @{ id='dubai';      name='阿联酋 · 迪拜';    lat=25.2048;  lon=55.2708;   tz='Asia/Dubai';       winTz='Arabian Standard Time';     locale='en-AE'; lang='en-AE' }
)

function Get-PresetLocation {
    param([string]$Id)
    foreach ($l in $script:Locations) { if ($l.id -eq $Id) { return $l } }
    return $null
}

# IANA 时区 → Windows 时区 ID 映射(常用值); 未收录返回 $null
$script:IanaToWindowsTz = @{
    'Asia/Tokyo'          = 'Tokyo Standard Time'
    'Asia/Seoul'          = 'Korea Standard Time'
    'Asia/Shanghai'       = 'China Standard Time'
    'Asia/Chongqing'      = 'China Standard Time'
    'Asia/Urumqi'         = 'China Standard Time'
    'Asia/Hong_Kong'      = 'China Standard Time'
    'Asia/Macau'          = 'China Standard Time'
    'Asia/Taipei'         = 'Taipei Standard Time'
    'Asia/Singapore'      = 'Singapore Standard Time'
    'Asia/Kuala_Lumpur'   = 'Singapore Standard Time'
    'Asia/Bangkok'        = 'SE Asia Standard Time'
    'Asia/Ho_Chi_Minh'    = 'SE Asia Standard Time'
    'Asia/Jakarta'        = 'SE Asia Standard Time'
    'Asia/Manila'         = 'Singapore Standard Time'
    'Asia/Dubai'          = 'Arabian Standard Time'
    'Asia/Kolkata'        = 'India Standard Time'
    'America/New_York'    = 'Eastern Standard Time'
    'America/Detroit'     = 'Eastern Standard Time'
    'America/Toronto'     = 'Eastern Standard Time'
    'America/Montreal'    = 'Eastern Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Mexico_City' = 'Central Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Phoenix'     = 'US Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'America/Vancouver'   = 'Pacific Standard Time'
    'America/Sao_Paulo'   = 'E. South America Standard Time'
    'America/Argentina/Buenos_Aires' = 'Argentina Standard Time'
    'Europe/London'       = 'GMT Standard Time'
    'Europe/Dublin'       = 'GMT Standard Time'
    'Europe/Lisbon'       = 'GMT Standard Time'
    'Europe/Paris'        = 'Romance Standard Time'
    'Europe/Madrid'       = 'Romance Standard Time'
    'Europe/Brussels'     = 'Romance Standard Time'
    'Europe/Berlin'       = 'W. Europe Standard Time'
    'Europe/Rome'         = 'W. Europe Standard Time'
    'Europe/Amsterdam'    = 'W. Europe Standard Time'
    'Europe/Zurich'       = 'W. Europe Standard Time'
    'Europe/Vienna'       = 'W. Europe Standard Time'
    'Europe/Stockholm'    = 'W. Europe Standard Time'
    'Europe/Moscow'       = 'Russian Standard Time'
    'Europe/Istanbul'     = 'Turkish Standard Time'
    'Australia/Sydney'    = 'AUS Eastern Standard Time'
    'Australia/Melbourne' = 'AUS Eastern Standard Time'
    'Australia/Brisbane'  = 'E. Australia Standard Time'
    'Australia/Perth'     = 'W. Australia Standard Time'
    'Pacific/Auckland'    = 'New Zealand Standard Time'
}
function Convert-IanaToWindowsTz {
    param([string]$Iana)
    if ($script:IanaToWindowsTz.ContainsKey($Iana)) { return $script:IanaToWindowsTz[$Iana] }
    return $null
}

# 校验 Windows 时区 ID 是否存在 (tzutil /l 列表)
function Test-WindowsTimezoneId {
    param([string]$WinTzId)
    # 不同系统/语言的 tzutil /l 行序不同(显示名与时区ID交替出现), 采用整行精确匹配
    try {
        $lines = @(& tzutil.exe /l)
        foreach ($ln in $lines) { if ($ln -eq $WinTzId) { return $true } }
    } catch {}
    return $false
}

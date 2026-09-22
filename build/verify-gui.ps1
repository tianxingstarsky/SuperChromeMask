$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Get-Process SuperMask -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Start-Process 'F:\超级面具\build\SuperMask.exe'
Start-Sleep -Seconds 8
$p = Get-Process SuperMask -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Host 'RESULT: FAIL - process dead'; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { Write-Host 'RESULT: FAIL - no window'; exit 1 }
$texts = @()
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
foreach ($el in $all) { if ($el.Current.Name) { $texts += $el.Current.Name } }
$hasStart = @($texts | Where-Object { $_ -like '*启动面具*' }).Count -gt 0
$hasVpn   = @($texts | Where-Object { $_ -like '*强制VPN模式*' }).Count -gt 0
$noKeep   = @($texts | Where-Object { $_ -like '*保留面具配置*' }).Count -eq 0
$hasError = @($texts | Where-Object { $_ -like '*无法*' -or $_ -like '*绑定*' }).Count -gt 0
Write-Host ('启动按钮:' + $hasStart + ' 强制VPN:' + $hasVpn + ' 保留项已移除:' + $noKeep + ' 错误:' + $hasError)
if ($hasStart -and $hasVpn -and $noKeep -and -not $hasError) { Write-Host 'RESULT: PASS' } else { Write-Host 'RESULT: FAIL' }
Stop-Process -Id $p.Id -Force

# 超级面具 SuperMask v1.2.1

给 Windows 电脑（尤其是浏览器）戴上"地理位置面具"：**GPS 坐标 / 时区 / 语言 / WebRTC** 一键伪装成任意地点。

核心设计承诺：**运行时优先、不改系统文件、关闭即恢复、全程可闭环**。

---

## 为什么开了 VPN 还会被定位成真实区域？

VPN 只换了 IP。网站还能通过浏览器本身暴露的信息推断你的真实位置：

| 检测途径 | 说明 | 本工具对策 | 级别 |
|---|---|---|---|
| GPS 地理 API | `navigator.geolocation`（Wi-Fi/系统定位，返回真实坐标） | 调试协议运行时覆写坐标，并自动授权免弹窗 | 浏览器级·纯运行时 |
| 时区 | `Intl`/`Date` 查询（IP 在东京而时区是东八区 → 暴露） | 运行时覆写为伪装地点时区 | 浏览器级·纯运行时 |
| 语言/区域 | `navigator.language(s)` / Accept-Language / Intl | 运行时覆写 + 浏览器界面语言随地点 | 浏览器级·纯运行时 |
| WebRTC / QUIC 旁路 | WebRTC 的 STUN 探测、QUIC/HTTP3(UDP 443) 都可能绕过 HTTP 代理直连（v1.1.1 实测确认会泄漏真实 IP） | **强制VPN模式（v1.2.0）**：① 自动探测 SOCKS5（可承载 UDP）优先 ② 禁 QUIC/HTTP3 ③ JS 层禁用 RTCPeerConnection ④ 显式代理强制全部连接经 VPN，**代理断开即断网，绝不静默回退直连**；「验证伪装」内置泄漏探测可实测 | 浏览器级·纯运行时 |
| IP 归属地 | **面具不改 IP**，由你的 VPN/代理决定 | 自动同步模式按出口 IP 生成全套伪装；手动模式启动时比对并提示 | 与 VPN 配合 |
| Canvas 等指纹 | 设备关联识别（非定位，但可关联账号） | 实验性加固：Canvas 噪声 + JS 兜底（可选） | 部分缓解 |
| 账号登录 | 登录会把身份与面具指纹/出口绑定，伪装失去意义（v1.2.1 起**刻意禁用**） | 网络层屏蔽 Google 账号登录页（accounts.google.com 等）+ 配置永远退出即焚，无任何登录状态可存留 | 浏览器级·纯运行时 |

## 快速开始

1. **先启动 VPN/代理**（等待其就绪），再双击 **`StartSuperMask.bat`** 打开图形界面
2. 地点默认选中 **「自动 · 同步VPN/代理出口(推荐)」**：读取系统代理探测出口 IP，
   坐标/时区/语言全自动与出口保持一致（零配置、零破绽）；也可选城市预设或自定义
3. 选择浏览器（Chrome/Edge，自动检测）
4. 点 **▶ 启动面具** —— 会弹出一个**独立的面具浏览器**：
   - 使用独立的临时配置文件，与你日常浏览器完全隔离、互不影响
   - 默认自动打开 browserleaks 验证页面，可直接看到伪装效果
   - 点 **✓ 验证伪装** 可读回浏览器实际看到的时区/语言/坐标并逐项比对
5. 用完点 **■ 停止并恢复**（或直接关掉浏览器窗口），一切自动还原

## 自动同步 VPN 出口（推荐工作流）

**先启动 VPN → 再启动面具 → 选「自动」**，工具会：

1. 读取系统代理（Clash / V2rayN / SSR 等的"系统代理"都写在 WinINET 注册表；TUN 模式则直连）
2. **经该代理**查询出口 IP 的地理位置（ipinfo.io → ip-api.com 双源容错）
3. 按出口位置自动生成整套面具：城市坐标（经纬度）+ IANA 时区 + 国家对应语言/locale + Windows 时区
4. 启动后再做一次**出口核验**：出口时区与伪装时区逐项比对，一致打 [OK]，不一致会警告

注意：切换 VPN 节点后请**重启面具**重新同步；手动选择地点时若出口与伪装地不一致，日志会明确提示暴露风险。

## 命令行用法

```powershell
# 查看预设地点
powershell -File SuperMask.ps1 -CLI -ListLocations

# 自动同步 VPN 出口(推荐): 读系统代理 → 探测出口 → 全自动
powershell -File SuperMask.ps1 -CLI -Start -Location auto -BrowserName edge

# 用预设城市
powershell -File SuperMask.ps1 -CLI -Start -Location tokyo -BrowserName chrome

# 自定义地点: 纬度,经度,IANA时区,locale[,语言[,名称]]
powershell -File SuperMask.ps1 -CLI -Start -CustomLocation "35.68,139.65,Asia/Tokyo,ja-JP"

# 常用控制
powershell -File SuperMask.ps1 -CLI -Status    # 查看活动会话
powershell -File SuperMask.ps1 -CLI -Verify    # 核验伪装效果
powershell -File SuperMask.ps1 -CLI -Stop      # 停止并恢复
powershell -File SuperMask.ps1 -CLI -Restore   # 恢复上次未正常关闭的会话
```

可选参数：`-NoWebRTCProtect`、`-Hardening`、`-SyncSystemTimezone`、`-Proxy "socks5://127.0.0.1:1080"`、`-NoVerifyPages`、`-BrowserPath <路径>`。

## 恢复保障（闭环矩阵）

| 场景 | 浏览器级伪装 | 临时配置文件 | 系统时区(若开启) | 机制 |
|---|---|---|---|---|
| 点「停止并恢复」 | 随浏览器关闭消失 | 立即删除 | 自动还原备份 | 控制器主动恢复 |
| 直接关闭浏览器窗口 | 消失 | 控制器 3 秒内检测到并删除 | 自动还原 | 控制器轮询 |
| 面具软件被杀/崩溃 | 随浏览器消失 | 残留于 %TEMP% | 保持伪装 | ①下次启动自动检测并恢复 ②`-Restore` ③紧急恢复 |
| 电脑重启 / 断电 | 自然消失 | 系统临时目录，无影响 | **开机守卫自动还原并自删除** | 启动文件夹自包含守卫 |
| 守卫也失效（极端） | — | 可手动删 | 紧急恢复脚本 / `tzutil /s "备份值"` | 状态文件中永久记录备份值 |

**紧急恢复**：双击 `EmergencyRestore.bat`（完全独立，主程序坏了也能用），一键完成：还原系统时区 → 结束面具浏览器 → 删除临时配置 → 移除守卫 → 清除状态。

## 技术原理

- **零文件修改的运行时注入**：通过 `--remote-debugging-port` 连接 Chrome DevTools 协议，调用
  `Emulation.setGeolocationOverride`（坐标）、`Emulation.setTimezoneOverride`（时区）、`Emulation.setLocaleOverride`（语言）、
  `Browser.grantPermissions`（地理权限免弹窗）。这些是**会话级覆写**，浏览器进程一结束即彻底消失。
- **配置隔离**：面具浏览器用 `--user-data-dir` 指向 `%TEMP%\SuperMask\` 下的临时目录（永远退出即焚），你的真实浏览器配置、登录、历史全程不受影响。
- **新标签页持续覆盖**：控制器每 3 秒轮询一次所有标签页，对新页面自动重新应用伪装（防止导航后覆写被清除）。
- **系统时区（默认关）**：唯一会改系统状态的选项。修改前先把原时区写入 `%LOCALAPPDATA%\SuperMask\session.json`，并在启动文件夹放一个**自包含**的还原守卫（Base64 编码、纯 ASCII、不依赖工具目录），重启登录后静默还原并自删除。
- **安全删除**：删除任何目录前都校验路径必须位于工具管理的 `%TEMP%\SuperMask` 或 `%LOCALAPPDATA%\SuperMask\profiles` 之下，绝不动其它路径。

## 工具自身的痕迹（透明说明）

运行会在这些位置留下工具自身数据（均可安全手动删除）：

- `%LOCALAPPDATA%\SuperMask\` —— 会话状态、偏好配置、守卫日志
- `%TEMP%\SuperMask\` —— 面具浏览器临时配置（正常退出即删）
- 启动文件夹 `SuperMaskRestoreGuard.cmd` —— **仅在开启系统时区伪装期间存在**，还原后自删除

## 限制与注意事项

1. **面具不改变 IP**。出口 IP 由 VPN/代理决定；「自动同步」模式已保证 IP 与伪装地点一致，手动模式若不一致日志会警告（"IP 在 A 国、GPS 在 B 国"本身就可疑）。
2. 需要基于 Chromium 的浏览器（Chrome / Edge）。Firefox 不支持此调试协议。
3. 跨域 iframe 内嵌组件（第三方广告/挂件）的时区可能不完全覆盖（少见场景；实验性加固可缓解一部分）。
4. 指纹加固为实验功能（Canvas 噪声 + JS 兜底），不承诺对抗商业级指纹检测。
5. WebRTC 防泄漏开启时会在网页里禁用 RTCPeerConnection（否则 Chrome 会绕过代理直连 STUN 暴露真实 IP），网页版音视频通话（Discord/Meet 等）将不可用；确有需要可取消勾选，但会重新暴露真实 IP 风险。
6. 若浏览器被企业策略禁止远程调试，工具会启动失败并提示，不会留下任何更改。

## 文件清单

```
SuperMask.ps1        主程序（GUI + CLI）
StartSuperMask.bat   双击启动图形界面
EmergencyRestore.ps1 / .bat   独立紧急恢复（最后一道保险）
lib\common.ps1       状态/日志/路径安全
lib\locations.ps1    地点预设库 + 时区映射
lib\geoip.ps1        系统代理读取 + 出口IP地理探测 + 自动同步
lib\cdp.ps1          CDP 调试协议客户端（纯标准库 WebSocket）
lib\browser.ps1      浏览器发现/启动/清理
lib\sysmask.ps1      系统时区伪装 + 开机自还原守卫
```

## 免责声明

本工具仅用于**个人隐私保护、防跟踪与测试学习**。使用者应遵守所在地法律法规及目标网站服务条款，不得用于欺诈、冒充他人或任何违法用途。因滥用造成的后果由使用者自行承担。

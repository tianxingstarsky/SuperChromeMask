# SuperMask 超级面具 v1.1.1

> **重要修复**：WebRTC 真实 IP 泄漏（"WebRTC IP doesn't match your Remote IP"）——如果你在用 v1.1.0 且浏览器检测出真实地区，请立即更新。

给 Windows 浏览器戴上"地理位置面具"：**GPS 坐标 / 时区 / 语言 / WebRTC** 一键伪装，**自动同步 VPN 出口**，**运行时注入、不改系统文件、关闭即恢复**。

## v1.1.1 更新内容

### 🐛 修复：WebRTC 真实 IP 泄漏

**问题**：v1.1.0 仅依赖 Chrome 启动参数 `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`，实测（Chrome 153）当系统代理为 HTTP 代理（无法转发 UDP）时，Chrome 会绕过该策略**直连 STUN 服务器**，导致 browserleaks 等检测站点看到你的真实公网 IP（例如 `WebRTC IP doesn't match your Remote IP`）。

**修复（三层防护）**：
1. **JS 层禁用 RTCPeerConnection**（新增，确定性拦截）：通过调试协议向每个页面注入脚本，网页（含 browserleaks）无法构造 PeerConnection，从根源上无法发起 STUN 探测。副作用：网页版音视频通话（Discord/Meet 等）不可用，取消勾选"WebRTC 防泄漏"可恢复。
2. **显式代理**：启动时自动把面具浏览器的 `--proxy-server` 指向当前系统代理，DNS 与连接全部强制经 VPN。
3. **处理策略**：保留 `disable_non_proxied_udp` 启动参数兜底。

### ✨ 新增：WebRTC 泄漏检测

「验证伪装」现在会用多路 STUN（Google/Cloudflare/腾讯）真实探测面具浏览器暴露的公网映射 IP，并与 VPN 出口 IP 逐项比对：
- `[OK]` = 无泄漏或映射 IP 与出口一致
- `[X]` = 检测到真实 IP 泄漏（会明确列出泄漏的 IP）

## 使用方法

1. **先启动 VPN/代理**，再运行 `SuperMask.exe`
2. 地点保持「自动 · 同步VPN/代理出口(推荐)」（或手动选城市/自定义）
3. 点 **▶ 启动面具** —— 会弹出独立的面具浏览器（与日常浏览器完全隔离）
4. 点 **✓ 验证伪装** 实测时区/语言/坐标/WebRTC 四项（会真实做一次 STUN 泄漏探测）
5. 用完点 **■ 停止并恢复**，或直接关闭面具浏览器窗口，一切自动还原

`EmergencyRestore.exe` 是独立紧急恢复工具：任何异常残留双击即可一键还原。

## ⚠️ 杀毒软件误报说明

本程序使用开源的 ps2exe 打包 PowerShell 源码生成，**未做代码签名**，部分杀毒软件可能误报为风险程序。如有顾虑，请直接下载源码用 PowerShell 运行（`StartSuperMask.bat`），或自行查阅 `build/make-exe.ps1` 从源码构建。请从本仓库官方 Release 下载。

## 系统要求

Windows 10/11 · Chrome 或 Edge（自动检测）· 无任何运行时依赖

## 免责声明

仅供个人隐私保护、防跟踪与测试学习使用，请遵守当地法律法规与网站服务条款。

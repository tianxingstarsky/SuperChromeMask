# SuperMask 超级面具 v1.2.2

> **如果你在 browserleaks 看到 "WebRTC IP doesn't match your Remote IP" 且 Public IP 显示真实 IP（如 120.235.237.130）——请更新到本版，并确认测试是在"弹出的面具浏览器"里做的。**

给 Windows 浏览器戴上"地理位置面具"：**GPS 坐标 / 时区 / 语言 / WebRTC** 一键伪装，**自动同步 VPN 出口**，**强制全量走 VPN**，**运行时注入、不改系统文件、关闭即恢复**。

## v1.2.2 更新内容

### 🐛 修复：WebRTC 拦截在部分页面竞态失效

取证发现（用户实测 browserleaks 仍显示真实 IP）：WebRTC 拦截脚本只在页面**首次**应用时注入一次，若恰好赶上页面加载竞态（或站点重定向后新文档未触发 doc-start 脚本），该页面的注入会被错误标记为"已完成"而**永不重试**——登录页屏蔽此前已有每周期重注入，本版把 **WebRTC 拦截也改为每 2 秒重新注入**（幂等、自愈），彻底封死竞态窗口。

**实测（browserleaks.com/webrtc，本机真实环境）**：

```
WebRTC Leak Test    ✔ No Leak
RTCPeerConnection   ✗ False
RTCDataChannel      ✗ False
Public IP Address   -        ← 无任何 IP 暴露
Your Remote IP      38.106.19.252 (洛杉矶VPN出口)
```

（截图见本 Release 附件 browserleaks-webrtc.png）

## 重要：正确的测试姿势

看到真实 IP 泄漏时，请按顺序自查：

1. **确认测试的是"弹出的面具浏览器"窗口**，不是你日常用的 Chrome——日常 Chrome 的 WebRTC 天然会走直连 STUN 探测出真实 IP，这不是面具能管的
2. **确认"强制VPN模式"已勾选**（默认勾选）
3. **确认用的是 v1.2.2**（主界面标题栏有版本号）
4. 点面具主界面的 **✓ 验证伪装**——内置的泄漏检测会用多路 STUN 实测，全 [OK] 才算过
5. 记住：**面具不改变 Public IP**。browserleaks 顶部的 "Your Remote IP" 才是 VPN 出口；WebRTC 区块里的 Public IP 若显示真实 IP 即为泄漏（本版已在面具浏览器内消除）

## 既有功能

- **自动同步 VPN 出口**：读取系统代理探测出口 IP，坐标/时区/语言全自动一致
- **强制 VPN 模式**：SOCKS5 自动发现 + 禁 QUIC/HTTP3 + JS 层禁用 WebRTC + 显式代理全协议，代理断开即断网不回退
- **禁止账号登录**：Google 登录页被自动屏蔽（防账号关联），配置永远退出即焚
- **完整恢复闭环**：停止还原 / 崩溃恢复 / 开机守卫 / 独立紧急恢复

## 系统要求

Windows 10/11 · Chrome 或 Edge（自动检测）· 无任何运行时依赖

## 免责声明

仅供个人隐私保护、防跟踪与测试学习使用，请遵守当地法律法规与网站服务条款。

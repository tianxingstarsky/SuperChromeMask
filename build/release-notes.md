# SuperMask 超级面具 v1.2.3

> **根因修复**：v1.2.2 及之前版本中，WebRTC/登录拦截脚本在**页面导航、重载、站点重定向后不生效**的最终根因已找到并修复——注入 doc-start 脚本前缺少 `Page.enable` 调用。实测加了它之后拦截脚本在所有导航场景下可靠触发。

给 Windows 浏览器戴上"地理位置面具"：**GPS 坐标 / 时区 / 语言 / WebRTC** 一键伪装，**自动同步 VPN 出口**，**强制全量走 VPN**，**运行时注入、不改系统文件、关闭即恢复**。

## v1.2.3 更新内容

### 🐛 根因修复：缺少 Page.enable 导致拦截脚本在导航后失效

通过对照实验定位（同一页面 reload 前后对比）：

| | 不加 Page.enable | 加 Page.enable |
|---|---|---|
| reload 后 doc-start 脚本 | ❌ 不触发 | ✅ 可靠触发 |

修复内容：
1. 所有 `Page.addScriptToEvaluateOnNewDocument` 注册前先调用 `Page.enable`
2. **验证页改为"预注入后导航"**：先开 about:blank → 注册拦截脚本 → 再导航到 browserleaks，从第一个文档起就处于保护状态（消除首载竞态）
3. 保留每周期重新注入兜底（登录页 + WebRTC 拦截均周期性重申）

**实测（browserleaks.com/webrtc，面具浏览器自动打开的验证页）**：

```
WebRTC Leak Test    ✔ No Leak
Public IP Address   -           ← 无任何 IP 暴露
RTCPeerConnection   ✗ False
Your Remote IP      38.106.19.252 (洛杉矶VPN出口)
reload 之后          依然 ✔ No Leak
```

（截图见附件 browserleaks-v123.png）

## 使用方法

1. **先启动 VPN/代理**，再运行 `SuperMask.exe`（zip 请先解压再运行）
2. 地点保持「自动 · 同步VPN/代理出口(推荐)」，强制VPN模式保持勾选
3. 点 **▶ 启动面具** → 测试请**只在弹出的面具浏览器里**进行（日常 Chrome 的 WebRTC 会直连探出真实 IP，不属于面具管辖）
4. 点 **✓ 验证伪装** 确认四项全 [OK]
5. 用完点 **■ 停止并恢复**，或直接关闭面具浏览器窗口

杀毒软件拦截时：右键文件 → 属性 → 解除锁定；或加白名单；或用 Source code（zip）+ `StartSuperMask.bat` 源码方式运行。

## 系统要求

Windows 10/11 · Chrome 或 Edge（自动检测）· 无任何运行时依赖

## 免责声明

仅供个人隐私保护、防跟踪与测试学习使用，请遵守当地法律法规与网站服务条款。

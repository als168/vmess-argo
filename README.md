# VMess + Argo 一键部署脚本
 

本仓库提供一个一键脚本，快速部署 **Xray (VMess)** + **Cloudflare Argo 隧道**。  
支持 **临时隧道 (Quick Tunnel)** 和 **自建隧道 (Named Tunnel)** 两种模式。


---

## 功能特点
- ✅ 自动安装 Xray 与 Cloudflared
- ✅ 自动生成配置文件，无需手动修改
- ✅ 支持临时隧道（无需 Cloudflare 控制台）
- ✅ 支持自建隧道（绑定自己的域名）
- ✅ 自动输出 V2RayN 链接，复制即可导入客户端
- ✅ 一键卸载，环境干净

---

使用方法

1. 下载并运行脚本
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/als168/vmess-argo/main/vmess_argo.sh)
```
2. 选择模式
---
运行后会出现菜单：

===== VMess + Argo =====
1. 安装并启动 (临时隧道)
2. 安装并启动 (自建隧道)
3. 卸载
0. 退出
---
选 1 → 临时隧道，自动生成 trycloudflare.com 域名

选 2 → 自建隧道，需要输入：

隧道 ID

域名（你在 Cloudflare 控制台绑定的域名）

Argo 隧道 token

注意事项
---
临时隧道：域名为 xxxx.trycloudflare.com，适合测试。

自建隧道：必须在 Cloudflare 控制台创建隧道并绑定域名。

端口固定：Xray 默认监听在 8001，Cloudflared 配置已自动指向该端口。

路径固定：WebSocket 路径为 /vmess。

TLS 必须开启：客户端配置时一定要勾选 TLS。

常见问题
---
延迟显示 -1 → 检查客户端配置是否和服务端一致（域名、端口、UUID、路径、TLS、Host）。

502 错误 → 通常是 Cloudflared 配置不正确或 Xray 没启动。

域名解析失败 → 等待 DNS 缓存刷新，或直接用 ping 域名 测试。

致谢
---
Xray-core

Cloudflared

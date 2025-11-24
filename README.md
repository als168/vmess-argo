# vmess + Argo 一键脚本 (Linux)

本仓库提供一个 **单文件 Bash 脚本**，可以在 Linux 系统上一键部署：
- Xray (vmess + WebSocket)
- Cloudflare Argo Tunnel (cloudflared)

无需域名和证书，默认使用 Cloudflare Quick Tunnel，自动生成客户端导入链接。

---

## 快速开始

### 下载并运行
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/als168/vmess-argo-min/main/vmess_argo_min.sh)"


```
运行后会提示选择：
```
请选择隧道模式：
1. 临时隧道 (Quick Tunnel) —— 简单快速，但域名随机、不稳定
2. 自建隧道 (需要 Cloudflare 账号和 token) —— 域名固定，稳定性高
```
输入 1 → 使用临时隧道，自动生成一个随机域名。

输入 2 → 使用自建隧道，需要输入你在 Cloudflare 面板里创建的 token。

许可证
MIT License
```
---

### `vmess_argo_min.sh`

就是我之前帮你写的 **精简版脚本（带选择提示）**，你只要复制进去即可。

---

✅ 这样你就有一个完整的仓库结构：  
- `README.md` 让人一眼就能看懂临时隧道和自建隧道的区别。  
- `vmess_argo_min.sh` 是极简脚本，适合低配 VPS。  

要不要我帮你直接写好 **GitHub 上传步骤**（从本地 VPS 到 GitHub 仓库），让你一步步照着操作？
```

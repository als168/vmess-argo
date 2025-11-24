#!/bin/bash
set -e

WORK_DIR="/etc/xray"
CONFIG_FILE="$WORK_DIR/config.json"
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
XRAY_PORT=${XRAY_PORT:-10080}
WS_PATH=${WS_PATH:-/vmess}
ARGO_DOMAIN=""

# 安装依赖
install_deps() {
  if ! command -v curl >/dev/null; then
    apt update -y && apt install -y curl unzip || yum install -y curl unzip
  fi
}

# 安装 Xray
install_xray() {
  arch=$(uname -m)
  case "$arch" in
    x86_64) dl_arch="64" ;;
    aarch64) dl_arch="arm64-v8a" ;;
    *) dl_arch="64" ;;
  esac
  mkdir -p $WORK_DIR
  curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$dl_arch.zip" -o xray.zip
  unzip -q xray.zip -d $WORK_DIR && rm xray.zip
  install -m 755 $WORK_DIR/xray /usr/local/bin/xray
}

# 安装 cloudflared
install_cloudflared() {
  arch=$(uname -m)
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  [ "$arch" = "aarch64" ] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  curl -fsSL "$url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

# 写配置文件（包含 TLS 和 Argo 域名）
write_config() {
  cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "serverName": "$ARGO_DOMAIN"
      },
      "wsSettings": { "path": "$WS_PATH", "headers": { "Host": "$ARGO_DOMAIN" } }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

# 启动服务并获取域名
start_services() {
  nohup xray -c $CONFIG_FILE >/dev/null 2>&1 &
  echo -e "\n请选择隧道模式："
  echo "1. 临时隧道 (Quick Tunnel)"
  echo "2. 自建隧道 (需要 Cloudflare token)"
  read -p "请输入选择 (1/2): " choice

  if [ "$choice" = "2" ]; then
    read -p "请输入你的 Argo 隧道 token: " ARGO_TOKEN
    nohup cloudflared tunnel run --token "$ARGO_TOKEN" >/tmp/argo.log 2>&1 &
  else
    nohup cloudflared tunnel --url "http://localhost:$XRAY_PORT" --no-autoupdate >/tmp/argo.log 2>&1 &
  fi

  # 等待域名生成
  for i in {1..10}; do
    sleep 2
    domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo.log | tail -n1)
    if [ -n "$domain" ]; then
      ARGO_DOMAIN="${domain#https://}"
      break
    fi
  done

  if [ -z "$ARGO_DOMAIN" ]; then
    echo "❌ 未能获取 Argo 域名，请检查 cloudflared 是否成功启动"
    exit 1
  fi

  # 更新配置文件，写入域名
  write_config
  pkill -f xray || true
  nohup xray -c $CONFIG_FILE >/dev/null 2>&1 &
}

# 输出链接
print_link() {
  json=$(cat <<JSON
{
  "v": "2",
  "ps": "vmess-argo",
  "add": "$ARGO_DOMAIN",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$ARGO_DOMAIN",
  "path": "$WS_PATH",
  "tls": "tls"
}
JSON
)
  link="vmess://$(echo -n "$json" | base64 -w0)"
  echo "====================================="
  echo "UUID: $UUID"
  echo "WS_PATH: $WS_PATH"
  echo "Argo 域名: https://$ARGO_DOMAIN"
  echo "客户端导入链接:"
  echo "$link"
  echo "====================================="
}

# 卸载
uninstall_all() {
  echo "正在卸载 Xray + Argo..."
  killall xray 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -rf $WORK_DIR
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/cloudflared
  rm -f /tmp/argo.log
  echo "卸载完成！"
}

# 菜单
menu() {
  echo "===== Xray + Argo 管理 ====="
  echo "1. 安装并启动 (生成一键链接)"
  echo "2. 卸载"
  echo "0. 退出"
  read -p "请选择操作: " choice
  case "$choice" in
    1) install_deps; install_xray; install_cloudflared; start_services; print_link ;;
    2) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

menu

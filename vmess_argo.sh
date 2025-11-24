#!/bin/bash
set -e

WORK_DIR="/etc/xray"
CONFIG_FILE="$WORK_DIR/config.json"
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
XRAY_PORT=${XRAY_PORT:-10080}
WS_PATH=${WS_PATH:-/vmess}
ARGO_DOMAIN=""

info() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

install_deps() {
  info "安装依赖..."
  if ! command -v curl >/dev/null; then
    apt update -y && apt install -y curl unzip || yum install -y curl unzip
  fi
}

install_xray() {
  info "安装 Xray..."
  arch=$(uname -m)
  case "$arch" in
    x86_64) dl_arch="64" ;;
    aarch64) dl_arch="arm64-v8a" ;;
    *) dl_arch="64" ;;
  esac
  mkdir -p $WORK_DIR
  curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$dl_arch.zip" -o xray.zip
  unzip -qo xray.zip -d $WORK_DIR && rm xray.zip
  install -m 755 $WORK_DIR/xray /usr/local/bin/xray
}

install_cloudflared() {
  info "安装 Cloudflared..."
  arch=$(uname -m)
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  [ "$arch" = "aarch64" ] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  curl -fsSL "$url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

write_config() {
  cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "$WS_PATH",
        "headers": { "Host": "$ARGO_DOMAIN" }
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

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

  for i in {1..20}; do
    sleep 2
    domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo.log | tail -n1)
    if [ -n "$domain" ]; then
      ARGO_DOMAIN="${domain#https://}"
      break
    fi
  done

  if [ -z "$ARGO_DOMAIN" ]; then
    error "未能获取 Argo 域名，请检查 cloudflared 是否成功启动"
    exit 1
  fi

  info "成功获取 Argo 域名: https://$ARGO_DOMAIN"

  write_config
  killall xray 2>/dev/null || true
  nohup xray -c $CONFIG_FILE >/dev/null 2>&1 &

  # 自动启动守护进程
  watchdog &
}

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
  info "UUID: $UUID"
  info "WS_PATH: $WS_PATH"
  info "Argo 域名: https://$ARGO_DOMAIN"
  info "客户端导入链接:"
  echo "$link"
  echo "====================================="
}

diagnose() {
  echo "===== 自动诊断 ====="
  echo "1. 检查本地 Xray 入站..."
  if curl -s http://127.0.0.1:$XRAY_PORT$WS_PATH >/dev/null; then
    info "Xray 入站正常"
  else
    error "Xray 入站无法访问，请检查是否启动或端口是否开放"
  fi

  echo "2. 检查 Argo 隧道 (完整路径)..."
  if curl -vk https://$ARGO_DOMAIN$WS_PATH >/dev/null 2>&1; then
    info "Argo 隧道转发正常"
  else
    error "Argo 隧道无法转发，请检查 cloudflared 是否运行或配置是否匹配"
  fi

  echo "3. 客户端配置提示："
  echo "   地址: $ARGO_DOMAIN"
  echo "   端口: 443"
  echo "   UUID: $UUID"
  echo "   路径: $WS_PATH"
  echo "   TLS: 开启"
  echo "   Host/SNI: $ARGO_DOMAIN"
  echo "====================="
}

clean_logs() {
  warn "执行日志清理..."
  : > /tmp/argo.log
  info "已清理 /tmp/argo.log"
  journalctl --vacuum-time=7d >/dev/null 2>&1 || true
  info "已清理 7 天前的系统日志"
}

watchdog() {
  counter=0
  while true; do
    sleep 30
    counter=$((counter+30))

    if ! pgrep -x "xray" >/dev/null; then
      warn "检测到 Xray 已停止，正在重启..."
      nohup xray -c $CONFIG_FILE >/dev/null 2>&1 &
    fi
    if ! pgrep -x "cloudflared" >/dev/null; then
      warn "检测到 Cloudflared 已停止，正在重启..."
      nohup cloudflared tunnel --url "http://localhost:$XRAY_PORT" --no-autoupdate >/tmp/argo.log 2>&1 &
    fi

    if [ $counter -ge 21600 ]; then
      clean_logs
      counter=0
    fi
  done
}

setup_systemd() {
  info "正在生成 systemd 服务文件..."
  cat > /etc/systemd/system/vmess-argo.service <<EOF
[Unit]
Description=VMess + Argo Tunnel 自愈脚本
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /root/vmess_argo.sh
Restart=always
RestartSec=10
User=root
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
EOF

  info "注册开机自启..."
  systemctl daemon-reload
  systemctl enable vmess-argo.service
  systemctl restart vmess-argo.service
  info "systemd 服务已安装并启用开机自启"
}

uninstall_all() {
  warn "正在卸载 Xray + Argo..."
  killall xray 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -rf $WORK_DIR
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/cloudflared
  rm -f /tmp/argo.log
  rm -f /etc/systemd/system/vmess-argo.service
  systemctl daemon-reload
  info "卸载完成！"
}

menu() {
  echo "===== Xray + Argo 管理 ====="
  echo "1. 安装并启动 (自动诊断 + 自动守护 + 日志清理 + 开机自启)"
  echo "2. 卸载"
  echo "0. 退出"
  read -p "请选择操作: " choice
  case "$choice" in
    1) install_deps; install_xray; install_cloudflared; start_services; print_link; diagnose; setup_systemd ;;
    2) uninstall_all ;;
    0) exit 0 ;;
    *) error "无效选择" ;;
  esac
}

menu

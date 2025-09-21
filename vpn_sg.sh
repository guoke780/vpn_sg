#!/bin/bash
# 自动化双向 Peer + Xray 安装脚本
# 支持新加坡出口机 + 香港中转机
# 可选 WireGuard 握手检测
# 安全测试版，不修改默认路由，SSH 不会断

set -e

echo "请选择角色:"
echo "1) 出口机 (新加坡)"
echo "2) 中转机 (香港)"
read -p "输入数字 [1-2]: " ROLE

# 配置路径
WG_CONFIG="/etc/wireguard/wg0.conf"
X_CONFIG="/usr/local/etc/xray/config.json"

# 安装基础依赖
apt update && apt install -y wireguard qrencode curl ufw iproute2 iputils-ping jq certbot unzip

if [ "$ROLE" == "1" ]; then
  # ===== 出口机（新加坡） =====
  PRIVATE_KEY=$(wg genkey)
  PUBLIC_KEY=$(echo $PRIVATE_KEY | wg pubkey)

  mkdir -p /etc/wireguard
  cat <<EOF >$WG_CONFIG
[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE_KEY
ListenPort = 51820
EOF

  systemctl enable wg-quick@wg0
  systemctl start wg-quick@wg0
  ufw allow 51820/udp || true

  echo "==============================="
  echo "新加坡出口配置完成"
  echo "PublicKey: $PUBLIC_KEY"
  echo "请复制此公钥，在香港 VPS 配置时输入"
  echo "==============================="

  # 可选回填中转机公钥
  read -p "如果已有香港 VPS 公钥，输入以加入 Peer（留空跳过）: " HK_PUB
  if [ -n "$HK_PUB" ]; then
    echo -e "\n[Peer]\nPublicKey = $HK_PUB\nAllowedIPs = 10.0.0.2/32\nPersistentKeepalive = 25" >> $WG_CONFIG
    wg-quick down wg0
    wg-quick up wg0
    echo "已加入香港 VPS Peer，WireGuard 重启完成"
  fi

elif [ "$ROLE" == "2" ]; then
  # ===== 中转机（香港） =====
  read -p "请输入新加坡 VPS 公钥: " SG_PUB
  read -p "请输入新加坡 VPS 公网IP: " SG_IP
  read -p "请输入香港 VPS 域名: " DOMAIN

  PRIVATE_KEY=$(wg genkey)
  PUB_KEY=$(echo $PRIVATE_KEY | wg pubkey)

  mkdir -p /etc/wireguard
  cat <<EOF >$WG_CONFIG
[Interface]
Address = 10.0.0.2/24
PrivateKey = $PRIVATE_KEY
ListenPort = 51820

[Peer]
PublicKey = $SG_PUB
Endpoint = $SG_IP:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
EOF

  systemctl enable wg-quick@wg0
  wg-quick up wg0
  ufw allow 51820/udp || true

  # ===== 可选握手检测 =====
  echo "是否要检测 WireGuard 握手？"
  echo "1) 检测"
  echo "2) 跳过"
  read -p "输入数字 [1-2]: " TEST_WG

  if [ "$]()

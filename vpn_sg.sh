#!/bin/bash
# 半自动双向 Peer + Xray 安装脚本
# 出口机：安装检查 WireGuard + 公钥 + 可选添加中转机 Peer
# 中转机：显示自身公钥手动回填出口机 Peer，继续 WireGuard + 可选握手检测 + Xray/TLS

set -e

echo "请选择角色:"
echo "1) 出口机 (新加坡)"
echo "2) 中转机 (香港)"
read -p "输入数字 [1-2]: " ROLE

WG_CONFIG="/etc/wireguard/wg0.conf"
X_CONFIG="/usr/local/etc/xray/config.json"

# 安装依赖
apt update && apt install -y wireguard qrencode curl ufw iproute2 iputils-ping jq certbot unzip

if [ "$ROLE" == "1" ]; then
  # ===== 出口机（新加坡） =====
  if ! command -v wg &>/dev/null; then
    echo "WireGuard 未安装，正在安装..."
    apt install -y wireguard ufw
  fi

  mkdir -p /etc/wireguard

  if [ -f "$WG_CONFIG" ]; then
    PRIVATE_KEY=$(grep "PrivateKey" $WG_CONFIG | awk '{print $3}')
    PUBLIC_KEY=$(echo $PRIVATE_KEY | wg pubkey)
    echo "WireGuard 已安装，当前 PublicKey: $PUBLIC_KEY"
  else
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo $PRIVATE_KEY | wg pubkey)
    cat <<EOF >$WG_CONFIG
[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE_KEY
ListenPort = 51820
EOF
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    ufw allow 51820/udp || true
    echo "WireGuard 配置已生成，PublicKey: $PUBLIC_KEY"
  fi

  # 可选回填中转机 Peer
  read -p "是否要添加中转机公钥作为 Peer？(y/n): " ADD_PEER
  if [[ "$ADD_PEER" =~ ^[Yy]$ ]]; then
    read -p "请输入中转机公钥: " HK_PUB
    if grep -q "$HK_PUB" "$WG_CONFIG"; then
      echo "Peer 已存在，无需重复添加"
    else
      echo -e "\n[Peer]\nPublicKey = $HK_PUB\nAllowedIPs = 10.0.0.2/32\nPersistentKeepalive = 25" >> $WG_CONFIG
      wg-quick down wg0
      wg-quick up wg0
      echo "已添加中转机 Peer，WireGuard 重启完成"
    fi
  fi

  echo "出口机配置完成"
  echo "PublicKey: $PUBLIC_KEY"

elif [ "$ROLE" == "2" ]; then
  # ===== 中转机（香港 VPS） =====
  read -p "请输入新加坡 VPS 公钥: " SG_PUB
  read -p "请输入新加坡 VPS 公网IP: " SG_IP
  read -p "请输入香港 VPS 域名: " DOMAIN

  PRIVATE_KEY=$(wg genkey)
  PUB_KEY=$(echo $PRIVATE_KEY | wg pubkey)

  echo "==============================="
  echo "中转机 WireGuard 公钥已生成:"
  echo "$PUB_KEY"
  echo "请手动将此公钥填写到出口机的 Peer 配置后再继续"
  echo "按 Enter 继续..."
  read -p ""

  # 生成本机 WireGuard 配置
  mkdir -p /etc/wireguard
  cat <<EOF >/etc/wireguard/wg0.conf
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

  if [ "$TEST_WG" == "1" ]; then
    echo "正在测试到新加坡出口的连通性..."
    success=false
    for i in {1..5}; do
      if ping -c 1 10.0.0.1 &>/dev/null; then
        echo "Ping 成功 ✅ 到 10.0.0.1（新加坡出口）"
        success=true
        break
      else
        echo "Ping 第 $i 次失败，重试..."
        sleep 1
      fi
    done
    if [ "$success" = false ]; then
      echo "⚠️ 隧道可能未建立，请检查防火墙或 Peer 配置"
    fi

    echo "WireGuard 握手信息（香港 VPS 对新加坡出口）:"
    wg show wg0 latest-handshakes
  else
    echo "已跳过 WireGuard 握手检测"
  fi

  # ===== Xray/TLS 部分 =====
  certbot certonly --standalone -d $DOMAIN --agree-tos --email admin@$DOMAIN --non-interactive
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  echo "0 3 * * * root certbot renew --post-hook 'systemctl restart xray'" >> /etc/crontab

  bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
  UUID=$(cat /proc/sys/kernel/random/uuid)

  mkdir -p $(dirname $X_CONFIG)
  cat <<EOF >$X_CONFIG
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients":[{"id":"$UUID","flow":"xtls-rprx-direct"}],
        "decryption":"none"
      },
      "streamSettings": {
        "network":"tcp",
        "security":"tls",
        "tlsSettings":{
          "certificates":[{"certificateFile":"$CERT_PATH","keyFile":"$KEY_PATH"}]
        }
      },
      "tag":"sg_port"
    }
  ],
  "outbounds": [
    {
      "protocol":"freedom",
      "settings":{},
      "tag":"sg_outbound"
    }
  ]
}
EOF

  systemctl restart xray
  ufw allow 443/tcp || true

  echo "==============================="
  echo "部署完成，UUID: $UUID"
  echo "新加坡出口 (端口 443)："
  echo "vless://$UUID@$DOMAIN:443?security=tls&encryption=none&flow=xtls-rprx-direct#SG" | qrencode -t utf8
  echo "==============================="

else
  echo "无效选项"
fi

#!/bin/bash
# 安全测试版：香港中转 + 新加坡出口
# 不修改默认路由，SSH 安全
# 单 UUID，多设备共用
# 带 WireGuard 隧道连通性测试 + 握手显示

set -e

echo "请选择角色:"
echo "1) 出口机 (新加坡)"
echo "2) 中转机 (香港)"
read -p "输入数字 [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
  # 出口机 (新加坡) 安装 WireGuard
  apt update && apt install -y wireguard
  PRIVATE_KEY=$(wg genkey)
  PUBLIC_KEY=$(echo $PRIVATE_KEY | wg pubkey)

  cat <<EOF >/etc/wireguard/wg0.conf
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
  echo "请复制到香港中转机脚本里使用"
  echo "==============================="

elif [ "$ROLE" == "2" ]; then
  # 中转机 (香港) 安装 WireGuard + Xray
  apt update && apt install -y wireguard curl qrencode ufw jq certbot iproute2 iputils-ping

  read -p "请输入新加坡 VPS 公钥: " SG_PUBLIC_KEY
  read -p "请输入新加坡 VPS 公网IP: " SG_IP
  read -p "请输入香港 VPS 域名: " DOMAIN

  # WireGuard 隧道
  PRIVATE_KEY_SG=$(wg genkey)
  cat <<EOF >/etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.2/24
PrivateKey = $PRIVATE_KEY_SG
ListenPort = 51820

[Peer]
PublicKey = $SG_PUBLIC_KEY
Endpoint = $SG_IP:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
EOF

  # 启动 WireGuard 隧道
  wg-quick up wg0
  systemctl enable wg-quick@wg0

  ufw allow 51820/udp || true
  echo "WireGuard 隧道启动完成，SSH 不会被切断"

  # ===== 隧道测试 =====
  echo "正在测试到新加坡出口的连通性..."
  for i in {1..5}; do
    if ping -c 1 10.0.0.1 &>/dev/null; then
      echo "Ping 成功 ✅ 到 10.0.0.1（新加坡出口）"
      break
    else
      echo "Ping 第 $i 次失败，重试..."
      sleep 1
    fi
    if [ "$i" -eq 5 ]; then
      echo "⚠️ 不能访问新加坡出口，WireGuard 隧道可能未建立"
    fi
  done

  # ===== WireGuard 握手状态 =====
  echo "WireGuard 握手信息（香港 VPS 对新加坡出口）:"
  wg show wg0 latest-handshakes

  # TLS 证书
  certbot certonly --standalone -d $DOMAIN --agree-tos --email admin@$DOMAIN --non-interactive
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  echo "0 3 * * * root certbot renew --post-hook 'systemctl restart xray'" >> /etc/crontab

  # 安装 Xray
  bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

  UUID=$(cat /proc/sys/kernel/random/uuid)

  # Xray 配置
  cat <<EOF >/etc/xray/config.json
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

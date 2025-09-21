#!/bin/bash
# 中转机部署脚本（香港 VPS）
# 功能: 安装Xray + WS + TLS，作为客户端的伪装入口，并转发流量到出口机

set -e
XRAY_CONFIG="/usr/local/etc/xray/config.json"

echo "===== 中转机部署 (香港 VPS) ====="
read -p "请输入中转机绑定的域名: " DOMAIN
read -p "请输入出口机的公网IP: " EXIT_IP

# 1. 安装依赖
apt update -y
apt install -y curl wget unzip socat ufw

# 2. 安装 Xray (如已安装则跳过)
if ! command -v xray >/dev/null 2>&1; then
    echo "安装 Xray..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
else
    echo "检测到 Xray 已安装，跳过安装步骤"
fi

# 3. 申请 TLS 证书
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "申请 TLS 证书..."
    apt install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive
else
    echo "检测到已有证书，跳过申请步骤"
fi

CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

# 4. 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 5. 写入 Xray 配置
mkdir -p /usr/local/etc/xray
cat > $XRAY_CONFIG <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$CERT_PATH",
              "keyFile": "$KEY_PATH"
            }
          ]
        },
        "wsSettings": {
          "path": "/proxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$EXIT_IP",
            "port": 8443,
            "users": [ { "id": "$UUID" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/proxy"
        }
      }
    }
  ]
}
EOF

# 6. 启动服务
systemctl enable xray
systemctl restart xray

# 7. 防火墙放行
ufw allow 443/tcp || true

echo "===== 部署完成 ====="
echo "客户端连接信息 (导入 Shadowrocket/v2rayN)："
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=/proxy#HK-Relay"

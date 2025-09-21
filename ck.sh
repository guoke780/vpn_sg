#!/bin/bash
# 出口机部署脚本（新加坡 VPS）
# 功能: 安装Xray，监听来自中转机的流量，然后直接放行到互联网

set -e
XRAY_CONFIG="/usr/local/etc/xray/config.json"

echo "===== 出口机部署 (新加坡 VPS) ====="
read -p "请输入与中转机相同的 UUID: " UUID

# 1. 安装依赖
apt update -y
apt install -y curl wget unzip ufw

# 2. 安装 Xray (如已安装则跳过)
if ! command -v xray >/dev/null 2>&1; then
    echo "安装 Xray..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
else
    echo "检测到 Xray 已安装，跳过安装步骤"
fi

# 3. 写入配置
mkdir -p /usr/local/etc/xray
cat > $XRAY_CONFIG <<EOF
{
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/proxy"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# 4. 启动服务
systemctl enable xray
systemctl restart xray

# 5. 防火墙放行
ufw allow 8443/tcp || true

echo "===== 出口机已部署完成 ====="
echo "监听端口: 8443"

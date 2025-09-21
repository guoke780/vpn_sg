#!/bin/bash
# 一键部署 WireGuard + Xray/TLS（出口机/中转机统一脚本）
# 特性：
# - WireGuard 自动安装
# - 半自动公钥填写
# - 可选握手检测
# - Xray 下载失败自动切换备用地址
# - 使用 wget 下载 Xray 安装脚本

set -e

ROLE=""
WG_CONFIG="/etc/wireguard/wg0.conf"
X_CONFIG="/usr/local/etc/xray/config.json"

echo "===== WireGuard + Xray 一键部署 ====="
echo "请选择当前机器角色："
echo "1) 出口机（新加坡 VPS）"
echo "2) 中转机（香港 VPS）"
read -p "输入数字 [1-2]: " ROLE

# 安装依赖
apt update && apt install -y wireguard qrencode wget ufw iproute2 iputils-ping jq certbot unzip

# WireGuard 密钥
PRIVATE_KEY=$(wg genkey)
PUB_KEY=$(echo $PRIVATE_KEY | wg pubkey)

# ===== 安装 Xray 函数（wget 版） =====
install_xray() {
    echo "正在下载 Xray 官方安装脚本..."
    ATTEMPTS=0
    PRIMARY="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
    BACKUP="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

    while [ $ATTEMPTS -lt 3 ]; do
        # 尝试主地址
        wget -qO /tmp/install-xray.sh --header="User-Agent: Mozilla/5.0" $PRIMARY
        if head -n 1 /tmp/install-xray.sh | grep -q '^#!/bin/bash'; then
            echo "主地址下载成功 ✅"
            bash /tmp/install-xray.sh
            return
        fi

        # 尝试备用地址
        echo "主地址下载失败，尝试备用地址..."
        wget -qO /tmp/install-xray.sh --header="User-Agent: Mozilla/5.0" $BACKUP
        if head -n 1 /tmp/install-xray.sh | grep -q '^#!/bin/bash'; then
            echo "备用地址下载成功 ✅"
            bash /tmp/install-xray.sh
            return
        fi

        ATTEMPTS=$((ATTEMPTS+1))
        echo "下载失败，重试第 $ATTEMPTS 次..."
        sleep 2
    done

    echo "❌ Xray 安装脚本下载失败，请检查网络或手动下载安装"
    exit 1
}

# ===== 出口机部署 =====
if [ "$ROLE" == "1" ]; then
    echo "===== 出口机部署 ====="
    echo "出口机 WireGuard 公钥: $PUB_KEY"
    read -p "请输入中转机 WireGuard 公钥（手动填写，可留空稍后添加）: " PEER_PUB
    read -p "请输入出口机监听端口（默认 51820）: " WG_PORT
    WG_PORT=${WG_PORT:-51820}

    mkdir -p /etc/wireguard
    cat <<EOF >$WG_CONFIG
[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE_KEY
ListenPort = $WG_PORT
EOF

    if [ -n "$PEER_PUB" ]; then
        read -p "请输入中转机 WireGuard 内网 IP (例: 10.0.0.2): " PEER_IP
        cat <<EOF >>$WG_CONFIG

[Peer]
PublicKey = $PEER_PUB
AllowedIPs = $PEER_IP/32
PersistentKeepalive = 25
EOF
    fi

    # 启动 WireGuard
    if ip link show wg0 &>/dev/null; then
        echo "检测到 wg0 接口已存在，正在删除..."
        ip link delete wg0
    fi
    wg-quick up wg0
    systemctl enable wg-quick@wg0
    ufw allow $WG_PORT/udp || true
    echo "WireGuard 出口机已启动"

# ===== 中转机部署 =====
else
    echo "===== 中转机部署 ====="
    read -p "请输入出口机 WireGuard 公钥: " SG_PUB
    read -p "请输入出口机公网 IP: " SG_IP
    read -p "请输入香港 VPS 域名: " DOMAIN

    echo "中转机 WireGuard 公钥: $PUB_KEY"
    echo "请手动将此公钥填写到出口机 Peer 后再继续"
    read -p "按 Enter 继续..."

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

    # 清理残留接口
    if ip link show wg0 &>/dev/null; then
        echo "检测到 wg0 接口已存在，正在删除..."
        ip link delete wg0
    fi

    wg-quick up wg0
    systemctl enable wg-quick@wg0
    ufw allow 51820/udp || true
    echo "WireGuard 中转机已启动"

    # 可选握手检测
    echo "是否要检测 WireGuard 握手？"
    echo "1) 检测"
    echo "2) 跳过"
    read -p "输入数字 [1-2]: " TEST_WG
    if [ "$TEST_WG" == "1" ]; then
        echo "正在测试到出口机连通性..."
        success=false
        for i in {1..5}; do
            if ping -c 1 10.0.0.1 &>/dev/null; then
                echo "Ping 成功 ✅ 到 10.0.0.1"
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
        echo "WireGuard 最新握手信息:"
        wg show wg0 latest-handshakes
    else
        echo "已跳过握手检测"
    fi

    # 安装 Xray
    install_xray

    UUID=$(cat /proc/sys/kernel/random/uuid)
    mkdir -p $(dirname $X_CONFIG)

    certbot certonly --standalone -d $DOMAIN --agree-tos --email admin@$DOMAIN --non-interactive
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    chmod 644 $CERT_PATH $KEY_PATH

    # 写入 Xray 配置
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

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    ufw allow 443/tcp || true

    sleep 2
    if ss -tlnp | grep -q 443; then
        echo "[OK] Xray 已成功监听 443"
    else
        echo "[❌] Xray 未监听 443，请检查配置文件和证书"
    fi

    echo "==============================="
    echo "部署完成，UUID: $UUID"
    echo "新加坡出口 (端口 443)："
    echo "vless://$UUID@$DOMAIN:443?security=tls&encryption=none&flow=xtls-rprx-direct#SG" | qrencode -t utf8
    echo "==============================="
fi

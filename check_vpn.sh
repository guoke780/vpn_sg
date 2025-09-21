#!/bin/bash
# WireGuard + Xray 一键排查脚本
# 支持出口机和中转机
set -e

echo "===== 一键排查 WireGuard + Xray ====="

# 1️⃣ 检查 WireGuard 接口
if ip link show wg0 &>/dev/null; then
    echo "[OK] wg0 接口存在"
else
    echo "[❌] wg0 接口不存在，请启动 WireGuard"
fi

# 2️⃣ 显示 WireGuard 状态
echo "===== WireGuard 状态 ====="
wg show

# 3️⃣ 测试 Peer 内网连通性
read -p "请输入对端 WireGuard 内网 IP (如出口机: 10.0.0.1 / 中转机: 10.0.0.2): " PEER_IP
echo "正在 ping 对端 WireGuard IP $PEER_IP..."
if ping -c 3 $PEER_IP &>/dev/null; then
    echo "[OK] 内网 ping 通"
else
    echo "[❌] 内网 ping 不通，请检查 Peer 配置和防火墙"
fi

# 4️⃣ 检查 Xray 服务状态 (仅 TCP 443)
echo "===== Xray 服务状态 ====="
if systemctl is-active --quiet xray; then
    echo "[OK] Xray 服务正在运行"
else
    echo "[❌] Xray 服务未运行"
fi

# 5️⃣ 检查端口监听
echo "===== 端口监听检查 ====="
echo "UDP 51820 (WireGuard) 状态:"
ss -u -lnp | grep 51820 || echo "[❌] UDP 51820 未监听"

echo "TCP 443 (Xray/TLS) 状态:"
ss -t -lnp | grep 443 || echo "[❌] TCP 443 未监听"

# 6️⃣ 建议
echo "===== 检查完成 ====="
echo "✔️ 如果 wg0 存在且 latest handshake 有时间戳，并且 ping 通对端内网 IP → WireGuard 隧道正常"
echo "✔️ 如果 TCP 443 监听正常且 Xray 服务 active → Shadowrocket 应能连接"
echo "❌ 若 ping 不通或握手未更新 → 检查 Peer 配置和防火墙"

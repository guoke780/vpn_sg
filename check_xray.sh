#!/bin/bash
# 一键检查 Xray 安装和启动状态

XRAY_CONFIG="/usr/local/etc/xray/config.json"

echo "===== 检查 Xray 安装 ====="
if ! command -v xray >/dev/null 2>&1; then
    echo "❌ Xray 未安装，请先安装 Xray"
    exit 1
fi
echo "✅ Xray 已安装"

echo "===== 检查配置文件 ====="
if [ ! -f "$XRAY_CONFIG" ]; then
    echo "❌ 配置文件不存在：$XRAY_CONFIG"
    exit 1
fi
echo "✅ 配置文件存在"

echo "===== 检查 systemd 服务 ====="
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

STATUS=$(systemctl is-active xray)
if [ "$STATUS" = "active" ]; then
    echo "✅ Xray 服务已启动"
    echo "端口监听情况："
    ss -tlpn | grep xray || echo "未找到监听端口，检查配置文件端口"
else
    echo "❌ Xray 启动失败，请查看日志:"
    journalctl -u xray -n 20 --no-pager
fi

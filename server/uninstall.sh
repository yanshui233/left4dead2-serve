#!/usr/bin/env bash
# ============================================================
# 卸载 L4D2 专用服务器（在 ECS 上以 root 执行）
# 用途: 释放磁盘前清干净，或重装前彻底重置
# 用法: bash uninstall.sh
#       KEEP_USER=1 bash uninstall.sh   # 保留 steam 用户
# ============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/l4d2}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
STEAM_USER="${STEAM_USER:-steam}"
SERVICE_NAME="${SERVICE_NAME:-l4d2ds}"
KEEP_USER="${KEEP_USER:-0}"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "请用 root 执行"; exit 1; }

log "停止并禁用 $SERVICE_NAME"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload || true
systemctl reset-failed 2>/dev/null || true

log "删除服务端文件 $INSTALL_DIR"
rm -rf "$INSTALL_DIR"

log "删除 SteamCMD $STEAMCMD_DIR"
rm -rf "$STEAMCMD_DIR"

if [ "$KEEP_USER" != "1" ] && id -u "$STEAM_USER" >/dev/null 2>&1; then
  log "删除运行用户 $STEAM_USER"
  pkill -u "$STEAM_USER" 2>/dev/null || true
  sleep 1
  userdel -r "$STEAM_USER" 2>/dev/null || userdel "$STEAM_USER" 2>/dev/null || true
fi

log "清理完成"
df -h / | tail -n1
echo
echo "提示: 已释放约 12-15 GB。彻底停止计费请在阿里云控制台【释放实例】。"

#!/bin/bash
# GameGuard 在线升级（沿用已保存的配置地址）
# 用法：curl -fsSL https://raw.githubusercontent.com/fuqiangleon/gameguard/main/mac/update.sh | sudo bash
set -e
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
BASE="https://raw.githubusercontent.com/fuqiangleon/gameguard/main/mac"
TMP=$(mktemp -d /tmp/gameguard-update.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
for f in gameguard.sh install.sh com.gameguard.plist gameguard-config-example.txt; do
  echo "下载 $f"
  curl -fsSL --max-time 30 --proto '=https' "$BASE/$f?t=$(date +%s)" -o "$TMP/$f"
done
bash -n "$TMP/gameguard.sh" && bash -n "$TMP/install.sh" || { echo "下载的文件不完整，已取消升级"; exit 1; }
grep -q '^<?xml' "$TMP/com.gameguard.plist" || { echo "下载的文件不完整，已取消升级"; exit 1; }
bash "$TMP/install.sh"

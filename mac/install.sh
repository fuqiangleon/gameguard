#!/bin/bash
# 安装：  sudo ./install.sh "https://你的配置地址/gameguard.txt" [访问令牌]
# 改地址：重新运行上面的命令即可
# 卸载：  sudo ./install.sh uninstall
set -e
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchDaemons/com.gameguard.plist
CONF=/usr/local/etc/gameguard.conf

if [ "$1" = "uninstall" ]; then
  launchctl bootout system "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" /usr/local/bin/gameguard.sh "$CONF"
  rm -rf /var/db/gameguard
  echo "已卸载。日志保留在 /var/log/gameguard.log"
  exit 0
fi

URL="$1"; TOKEN="$2"
if [ -n "$URL" ] && [ "${URL#https://}" = "$URL" ]; then
  echo "配置地址必须是 https:// 开头"; exit 1
fi

mkdir -p /usr/local/bin /usr/local/etc
install -o root -g wheel -m 755 "$DIR/gameguard.sh" /usr/local/bin/gameguard.sh
install -o root -g wheel -m 644 "$DIR/com.gameguard.plist" "$PLIST"

umask 077
cat > "$CONF" <<EOF
CONFIG_URL="$URL"
AUTH_TOKEN="$TOKEN"
REFRESH_SECONDS=300
EOF
chown root:wheel "$CONF"; chmod 600 "$CONF"
rm -f /var/db/gameguard/config.cache

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "已安装，每分钟检查一次，每 5 分钟拉取一次网络配置。"
[ -z "$URL" ] && echo "注意：没有填写配置地址，将使用内置默认规则（全天禁止）。"
echo
/usr/local/bin/gameguard.sh --show

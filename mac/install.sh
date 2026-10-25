#!/bin/bash
# 首次安装：sudo ./install.sh "https://gist.githubusercontent.com/<用户名>/<gist id>/raw/gameguard.txt"
# 更新脚本：sudo ./install.sh            （不填地址则沿用已保存的配置地址）
# 卸载：    sudo ./install.sh uninstall
set -e
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchDaemons/com.gameguard.plist
CONF=/usr/local/etc/gameguard.conf
MARK_BEGIN="# >>> GameGuard 网站屏蔽（自动生成，请勿手动修改） >>>"
MARK_END="# <<< GameGuard <<<"

if [ "$1" = "uninstall" ]; then
  launchctl bootout system "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" /usr/local/bin/gameguard.sh "$CONF"
  rm -rf /var/db/gameguard
  # 移除 hosts 里的网站屏蔽
  if grep -qF "$MARK_BEGIN" /etc/hosts; then
    tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{f=1;next} $0==e{f=0;next} !f' /etc/hosts > "$tmp"
    cat "$tmp" > /etc/hosts; rm -f "$tmp"
    dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
  fi
  for f in /etc/resolver/*; do
    [ -f "$f" ] && head -1 "$f" | grep -qF "# GameGuard" && rm -f "$f"
  done
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
  for dom in com.google.Chrome com.microsoft.Edge com.brave.Browser; do
    defaults delete "/Library/Managed Preferences/$dom" DnsOverHttpsMode 2>/dev/null || true
  done
  echo "已卸载。日志保留在 /var/log/gameguard.log"
  exit 0
fi

URL="$1"; TOKEN="$2"
if [ -z "$URL" ] && [ -f "$CONF" ]; then
  . "$CONF"; URL="$CONFIG_URL"; TOKEN="$AUTH_TOKEN"
  echo "沿用已保存的配置地址：$URL"
fi
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

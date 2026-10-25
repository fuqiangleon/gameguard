#!/bin/bash
# gameguard.sh —— 按网络配置检测并结束游戏进程（macOS）
#
# 由 launchd 以 root 身份每分钟运行一次。
# 配置地址写在 /usr/local/etc/gameguard.conf（只有 root 能读写）：
#     CONFIG_URL="https://.../gameguard.txt"
#     AUTH_TOKEN=""          # 可选，作为 Authorization: Bearer 发送
#     REFRESH_SECONDS=60     # 可选，多久拉取一次网络配置（秒）
#
# 手动测试（只检测、不结束）：  sudo /usr/local/bin/gameguard.sh --dry-run
# 查看当前生效的配置：         sudo /usr/local/bin/gameguard.sh --show

MODE="run"
case "$1" in --dry-run) MODE="dry" ;; --show) MODE="show" ;; esac

LOCAL_CONF=/usr/local/etc/gameguard.conf
STATE_DIR=/var/db/gameguard
CACHE=$STATE_DIR/config.cache
LOG=/var/log/gameguard.log

CONFIG_URL=""
AUTH_TOKEN=""
REFRESH_SECONDS=60
[ -f "$LOCAL_CONF" ] && . "$LOCAL_CONF"     # 本地文件只有 root 可写

# 网络配置拿不到、也没有缓存时使用的默认规则（全天禁止）
DEFAULT_CONFIG='enabled=true
block=RobloxPlayer
block=RobloxStudio
block=Roblox.app
block=Minecraft.app
block=minecraft-launcher
block=net.minecraft
block=Minecraft Education
message=现在不是游戏时间，游戏已被关闭。'

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; [ "$MODE" != "run" ] && echo "$*"; }

# ---------- 1. 拉取网络配置（按间隔刷新，失败就沿用缓存） ----------
need_refresh=1
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  [ "$age" -lt "$REFRESH_SECONDS" ] && need_refresh=0
fi
[ "$MODE" != "run" ] && need_refresh=1

if [ -n "$CONFIG_URL" ] && [ $need_refresh -eq 1 ]; then
  tmp=$(mktemp "$STATE_DIR/dl.XXXXXX")
  hdr=()
  [ -n "$AUTH_TOKEN" ] && hdr=(-H "Authorization: Bearer $AUTH_TOKEN")
  ok=0
  # 优先走 GitHub API（没有 CDN 缓存，保存后约 1 分钟生效）；失败再用 raw 地址（可能有约 5 分钟缓存）
  gid=$(echo "$CONFIG_URL" | sed -nE 's#^https://gist\.githubusercontent\.com/[^/]+/([0-9a-fA-F]+)/raw/.*#\1#p')
  gfile=${CONFIG_URL##*/}; gfile=${gfile%%\?*}
  if [ -n "$gid" ] && curl -fsSL --max-time 15 --proto '=https' "${hdr[@]}" \
          -H "Accept: application/vnd.github+json" "https://api.github.com/gists/$gid" -o "$tmp.json" \
     && osascript -l JavaScript -e 'ObjC.import("Foundation");
function run(a){var s=$.NSString.stringWithContentsOfFileEncodingError(a[0],$.NSUTF8StringEncoding,null).js;
var f=JSON.parse(s).files||{};var x=f[a[1]]||f[Object.keys(f)[0]];return (x&&!x.truncated)?x.content:"";}' \
          "$tmp.json" "$gfile" > "$tmp" 2>/dev/null \
     && grep -q '^enabled=' "$tmp"; then
    ok=1
  elif curl -fsSL --max-time 15 --proto '=https' "${hdr[@]}" \
          -H "Cache-Control: no-cache" "$CONFIG_URL?t=$(date +%s)" -o "$tmp" \
     && grep -q '^enabled=' "$tmp"; then
    ok=1
  fi
  rm -f "$tmp.json"
  if [ $ok -eq 1 ] && [ "$(wc -c < "$tmp")" -lt 65536 ]; then
    if ! cmp -s "$tmp" "$CACHE"; then
      mv "$tmp" "$CACHE"; chmod 600 "$CACHE"
      log "已更新网络配置"
    else
      rm -f "$tmp"; touch "$CACHE"
    fi
  else
    rm -f "$tmp"
    log "拉取网络配置失败，沿用上次的配置"
    [ -f "$CACHE" ] && touch "$CACHE"      # 避免每分钟都重试刷屏
  fi
fi

if [ -f "$CACHE" ]; then CONFIG=$(cat "$CACHE"); SRC="网络配置（缓存）"; else CONFIG="$DEFAULT_CONFIG"; SRC="内置默认"; fi

# ---------- 2. 解析配置（只读取已知字段，不执行任何内容） ----------
ENABLED=true
MESSAGE="现在不是游戏时间，游戏已被关闭。"
ALLOW_UNTIL=""
ALLOWED=()
BLOCKS=()
SITES=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"                                    # 去掉注释
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r$//')"
  [ -z "$line" ] && continue
  key="${line%%=*}"; val="${line#*=}"
  case "$key" in
    enabled)     ENABLED="$val" ;;
    message)     MESSAGE="$val" ;;
    allow_until) ALLOW_UNTIL="$val" ;;
    allow)       echo "$val" | grep -Eq '^[1-7](,[1-7])* [0-9]{4} [0-9]{4}$' && ALLOWED+=("$val") ;;
    block)       [ ${#val} -ge 4 ] && BLOCKS+=("$val") ;;  # 太短的规则可能误杀，忽略
    site)        val=$(echo "$val" | tr 'A-Z' 'a-z' | sed -e 's#^[a-z]*://##' -e 's#/.*##' -e 's/^\*\.//' -e 's/^www\.//')
                 echo "$val" | grep -Eq '^([a-z0-9-]+\.)+[a-z]{2,}$' && SITES+=("$val") ;;
  esac
done <<< "$CONFIG"
[ ${#BLOCKS[@]} -eq 0 ] && while IFS= read -r l; do case "$l" in block=*) BLOCKS+=("${l#block=}");; esac; done <<< "$DEFAULT_CONFIG"

if [ "$MODE" = "show" ]; then
  echo "配置来源：$SRC   ${CONFIG_URL:+($CONFIG_URL)}"
  echo "enabled=$ENABLED"
  echo "allow_until=${ALLOW_UNTIL:-（无）}"
  for a in "${ALLOWED[@]}"; do echo "allow=$a"; done
  for b in "${BLOCKS[@]}"; do echo "block=$b"; done
  for s in "${SITES[@]}"; do echo "site=$s"; done
  echo "message=$MESSAGE"
fi

# ---------- 3. 判断现在是否允许 ----------
NOW_ALLOWED=0
STATE_TEXT="当前禁止游戏"
if [ "$ENABLED" = "false" ]; then
  NOW_ALLOWED=1; STATE_TEXT="管控已暂停"
fi
if [ $NOW_ALLOWED -eq 0 ] && [ -n "$ALLOW_UNTIL" ]; then
  until_ts=$(date -j -f "%Y-%m-%d %H:%M" "$ALLOW_UNTIL" +%s 2>/dev/null)
  if [ -n "$until_ts" ] && [ "$(date +%s)" -lt "$until_ts" ]; then
    NOW_ALLOWED=1; STATE_TEXT="临时放行中，直到 ${ALLOW_UNTIL}"
  fi
fi
if [ $NOW_ALLOWED -eq 0 ]; then
  dow=$(date +%u); now=$((10#$(date +%H%M)))
  for w in "${ALLOWED[@]}"; do
    read -r days s e <<< "$w"
    case ",$days," in *",$dow,"*)
      if [ "$now" -ge $((10#$s)) ] && [ "$now" -lt $((10#$e)) ]; then
        NOW_ALLOWED=1; STATE_TEXT="当前在允许时间段内（${w}）"; break
      fi ;;
    esac
  done
fi

# ---------- 4. 网站屏蔽：禁止时段写入 /etc/hosts，允许时段移除 ----------
HOSTS=/etc/hosts
MARK_BEGIN="# >>> GameGuard 网站屏蔽（自动生成，请勿手动修改） >>>"
MARK_END="# <<< GameGuard <<<"

build_hosts_block() {
  [ ${#SITES[@]} -eq 0 ] && return
  echo "$MARK_BEGIN"
  for s in "${SITES[@]}"; do
    for h in "$s" "www.$s"; do
      case "$h" in www.www.*) continue ;; esac
      echo "0.0.0.0 $h"
      echo ":: $h"
    done
  done | awk '!seen[$0]++'
  echo "$MARK_END"
}

current_block=$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{f=1} f{print} $0==e{f=0}' "$HOSTS")
if [ $NOW_ALLOWED -eq 0 ]; then wanted_block=$(build_hosts_block); else wanted_block=""; fi

# 子域名一并屏蔽：/etc/resolver/<域名> 让该域名及其所有子域名都交给一个不存在的 DNS 服务器，从而解析失败
RESOLVER_DIR=/etc/resolver
RESOLVER_MARK="# GameGuard"
sync_resolvers() {
  local changed=0 f name keep s
  mkdir -p "$RESOLVER_DIR"
  # 删除不再需要的（只删 GameGuard 自己创建的文件）
  for f in "$RESOLVER_DIR"/*; do
    [ -f "$f" ] || continue
    head -1 "$f" | grep -qF "$RESOLVER_MARK" || continue
    name=$(basename "$f"); keep=0
    if [ $NOW_ALLOWED -eq 0 ]; then for s in "${SITES[@]}"; do [ "$s" = "$name" ] && keep=1; done; fi
    [ $keep -eq 0 ] && { rm -f "$f"; changed=1; }
  done
  # 添加需要的（不覆盖别人已有的同名文件）
  if [ $NOW_ALLOWED -eq 0 ]; then
    for s in "${SITES[@]}"; do
      f="$RESOLVER_DIR/$s"
      [ -f "$f" ] && continue
      printf '%s\nnameserver 127.0.0.1\nport 9\ntimeout 1\n' "$RESOLVER_MARK" > "$f"; chmod 644 "$f"; changed=1
    done
  fi
  return $changed
}

if [ "$MODE" = "show" ]; then
  if [ -n "$wanted_block" ]; then echo "→ 网站屏蔽：生效中（${#SITES[@]} 个网站）"; else echo "→ 网站屏蔽：未生效"; fi
  echo "→ ${STATE_TEXT}"
  exit 0
fi

if [ "$current_block" != "$wanted_block" ]; then
  if [ "$MODE" = "dry" ]; then
    log "[测试] 需要更新 /etc/hosts 网站屏蔽（${#SITES[@]} 个网站）"
  else
    tmp_hosts=$(mktemp "$STATE_DIR/hosts.XXXXXX")
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{f=1;next} $0==e{f=0;next} !f' "$HOSTS" > "$tmp_hosts"
    [ -n "$wanted_block" ] && printf '%s\n' "$wanted_block" >> "$tmp_hosts"
    if [ -s "$tmp_hosts" ] && grep -q "localhost" "$tmp_hosts"; then   # 防止写坏系统 hosts
      cat "$tmp_hosts" > "$HOSTS"; chmod 644 "$HOSTS"
      dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
      if [ -n "$wanted_block" ]; then log "已启用网站屏蔽：${SITES[*]}"; else log "已解除网站屏蔽"; fi
    else
      log "生成的 hosts 文件异常，未写入"
    fi
    rm -f "$tmp_hosts"
  fi
fi

if [ "$MODE" = "run" ]; then
  if ! sync_resolvers; then
    dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  fi
fi

# 防止浏览器用“安全 DNS”绕过 hosts（Chrome / Edge / Brave / Firefox）
if [ "$MODE" = "run" ] && [ ${#SITES[@]} -gt 0 ]; then
  mkdir -p "/Library/Managed Preferences"
  for dom in com.google.Chrome com.microsoft.Edge com.brave.Browser; do
    defaults write "/Library/Managed Preferences/$dom" DnsOverHttpsMode -string off 2>/dev/null
  done
  for ff in /Applications/Firefox*.app $(ls -d /Users/*/Applications/Firefox*.app 2>/dev/null); do
    [ -d "$ff" ] || continue
    pol="$ff/Contents/Resources/distribution/policies.json"
    if [ ! -f "$pol" ]; then
      mkdir -p "$(dirname "$pol")"
      printf '{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}\n' > "$pol"
    fi
  done
  if [ ! -f "$STATE_DIR/doh-disabled" ]; then
    touch "$STATE_DIR/doh-disabled"
    log "已关闭浏览器的安全 DNS，防止绕过网站屏蔽（重启浏览器后生效）"
  fi
fi

[ $NOW_ALLOWED -eq 1 ] && exit 0

# ---------- 4. 查找并结束进程 ----------
killed=0
for pat in "${BLOCKS[@]}"; do
  for pid in $(pgrep -if -- "$pat"); do
    [ "$pid" = "$$" ] && continue
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$owner" ] && continue
    [ "$owner" = "root" ] && continue                  # 只处理普通用户的进程
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in *gameguard*) continue ;; esac
    if [ "$MODE" = "dry" ]; then
      log "[测试] 匹配“${pat}”：PID $pid ($owner) $cmd"
    else
      kill -9 "$pid" 2>/dev/null && { log "已结束 PID $pid ($owner)，匹配“${pat}”：$cmd"; killed=1; }
    fi
  done
done

# ---------- 5. 提示当前用户 ----------
if [ $killed -eq 1 ]; then
  user=$(stat -f%Su /dev/console)
  uid=$(id -u "$user" 2>/dev/null)
  if [ -n "$uid" ] && [ "$user" != "root" ]; then
    safe_msg=$(echo "$MESSAGE" | tr -d '"\\')
    launchctl asuser "$uid" sudo -u "$user" osascript -e \
      "display notification \"$safe_msg\" with title \"GameGuard\"" 2>/dev/null
  fi
fi

# 日志超过 1MB 时只保留最后 2000 行
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt 1048576 ]; then
  tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exit 0

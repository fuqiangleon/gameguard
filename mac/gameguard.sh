#!/bin/bash
# gameguard.sh —— 按网络配置检测并结束游戏进程（macOS）
#
# 由 launchd 以 root 身份每分钟运行一次。
# 配置地址写在 /usr/local/etc/gameguard.conf（只有 root 能读写）：
#     CONFIG_URL="https://.../gameguard.txt"
#     AUTH_TOKEN=""          # 可选，作为 Authorization: Bearer 发送
#     REFRESH_SECONDS=60     # 可选，多久拉取一次网络配置（秒）
#     HEARTBEAT_TOKEN=""     # 可选，有 Gists 写权限的令牌；设置后定时把状态汇报到 Gist 评论（心跳）
#     HEARTBEAT_SECONDS=300  # 可选，心跳间隔（秒）；状态变化时会立即汇报
#     HEARTBEAT_URL=""       # 可选，每次心跳额外访问的地址（如 healthchecks.io，用于掉线报警）
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
HEARTBEAT_TOKEN=""
HEARTBEAT_SECONDS=300
HEARTBEAT_URL=""
GG_VERSION="2026.10.28"
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
  tok="${AUTH_TOKEN:-$HEARTBEAT_TOKEN}"     # 有令牌就带上，API 限额从每小时 60 次提高到 5000 次
  [ -n "$tok" ] && hdr=(-H "Authorization: Bearer $tok")
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
ALLOW_UNTIL=""          # 程序和网站一起放行
APP_ALLOW_UNTIL=""      # 只放行程序
SITE_ALLOW_UNTIL=""     # 只放行网站
SITE_SCHEDULE=same      # same = 网站跟程序同一个时间表；separate = 网站用 site_allow
ALLOWED=()
SITE_ALLOWED_WIN=()
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
    app_allow_until)  APP_ALLOW_UNTIL="$val" ;;
    site_allow_until) SITE_ALLOW_UNTIL="$val" ;;
    site_schedule)    [ "$val" = "separate" ] && SITE_SCHEDULE=separate ;;
    allow)       echo "$val" | grep -Eq '^[1-7](,[1-7])* [0-9]{4} [0-9]{4}$' && ALLOWED+=("$val") ;;
    site_allow)  echo "$val" | grep -Eq '^[1-7](,[1-7])* [0-9]{4} [0-9]{4}$' && SITE_ALLOWED_WIN+=("$val") ;;
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
  [ -n "$APP_ALLOW_UNTIL" ] && echo "app_allow_until=$APP_ALLOW_UNTIL"
  [ -n "$SITE_ALLOW_UNTIL" ] && echo "site_allow_until=$SITE_ALLOW_UNTIL"
  for a in "${ALLOWED[@]}"; do echo "allow=$a"; done
  if [ "$SITE_SCHEDULE" = "separate" ]; then
    echo "site_schedule=separate"
    for a in "${SITE_ALLOWED_WIN[@]}"; do echo "site_allow=$a"; done
  fi
  for b in "${BLOCKS[@]}"; do echo "block=$b"; done
  for s in "${SITES[@]}"; do echo "site=$s"; done
  echo "message=$MESSAGE"
fi

# ---------- 3. 判断现在是否允许（程序和网站分别判断） ----------
NOW_TS=$(date +%s); DOW=$(date +%u); NOW_HM=$((10#$(date +%H%M)))
until_active() {   # $1 = "YYYY-MM-DD HH:MM"，还没到这个时间就返回成功
  [ -n "$1" ] || return 1
  local t; t=$(date -j -f "%Y-%m-%d %H:%M" "$1" +%s 2>/dev/null)
  [ -n "$t" ] && [ "$NOW_TS" -lt "$t" ]
}
HIT_WINDOW=""
in_windows() {     # 参数是若干 "星期 开始 结束"，现在在其中任一段内就返回成功
  local w days s e
  for w in "$@"; do
    read -r days s e <<< "$w"
    case ",$days," in *",$DOW,"*)
      if [ "$NOW_HM" -ge $((10#$s)) ] && [ "$NOW_HM" -lt $((10#$e)) ]; then HIT_WINDOW="$w"; return 0; fi ;;
    esac
  done
  return 1
}

APP_ALLOWED=0; APP_TEXT="受限"
SITE_ALLOWED=0; SITE_TEXT="受限"
if [ "$ENABLED" = "false" ]; then
  APP_ALLOWED=1; APP_TEXT="管控已暂停"; SITE_ALLOWED=1; SITE_TEXT="管控已暂停"
else
  if until_active "$ALLOW_UNTIL"; then
    APP_ALLOWED=1; APP_TEXT="临时放行到 $ALLOW_UNTIL"
  elif until_active "$APP_ALLOW_UNTIL"; then
    APP_ALLOWED=1; APP_TEXT="临时放行到 $APP_ALLOW_UNTIL"
  elif in_windows "${ALLOWED[@]}"; then
    APP_ALLOWED=1; APP_TEXT="开放时间（${HIT_WINDOW}）"
  fi
  if until_active "$ALLOW_UNTIL"; then
    SITE_ALLOWED=1; SITE_TEXT="临时放行到 $ALLOW_UNTIL"
  elif until_active "$SITE_ALLOW_UNTIL"; then
    SITE_ALLOWED=1; SITE_TEXT="临时放行到 $SITE_ALLOW_UNTIL"
  elif [ "$SITE_SCHEDULE" = "separate" ]; then
    in_windows "${SITE_ALLOWED_WIN[@]}" && { SITE_ALLOWED=1; SITE_TEXT="开放时间（${HIT_WINDOW}，网站时间表）"; }
  elif in_windows "${ALLOWED[@]}"; then
    SITE_ALLOWED=1; SITE_TEXT="开放时间（${HIT_WINDOW}）"
  fi
fi
NOW_ALLOWED=$SITE_ALLOWED    # 下面的网站屏蔽部分按网站的状态处理

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
  echo "→ 程序：${APP_TEXT}"
  echo "→ 网站：${SITE_TEXT}"
  if [ -n "$HEARTBEAT_TOKEN" ]; then
    hb_last=$(cat "$STATE_DIR/hb.last" 2>/dev/null)
    echo "→ 心跳：已开启（每 $((HEARTBEAT_SECONDS / 60)) 分钟），上次成功：${hb_last:+$(date -r "$hb_last" '+%Y-%m-%d %H:%M:%S')}${hb_last:-还没有}"
  else
    echo "→ 心跳：未开启（没有设置心跳令牌）"
  fi
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

killed=0
if [ $APP_ALLOWED -eq 0 ]; then
  # ---------- 5. 查找并结束进程 ----------
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
        kill -9 "$pid" 2>/dev/null && { log "已结束 PID $pid ($owner)，匹配“${pat}”：$cmd"; killed=1; date +%s > "$STATE_DIR/last_kill"; }
      fi
    done
  done

  # ---------- 5b. 提示当前用户 ----------
  if [ $killed -eq 1 ]; then
    user=$(stat -f%Su /dev/console)
    uid=$(id -u "$user" 2>/dev/null)
    if [ -n "$uid" ] && [ "$user" != "root" ]; then
      safe_msg=$(echo "$MESSAGE" | tr -d '"\\')
      launchctl asuser "$uid" sudo -u "$user" osascript -e \
        "display notification \"$safe_msg\" with title \"GameGuard\"" 2>/dev/null
    fi
  fi

fi

# ---------- 6. 心跳：把当前状态写到 Gist 的一条评论里，家长控制台据此显示是否在线 ----------
# 评论不进 Gist 的版本历史，所以频繁更新也不会让 Gist 变大。每台 Mac 只占一条评论，反复更新它。
heartbeat() {
  [ "$MODE" = "run" ] && [ -n "$HEARTBEAT_TOKEN" ] || return 0
  local gid now state last_ts last_state
  gid=$(echo "$CONFIG_URL" | sed -nE 's#^https://gist\.githubusercontent\.com/[^/]+/([0-9a-fA-F]+)/raw/.*#\1#p')
  [ -n "$gid" ] || return 0
  now=$(date +%s)
  state="${ENABLED}-${APP_ALLOWED}-${SITE_ALLOWED}"
  last_ts=$(cat "$STATE_DIR/hb.last" 2>/dev/null); last_ts=${last_ts:-0}
  last_state=$(cat "$STATE_DIR/hb.state" 2>/dev/null)
  if [ "$state" = "$last_state" ] && [ $((now - last_ts)) -lt "$HEARTBEAT_SECONDS" ]; then return 0; fi

  local iface lip pip host cuser boot cfg_age lastkill body resp code cid
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$iface" ] && lip=$(ipconfig getifaddr "$iface" 2>/dev/null)
  pip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
  echo "$pip" | grep -Eq '^[0-9a-fA-F:.]{3,45}$' || pip=""
  host=$(scutil --get ComputerName 2>/dev/null)
  cuser=$(stat -f%Su /dev/console 2>/dev/null)
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*[{] sec = ([0-9]+).*/\1/p')
  cfg_age=""; [ -f "$CACHE" ] && cfg_age=$(( now - $(stat -f %m "$CACHE") ))
  lastkill=$(cat "$STATE_DIR/last_kill" 2>/dev/null)

  body=$(mktemp "$STATE_DIR/hb.XXXXXX"); resp="$body.resp"
  osascript -l JavaScript -e 'function run(a){var o={};for(var i=0;i+1<a.length;i+=2){var v=a[i+1];o[a[i]]=/^-?[0-9]+$/.test(v)?Number(v):v;}
var t="gameguard-heartbeat "+JSON.stringify(o);
return JSON.stringify({body:t}).replace(/[\u007f-￿]/g,function(c){return "\\u"+("0000"+c.charCodeAt(0).toString(16)).slice(-4);});}' \
    v 1 host "$host" version "$GG_VERSION" time "$now" boot "${boot:-0}" user "$cuser" \
    ip_local "$lip" ip_public "$pip" iface "$iface" enabled "$ENABLED" \
    app_open "$APP_ALLOWED" app_text "$APP_TEXT" site_open "$SITE_ALLOWED" site_text "$SITE_TEXT" \
    sites "${#SITES[@]}" blocks "${#BLOCKS[@]}" config_age "${cfg_age:-0}" last_kill "${lastkill:-0}" > "$body" 2>/dev/null

  if [ -s "$body" ]; then
    local auth=(-H "Authorization: Bearer $HEARTBEAT_TOKEN" -H "Accept: application/vnd.github+json")
    cid=$(cat "$STATE_DIR/hb.comment" 2>/dev/null)
    if [ -n "$cid" ]; then
      code=$(curl -sS --max-time 15 --proto '=https' -o "$resp" -w '%{http_code}' -X PATCH "${auth[@]}" \
             --data-binary @"$body" "https://api.github.com/gists/$gid/comments/$cid" 2>/dev/null)
      [ "$code" = "404" ] && cid=""
    fi
    if [ -z "$cid" ]; then
      code=$(curl -sS --max-time 15 --proto '=https' -o "$resp" -w '%{http_code}' -X POST "${auth[@]}" \
             --data-binary @"$body" "https://api.github.com/gists/$gid/comments" 2>/dev/null)
      if [ "$code" = "201" ]; then
        grep -Eo '"id": *[0-9]+' "$resp" | head -1 | grep -Eo '[0-9]+' > "$STATE_DIR/hb.comment"
      fi
    fi
  fi

  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    echo "$now" > "$STATE_DIR/hb.last"; echo "$state" > "$STATE_DIR/hb.state"
    [ -f "$STATE_DIR/hb.fail" ] && { rm -f "$STATE_DIR/hb.fail"; log "心跳恢复正常"; }
  elif [ ! -f "$STATE_DIR/hb.fail" ]; then
    touch "$STATE_DIR/hb.fail"
    case "$code" in
      401) log "心跳上报失败：令牌无效或已过期" ;;
      403|404) log "心跳上报失败（HTTP $code）：令牌没有这个 Gist 的写权限" ;;
      *) log "心跳上报失败（HTTP ${code:-无响应}），之后恢复会再记录" ;;
    esac
  fi
  rm -f "$body" "$resp"
  [ -n "$HEARTBEAT_URL" ] && curl -fsS --max-time 10 --retry 2 -o /dev/null "$HEARTBEAT_URL" 2>/dev/null
  return 0
}
heartbeat

# 日志超过 1MB 时只保留最后 2000 行
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt 1048576 ]; then
  tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exit 0

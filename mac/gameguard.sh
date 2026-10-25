#!/bin/bash
# gameguard.sh —— 按网络配置检测并结束游戏进程（macOS）
#
# 由 launchd 以 root 身份每分钟运行一次。
# 配置地址写在 /usr/local/etc/gameguard.conf（只有 root 能读写）：
#     CONFIG_URL="https://.../gameguard.txt"
#     AUTH_TOKEN=""          # 可选，作为 Authorization: Bearer 发送
#     REFRESH_SECONDS=300    # 可选，多久拉取一次网络配置
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
REFRESH_SECONDS=300
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
  if curl -fsSL --max-time 15 --proto '=https' "${hdr[@]}" \
          -H "Cache-Control: no-cache" "$CONFIG_URL?t=$(date +%s)" -o "$tmp" \
     && grep -q '^enabled=' "$tmp" && [ "$(wc -c < "$tmp")" -lt 65536 ]; then
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
  esac
done <<< "$CONFIG"
[ ${#BLOCKS[@]} -eq 0 ] && while IFS= read -r l; do case "$l" in block=*) BLOCKS+=("${l#block=}");; esac; done <<< "$DEFAULT_CONFIG"

if [ "$MODE" = "show" ]; then
  echo "配置来源：$SRC   ${CONFIG_URL:+($CONFIG_URL)}"
  echo "enabled=$ENABLED"
  echo "allow_until=${ALLOW_UNTIL:-（无）}"
  for a in "${ALLOWED[@]}"; do echo "allow=$a"; done
  for b in "${BLOCKS[@]}"; do echo "block=$b"; done
  echo "message=$MESSAGE"
fi

# ---------- 3. 判断现在是否允许玩 ----------
[ "$ENABLED" = "false" ] && { [ "$MODE" = "show" ] && echo "→ 管控已暂停"; exit 0; }

if [ -n "$ALLOW_UNTIL" ]; then
  until_ts=$(date -j -f "%Y-%m-%d %H:%M" "$ALLOW_UNTIL" +%s 2>/dev/null)
  if [ -n "$until_ts" ] && [ "$(date +%s)" -lt "$until_ts" ]; then
    [ "$MODE" = "show" ] && echo "→ 临时放行中，直到 $ALLOW_UNTIL"
    exit 0
  fi
fi

dow=$(date +%u); now=$((10#$(date +%H%M)))
for w in "${ALLOWED[@]}"; do
  read -r days s e <<< "$w"
  case ",$days," in *",$dow,"*)
    if [ "$now" -ge $((10#$s)) ] && [ "$now" -lt $((10#$e)) ]; then
      [ "$MODE" = "show" ] && echo "→ 当前在允许时间段内（${w}）"
      exit 0
    fi ;;
  esac
done
[ "$MODE" = "show" ] && echo "→ 当前禁止游戏"
[ "$MODE" = "show" ] && exit 0

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

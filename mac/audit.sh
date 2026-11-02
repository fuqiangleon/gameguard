#!/bin/bash
# GameGuard 安全自检（macOS）
# 用法（用管理员账户）：
#   curl -fsSL https://raw.githubusercontent.com/fuqiangleon/gameguard/main/mac/audit.sh | sudo bash
# 只读检查，不修改任何设置。
# 可选：用环境变量指定应该是管理员的账户（默认 ddg dad）
#   curl -fsSL .../audit.sh | sudo ADMINS="ddg dad" bash

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }

ADMINS="${ADMINS:-ddg dad}"
SYSTEM_ADMINS="root _mbsetupuser"
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✘\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

echo "GameGuard 安全自检 · $(scutil --get ComputerName 2>/dev/null) · $(date '+%Y-%m-%d %H:%M')"
echo "macOS $(sw_vers -productVersion 2>/dev/null)，期望的管理员：$ADMINS"

# ---------------------------------------------------------------- 账户
sec "1. 账户与管理员"
admin_users=$(dscacheutil -q group -a name admin | awk -F': ' '/^users:/{print $2}')
extra=""; for u in $admin_users; do in_list "$u" "$ADMINS $SYSTEM_ADMINS" || extra="$extra $u"; done
if [ -z "$extra" ]; then ok "管理员只有：$admin_users"; else bad "多出的管理员账户：${extra}（应降为普通账户或删除）"; fi
for u in $ADMINS; do
  if ! id "$u" >/dev/null 2>&1; then warn "账户 $u 不存在"; continue; fi
  dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1 && ok "$u 是管理员" || bad "$u 不是管理员"
  dscl . -read "/Users/$u" IsHidden 2>&1 | grep -Eq 'IsHidden:[[:space:]]*1' && ok "$u 已在登录界面隐藏" || warn "$u 没有隐藏（登录界面可见）"
  dscl . -read "/Users/$u" LinkedIdentity 2>&1 | grep -q 'LinkedIdentity:' && bad "$u 绑定了 Apple ID，可被用来重置密码" || ok "$u 没有绑定 Apple ID"
done

users=$(dscl . list /Users UniqueID | awk '$2>=500 && $1 !~ /^_/ {print $1":"$2}')
info "所有普通账户（名字:编号，编号越大越新）：$(echo $users)"
max_admin_uid=0
for u in $ADMINS; do uid=$(id -u "$u" 2>/dev/null); [ -n "$uid" ] && [ "$uid" -gt "$max_admin_uid" ] && max_admin_uid=$uid; done
for pair in $users; do
  name=${pair%%:*}; uid=${pair##*:}
  in_list "$name" "$ADMINS" && continue
  [ "$uid" -gt "$max_admin_uid" ] && warn "账户 ${name}（编号 ${uid}）比管理员账户建得更晚，确认是不是你建的"
done
if [ "$(defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled 2>/dev/null)" != "1" ]; then
  ok "客人账户已关闭"
else
  bad "客人账户是打开的"
fi
autologin=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)
[ -z "$autologin" ] && ok "没有设置自动登录" || warn "设置了自动登录：$autologin"

# ---------------------------------------------------------------- 磁盘与恢复
sec "2. FileVault、查找、恢复模式"
fv=$(fdesetup status 2>/dev/null)
case "$fv" in *"is On"*) ok "FileVault 已打开" ;; *progress*) ok "FileVault 正在加密：$fv" ;; *) bad "FileVault 未打开（可在恢复模式重置密码）" ;; esac
fv_users=$(fdesetup list 2>/dev/null | cut -d, -f1 | tr '\n' ' ')
fv_extra=""; for u in $fv_users; do in_list "$u" "$ADMINS" || fv_extra="$fv_extra $u"; done
if [ -z "$fv_extra" ]; then ok "能解锁磁盘的账户：$fv_users"; else warn "以下账户也能解锁磁盘：$fv_extra"; fi
[ "$(fdesetup haspersonalrecoverykey 2>/dev/null)" = "true" ] && ok "有个人恢复密钥" || warn "没有个人恢复密钥（运行 sudo fdesetup changerecovery -personal）"
if nvram fmm-mobileme-token-FMM >/dev/null 2>&1; then ok "「查找我的 Mac」已开启（激活锁）"; else bad "「查找我的 Mac」未开启：Mac 可被抹掉重装"; fi
for d in /Users/*; do
  f="$d/Library/Preferences/MobileMeAccounts.plist"
  [ -f "$f" ] || continue
  ids=$(defaults read "$f" Accounts 2>/dev/null | awk -F'"' '/AccountID/{print $2}' | tr '\n' ' ')
  [ -n "$ids" ] && info "$(basename "$d") 登录的 Apple ID：$ids"
done
sip=$(csrutil status 2>/dev/null)
case "$sip" in *enabled*) ok "系统完整性保护（SIP）已开启" ;; *) bad "SIP 未开启：$sip" ;; esac

# ---------------------------------------------------------------- GameGuard
sec "3. GameGuard 管控程序"
PLIST=/Library/LaunchDaemons/com.gameguard.plist
for f in "$PLIST" /usr/local/bin/gameguard.sh /usr/local/etc/gameguard.conf; do
  if [ -f "$f" ]; then
    own=$(stat -f '%Su' "$f"); mode=$(stat -f '%Lp' "$f")
    if [ "$own" = "root" ]; then ok "${f}（属主 root，权限 ${mode}）"; else bad "$f 属主是 ${own}，应为 root"; fi
  else
    bad "缺少 ${f}（可能被卸载）"
  fi
done
if launchctl print system/com.gameguard >/dev/null 2>&1; then
  iv=$(launchctl print system/com.gameguard | awk -F'= ' '/run interval/{print $2; exit}')
  ok "定时任务已加载（间隔 ${iv:-未知}）"
  case "$iv" in 20*) ;; *) warn "不是最新版（最新版每 20 秒检查一次），运行 update.sh 升级" ;; esac
else
  bad "定时任务没有加载"
fi
if [ -f /usr/local/etc/gameguard.conf ]; then
  url=$(. /usr/local/etc/gameguard.conf; echo "$CONFIG_URL")
  [ -n "$url" ] && ok "配置地址已设置" || bad "没有配置地址（只会用内置默认规则）"
fi
cache=/var/db/gameguard/config.cache
if [ -f "$cache" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$cache") ))
  [ "$age" -lt 300 ] && ok "最近 $((age/60)) 分钟内读取过网络配置" || warn "已经 $((age/60)) 分钟没有成功读取网络配置"
  grep -q '^heartbeat_topic=' "$cache" && ok "心跳频道已配置" || warn "没有开启心跳（在控制台首页点「开启心跳」）"
  grep -qE '^block=com\.roblox\.' "$cache" && ok "已按应用 ID 识别 Roblox" || warn "规则里没有 com.roblox.（在控制台「管控」页点 + Roblox 并保存）"
  grep -q '^site=now.gg' "$cache" && ok "已屏蔽云游戏网站 now.gg" || warn "没有屏蔽 now.gg（在「屏蔽网站」点 + Roblox 并保存）"
else
  bad "没有配置缓存，GameGuard 从未成功读取网络配置"
fi
hb=/var/db/gameguard/hb.last
if [ -f "$hb" ]; then
  hb_age=$(( $(date +%s) - $(cat "$hb") ))
  [ "$hb_age" -lt 1500 ] && ok "最近一次心跳：$((hb_age/60)) 分钟前" || warn "最近一次心跳在 $((hb_age/60)) 分钟前"
fi
if [ -x /usr/local/bin/gameguard.sh ]; then
  /usr/local/bin/gameguard.sh --show 2>/dev/null | grep '^→' | sed 's/^/    /'
fi
if [ -f /var/log/gameguard.log ]; then
  info "最近日志："; tail -3 /var/log/gameguard.log | sed 's/^/      /'
fi

# ---------------------------------------------------------------- 绕过与后门
sec "4. 可能的绕过方式与后门"
if [ -z "$(ls -A /etc/sudoers.d 2>/dev/null)" ]; then ok "/etc/sudoers.d 是空的"; else bad "/etc/sudoers.d 里有文件：$(ls /etc/sudoers.d | tr '\n' ' ')"; fi
extra_sudo=$(grep -vE '^\s*(#|$|Defaults|root\s|%admin\s|@includedir|#includedir)' /etc/sudoers 2>/dev/null)
[ -z "$extra_sudo" ] && ok "/etc/sudoers 没有额外授权" || bad "/etc/sudoers 有额外授权：$extra_sudo"
prof=$(profiles list 2>/dev/null)
case "$prof" in *"no configuration profiles"*|"") ok "没有安装配置描述文件" ;; *) warn "安装了配置描述文件，确认是否认识："; echo "$prof" | sed 's/^/      /' ;; esac
vpn=$(scutil --nc list 2>/dev/null | grep -v '^Available' )
[ -z "$vpn" ] && ok "没有系统 VPN 配置" || { warn "有 VPN 配置："; echo "$vpn" | sed 's/^/      /'; }
for app in /Applications/ZeroTier* /Applications/Tailscale* /Applications/*VPN* /Applications/*Proxy* /Applications/Clash* /Applications/ClashX* /Applications/V2rayU* /Applications/Shadowrocket*; do
  [ -e "$app" ] && warn "发现网络代理类软件：$app"
done
recent=$(find /Library/LaunchDaemons /Library/LaunchAgents /Users/*/Library/LaunchAgents -name '*.plist' -mtime -14 2>/dev/null | grep -v com.gameguard)
[ -z "$recent" ] && ok "最近 14 天没有新增开机启动项" || { warn "最近 14 天新增或修改的启动项（确认是否认识）："; echo "$recent" | sed 's/^/      /'; }
if grep -q '0.0.0.0' /etc/hosts && grep -q 'GameGuard' /etc/hosts; then info "hosts 里有 GameGuard 屏蔽段（受限时段才有）"; fi
odd_hosts=$(awk '/>>> GameGuard/{f=1} /<<< GameGuard/{f=0;next} !f' /etc/hosts | grep -vE '^\s*(#|$)' | grep -vE '^(127\.0\.0\.1|255\.255\.255\.255|::1)\s+(localhost|broadcasthost)')
[ -z "$odd_hosts" ] && ok "/etc/hosts 没有其他修改" || warn "/etc/hosts 有其他条目：$odd_hosts"
rl=$(systemsetup -getremotelogin 2>/dev/null)
case "$rl" in *On*) info "远程登录（SSH）：开启" ;; *Off*) info "远程登录（SSH）：关闭" ;; esac
nt=$(systemsetup -getusingnetworktime 2>/dev/null)
case "$nt" in *On*) ok "自动设置时间：开启" ;; *Off*) bad "没有自动设置时间（可能被改时间绕过）" ;; esac

# ---------------------------------------------------------------- 登录记录
sec "5. 最近登录"
last -10 2>/dev/null | grep -vE '^$|^wtmp' | sed 's/^/    /'

echo
printf '结果：\033[32m通过 %d\033[0m · \033[33m注意 %d\033[0m · \033[31m问题 %d\033[0m\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "没有发现严重问题。" || echo "请先处理标 ✘ 的问题。"

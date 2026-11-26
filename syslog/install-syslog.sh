#!/usr/bin/env bash
# 讓目標機器把重要的系統紀錄即時送到 NAS 的 Syslog 伺服器,集中保存。
#
# 送出的紀錄(只送重要的):
#   - 登入與權限:auth、authpriv(SSH 登入、sudo、su 等),全部等級
#   - 系統核心:kern,全部等級
#   - 其他所有程式:警告(warning)以上
# 用 TCP 傳送;NAS 連不上時先暫存在機器上(最多 200 MB),連回來後自動補送。
# 同時把機器時區設成 --timezone(預設 Asia/Taipei),紀錄時間才會和 NAS 一致。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash install-syslog.sh
#
#   1. NAS IP(也可以寫 ~/.ssh/config 的名稱)
#   2. 目標機器 [SSH_USER@]IP,再輸入密碼,可以連續加多台
#   3. 逐台檢查(SSH、sudo、該機連得到 NAS 的 Syslog 埠),顯示摘要,
#      輸入 y 後全部自動完成
# 第 3 步確認之前,任何機器都不會被修改。
#
# 在目標機器上直接執行:
#   sudo bash install-syslog.sh here --nas <NAS_IP>   # 設定這一台
#   bash install-syslog.sh check                      # 唯讀檢查狀態
# 移除請用同目錄的 remove-syslog.sh。
#
# NAS 端要先做(網頁設定):控制台 → 應用服務 → Syslog 伺服器 → 啟用,開 TCP。
#
# 參數(沒給的先用腳本最上面「預設值」區塊的值,那裡也空白才會問)
#   --nas IP               NAS 位址,可用 ssh 設定名稱(只取 HostName)
#   --port N               NAS 的 Syslog TCP 埠,預設 514
#   --timezone ZONE        機器時區,預設 Asia/Taipei;none = 不改
#   --host [SSH_USER@]IP   目標機器,可重複或用逗號 a,b,c
#   --yes                  跳過最後的確認
#   -h, --help             顯示這份說明
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_NAS=""            # --nas,例如 192.168.1.10
CFG_PORT=514          # --port
CFG_TIMEZONE="Asia/Taipei"  # --timezone;none = 不改時區
CFG_HOSTS=""          # --host,例如 admin@192.168.1.21,admin@192.168.1.22
CFG_YES=0             # 1 = 所有確認自動回答 y
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

CONF="/etc/rsyslog.d/90-nas-syslog.conf"
SPOOL="/var/spool/rsyslog"
QUEUE_NAME="nas_fwd"
QUEUE_MAX="200m"
MARK="# managed by install-syslog.sh (nas_setup); remove with remove-syslog.sh"

NAS_ARG=""; NAS_HOST=""; PORT=""; TZONE=""
ASSUME_YES=0
ARG_HOSTS=()
WORK=""
T_HOST=(); T_USER=(); T_SHOW=(); T_ROOT=()
SO=()
REASON=""

die()  { echo "錯誤:$*" >&2; exit 1; }
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

APT_LOG="/var/log/install-syslog-apt.log"
apt_q() {
    if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
         apt-get -y -q "$@" </dev/null >>"$APT_LOG" 2>&1; then
        tail -n 20 "$APT_LOG" >&2
        die "apt-get $* 失敗,完整記錄在 $APT_LOG"
    fi
}

[ -t 1 ] && printf '\e[?1004l'
flush_stdin() {
    [ -t 0 ] || return 0
    local _t; while read -r -t 0.05 -n 4096 _t 2>/dev/null; do :; done; return 0
}
read_secret() {
    local _v
    flush_stdin
    read -rsp "$2" _v; echo
    _v="${_v//$'\e[I'/}"; _v="${_v//$'\e[O'/}"
    printf -v "$1" '%s' "$_v"
}
# preset_secret NAME VAR: password prepared by install-all.sh; 1 = none
preset_secret() {
    local f="${INSTALL_ALL_SECRETS:-}/$1"
    [ -n "${INSTALL_ALL_SECRETS:-}" ] && [ -r "$f" ] || return 1
    printf -v "$2" '%s' "$(head -n1 "$f")"
}

ssh_resolve() { command -v ssh >/dev/null || return 1; ssh -G "$1" 2>/dev/null | awk -v f="$2" '$1==f {print $2; exit}'; }

set_nas() {
    local addr r
    addr="$(echo "$1" | xargs)"
    [[ "$addr" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "NAS 位址不正確:$addr"; return 1; }
    r="$(ssh_resolve "$addr" hostname || true)"
    NAS_HOST="${r:-$addr}"
    [ "$NAS_HOST" = "$addr" ] || log "NAS ${addr} -> ${NAS_HOST}(來自 ssh 設定)"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# render_conf NAS PORT: the managed rsyslog snippet
render_conf() {
    cat <<EOF
$MARK
# 送到 NAS:auth/authpriv/kern 全部,其他 warning 以上。NAS 連不上時暫存在 $SPOOL。
if (\$syslogfacility-text == "auth" or \$syslogfacility-text == "authpriv" or \$syslogfacility-text == "kern" or \$syslogseverity <= 4) then {
    action(type="omfwd" target="$1" port="$2" protocol="tcp"
           template="RSYSLOG_ForwardFormat"
           queue.type="LinkedList" queue.filename="$QUEUE_NAME"
           queue.spoolDirectory="$SPOOL" queue.maxDiskSpace="$QUEUE_MAX"
           queue.saveOnShutdown="on"
           action.resumeRetryCount="-1" action.resumeInterval="30")
}
EOF
}

# set_timezone ZONE: 0 = changed, 1 = already set / skipped
set_timezone() {
    local z="$1" cur
    [ -n "$z" ] && [ "$z" != "none" ] || return 1
    [ -f "/usr/share/zoneinfo/$z" ] || die "沒有這個時區:$z(例如 Asia/Taipei)"
    cur="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
    [ "$cur" != "$z" ] || return 1
    if command -v timedatectl >/dev/null && [ -d /run/systemd/system ]; then
        timedatectl set-timezone "$z"
    else
        ln -sf "/usr/share/zoneinfo/$z" /etc/localtime
        echo "$z" > /etc/timezone
    fi
    log "時區 ${cur:-未知} -> $z"
    return 0
}

restart_rsyslog() {
    if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then
        systemctl enable rsyslog >/dev/null 2>&1 || true
        systemctl restart rsyslog
    else
        warn "沒有 systemd,請自行重新啟動 rsyslog"
    fi
}

# --- install on THIS machine (root) -----------------------------------------
install_here() {
    [ "$(id -u)" -eq 0 ] || die "需要 root:sudo bash $SELF here --nas <NAS_IP>"
    [ -n "$NAS_HOST" ] || die "需要 --nas"
    valid_port "$PORT" || die "--port 不正確:$PORT"

    if ! command -v rsyslogd >/dev/null; then
        log "安裝 rsyslog"
        apt_q update
        apt_q install rsyslog
    fi
    install -d -m 700 "$SPOOL"

    local tz_changed=0
    if set_timezone "$TZONE"; then tz_changed=1; fi

    local tmp old=""
    tmp="$(mktemp)"
    render_conf "$NAS_HOST" "$PORT" > "$tmp"
    if [ -f "$CONF" ] && cmp -s "$tmp" "$CONF"; then
        rm -f "$tmp"
        log "$(hostname):設定已是最新,不需要修改"
        # rsyslog keeps the old timezone until restarted
        [ "$tz_changed" -eq 0 ] || restart_rsyslog
    else
        if [ -f "$CONF" ]; then old="$(mktemp)"; cp -a "$CONF" "$old"; fi
        install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
        if ! rsyslogd -N1 >/dev/null 2>&1; then
            rsyslogd -N1 >&2 || true
            if [ -n "$old" ]; then cp -a "$old" "$CONF"; rm -f "$old"; else rm -f "$CONF"; fi
            die "rsyslog 設定檢查失敗,已還原,沒有修改"
        fi
        [ -z "$old" ] || rm -f "$old"
        log "寫入 $CONF"
        restart_rsyslog
    fi
    logger -p auth.notice -t nas-syslog "install-syslog: $(hostname) 開始送紀錄到 ${NAS_HOST}:${PORT}"
    log "$(hostname) 完成,已送出一則測試紀錄(auth.notice)"
}

check_tool() {
    echo "--- 設定檔";  if [ -f "$CONF" ]; then cat "$CONF"; else echo "(沒有 $CONF)"; fi
    echo "--- rsyslog"; systemctl is-active rsyslog 2>/dev/null || echo "(無法查詢)"
    echo "--- 時區"; timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "(無法查詢)"
    echo "--- 暫存佇列(NAS 連不上時才會有檔案)"
    local q found=0
    for q in "$SPOOL/$QUEUE_NAME".*; do [ -e "$q" ] && { ls -la "$q"; found=1; }; done
    [ "$found" -eq 1 ] || echo "(沒有)"
    local t p
    t="$(awk -F'"' '/target=/{for(i=1;i<NF;i++) if($i ~ /target=$/) print $(i+1)}' "$CONF" 2>/dev/null | head -n1)"
    p="$(awk -F'"' '/port=/{for(i=1;i<NF;i++) if($i ~ /port=$/) print $(i+1)}' "$CONF" 2>/dev/null | head -n1)"
    if [ -n "$t" ]; then
        echo "--- 連線 ${t}:${p}"
        if timeout 5 bash -c "</dev/tcp/${t}/${p}" 2>/dev/null; then echo "連得到"; else echo "連不到"; fi
    fi
}

# --- remote (from YOUR PC, password SSH) -------------------------------------
cleanup() {
    local s
    [ -n "$WORK" ] && [ -d "$WORK" ] || return 0
    for s in "$WORK"/cm-*; do
        [ -S "$s" ] && ssh -o ControlPath="$s" -O exit _ >/dev/null 2>&1
    done
    rm -rf "$WORK"
}

check_ssh_version() {
    local v
    v="$(ssh -V 2>&1)"
    [[ "$v" =~ OpenSSH_([0-9]+)\.([0-9]+) ]] || die "看不懂 ssh 版本:$v"
    { [ "${BASH_REMATCH[1]}" -gt 8 ] || { [ "${BASH_REMATCH[1]}" -eq 8 ] && [ "${BASH_REMATCH[2]}" -ge 4 ]; }; } \
        || die "這台電腦需要 OpenSSH 8.4 以上(SSH_ASKPASS_REQUIRE),目前是 $v"
}

set_so() {
    SO=(-o "ControlPath=${WORK}/cm-$1")
    [ -z "${T_USER[$1]}" ] || SO+=(-o "User=${T_USER[$1]}")
    SO+=(-o ConnectTimeout=8
        -o StrictHostKeyChecking=accept-new
        -o "PreferredAuthentications=password,keyboard-interactive"
        -o NumberOfPasswordPrompts=1)
}
r_open() {
    set_so "$1"
    SSH_ASKPASS="${WORK}/askpass" SSH_ASKPASS_REQUIRE=force PW_FILE="${WORK}/pw.$1" \
        ssh "${SO[@]}" -o ControlMaster=yes -o ControlPersist=30m -fN "${T_HOST[$1]}" </dev/null
}
r_ssh()    { local i="$1"; shift; set_so "$i"; ssh -n "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"; }
r_ssh_in() { local i="$1"; shift; set_so "$i"; ssh    "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"; }
r_scp()    { local i="$1" dest="$2"; shift 2; set_so "$i"; scp -q "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "$@" "${T_HOST[$i]}:${dest}/"; }

# add_host "[USER@]ADDR": 1 = bad password input, 2 = bad address
add_host() {
    local arg h u="" pw i rh ru
    arg="$(echo "$1" | xargs)"
    if [[ "$arg" == *@* ]]; then u="${arg%@*}"; h="${arg##*@}"; else h="$arg"; fi
    [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "位址不正確:$h"; return 2; }
    [ -z "$u" ] || valid_name "$u" || { warn "使用者名稱不正確:$u"; return 2; }
    rh="$(ssh_resolve "$h" hostname || true)"; rh="${rh:-$h}"
    ru="${u:-$(ssh_resolve "$h" user || true)}"; ru="${ru:-$(id -un)}"
    [ "$rh" = "$h" ] || log "${h} -> ${ru}@${rh}(來自 ssh 設定)"
    preset_secret "host-$h" pw || read_secret pw "${ru}@${rh} 的密碼:"
    [ -n "$pw" ] || { warn "密碼是空的"; return 1; }
    i=${#T_HOST[@]}
    T_HOST+=("$h"); T_USER+=("$u"); T_SHOW+=("${ru}@${rh}"); T_ROOT+=(0)
    ( umask 077; printf '%s\n' "$pw" > "${WORK}/pw.$i" )
}

ask_hosts() {
    local h more rc
    printf '\n%s\n' "【目標機器】登入用的帳號要有 sudo(本機管理員或有 sudo 的 LDAP 帳號都可以)"
    if [ ${#ARG_HOSTS[@]} -gt 0 ]; then
        for h in "${ARG_HOSTS[@]}"; do
            while :; do
                rc=0; add_host "$h" || rc=$?
                [ "$rc" -eq 0 ] && break
                [ "$rc" -eq 2 ] && die "--host 不正確:$h"
            done
        done
        return
    fi
    while :; do
        read -rp "目標機器 [SSH_USER@]IP:" h
        add_host "$h" || continue
        read -rp "還要加其他機器嗎?[y/N] " more
        [[ "$more" =~ ^[Yy]$ ]] || break
    done
}

precheck() {
    local i="$1"
    REASON=""
    r_open "$i" || { REASON="SSH 密碼登入失敗"; return 1; }
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${T_SHOW[$i]%@*} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    r_ssh "$i" 'command -v apt-get' >/dev/null 2>&1 || { REASON="不是 Debian/Ubuntu(沒有 apt-get)"; return 1; }
    r_ssh "$i" "timeout 5 bash -c '</dev/tcp/${NAS_HOST}/${PORT}'" >/dev/null 2>&1 \
        || { REASON="這台連不到 ${NAS_HOST}:${PORT}(NAS 的 Syslog 伺服器有沒有開 TCP?)"; return 1; }
}

run_on() {
    local i="$1" rdir rc=0 cmd
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/nas-syslog.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }
    cmd="bash $(printf '%q' "$rdir/$(basename "$SELF")") here --nas $(printf '%q' "$NAS_HOST") --port $(printf '%q' "$PORT") --timezone $(printf '%q' "$TZONE")"
    if [ "${T_ROOT[$i]}" -eq 1 ]; then
        r_ssh "$i" "$cmd" || rc=$?
    else
        r_ssh_in "$i" "sudo -S -p '' $cmd" < "${WORK}/pw.$i" || rc=$?
    fi
    r_ssh "$i" "rm -rf '$rdir'" || warn "${T_SHOW[$i]}:無法刪除 $rdir"
    return "$rc"
}

ask_nas() {
    local a
    if [ -n "$NAS_ARG" ]; then
        set_nas "$NAS_ARG" || die "--nas 不正確:$NAS_ARG"
    else
        [ -t 0 ] || die "需要 --nas"
        printf '\n%s\n' "【NAS】NAS 的 IP,也可以寫 ~/.ssh/config 的名稱"
        until read -rp "NAS IP:" a && [ -n "$a" ] && set_nas "$a"; do :; done
    fi
    valid_port "$PORT" || die "--port 不正確:$PORT"
}

remote_main() {
    [ -t 0 ] || die "需要互動式終端機"
    command -v ssh >/dev/null && command -v scp >/dev/null || die "找不到 ssh 或 scp"
    check_ssh_version
    WORK="$(mktemp -d /tmp/nas-syslog-deploy.XXXXXX)"; chmod 700 "$WORK"
    trap cleanup EXIT
    printf '#!/bin/sh\nexec cat "$PW_FILE"\n' > "${WORK}/askpass"
    chmod 700 "${WORK}/askpass"

    ask_nas
    ask_hosts

    local i ok=() bad=() results=() names=()
    echo
    for i in "${!T_HOST[@]}"; do
        log "檢查 ${T_SHOW[$i]}"
        if precheck "$i"; then ok+=("$i"); else bad+=("${T_SHOW[$i]}:$REASON"); fi
    done
    echo
    for i in "${ok[@]}";  do echo "  通過    ${T_SHOW[$i]}"; done
    for i in "${bad[@]}"; do echo "  跳過    $i"; done
    [ ${#ok[@]} -gt 0 ] || die "沒有可以設定的機器,沒有修改任何東西"

    for i in "${ok[@]}"; do names+=("${T_SHOW[$i]}"); done
    cat <<EOF

================ 摘要 ================
 目標機器 :${names[*]}
 送到     :${NAS_HOST}:${PORT}(TCP)
 送出內容 :auth、authpriv、kern 全部;其他程式 warning 以上
 斷線時   :暫存在 ${SPOOL}(最多 ${QUEUE_MAX}),連回來後補送
 時區     :${TZONE}
 會修改   :${CONF}(沒有 rsyslog 會先安裝)、時區
======================================
EOF
    if [ "$ASSUME_YES" -eq 0 ]; then
        local a; read -rp "確定套用?[y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
    fi

    for i in "${ok[@]}"; do
        echo; log "========== ${T_SHOW[$i]} =========="
        if run_on "$i"; then results+=("完成    ${T_SHOW[$i]}"); else results+=("失敗    ${T_SHOW[$i]}"); fi
    done
    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
    echo "NAS 上的紀錄:Syslog 伺服器 → Syslog 檢視器,或共用資料夾裡的 messages 檔"
}

parse_opts() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --nas)    NAS_ARG="${2:?}"; shift 2 ;;
            --port)   PORT="${2:?}"; shift 2 ;;
            --timezone) TZONE="${2:?}"; shift 2 ;;
            --host)   IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    [ -n "$NAS_ARG" ] || NAS_ARG="$CFG_NAS"
    [ -n "$PORT" ]    || PORT="$CFG_PORT"
    [ -n "$TZONE" ]   || TZONE="${CFG_TIMEZONE:-none}"
    if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
    [ "$CFG_YES" != "1" ] || ASSUME_YES=1
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        -h|--help|help) usage 0 ;;
        check)          check_tool; return ;;
        here)           shift; parse_opts "$@"
                        [ -n "$NAS_ARG" ] || die "需要 --nas"
                        set_nas "$NAS_ARG" || die "--nas 不正確:$NAS_ARG"
                        install_here; return ;;
    esac
    parse_opts "$@"
    remote_main
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

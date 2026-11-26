#!/usr/bin/env bash
# NAS 上刪除某個 LDAP 使用者之後,清掉他在目標機器上留下的東西。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash cleanup-ldap-user.sh
#
#   1. 要清除的 LDAP 使用者名稱
#   2. NAS [SCAN_USER@]IP、LDAP 網域、查詢帳號密碼
#      用來確認這個使用者在 NAS 上「真的已經刪除」;還在就停止,不會動任何機器
#   3. 目標機器 [SSH_USER@]IP 與密碼,可以連續加多台
#   4. 逐台列出要清除的內容,輸入 y 後全部自動完成
# 第 4 步確認之前,任何機器都不會被修改。
#
# 每台機器會清除(範圍同 userdel -r):
#   - 這個使用者還在執行的程式(先 TERM,再 KILL)
#   - 家目錄 /home/<使用者>
#   - mail spool /var/mail/<使用者>
#   - cron 排程 /var/spool/cron/crontabs/<使用者>、at 排程
#   - systemd linger 設定
#   - sssd 快取中這個使用者的資料
# 其他地方屬於他的檔案不會動。
#
# 參數(每個參數會跳過對應的問題;密碼一律執行時輸入)
#   --user NAME            要清除的 LDAP 使用者
#   --nas [SCAN_USER@]IP   NAS 與查詢用的 LDAP 帳號。IP 可用 ssh 設定名稱
#   --domain DOMAIN        LDAP 網域,例如 example.com(沒有 .xxx 結尾會自動補 .com)
#   --host [SSH_USER@]IP   目標機器,可重複或用逗號 a,b,c
#   --tls-reqcert MODE     never|allow|try|demand。預設 allow
#   --yes                  跳過最後的確認
#   -h, --help             顯示這份說明
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
# 要刪的帳號(--user)沒有預設值,每次都要指定。
CFG_NAS=""            # --nas,NAS 位址,例如 192.168.1.10(可寫成 帳號@IP)
CFG_SCAN_USER="scan_group"  # 查詢帳號;空白 = 每次問
CFG_DOMAIN=""         # --domain,例如 example.com
CFG_HOSTS=""          # --host,例如 admin@192.168.1.21,admin@192.168.1.22
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

MIN_ID="1000000"          # LDAP ids start here; never touch anything below
DEFAULT_SCAN_USER="scan_group"
LDAP_PORT="636"
TLS_REQCERT="allow"
TARGET_USER=""
NAS_ARG=""; NAS_USER=""; LDAP_HOST=""; LDAP_DOMAIN=""
BASE_DN=""; USER_BASE=""
ASSUME_YES=0
ARG_HOSTS=()
WORK=""
T_HOST=(); T_USER=(); T_SHOW=(); T_ROOT=(); T_INFO=()
SO=()
REASON=""

die()  { echo "錯誤:$*" >&2; exit 1; }
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }

# tmux (focus-events on) + fish: focus-in/out sequences (ESC[I / ESC[O) can
# leak into reads. Turn focus reporting off, drain pending input before a
# read and strip those sequences from secrets.
[ -t 1 ] && printf '\e[?1004l'
flush_stdin() {
    [ -t 0 ] || return 0
    local _t; while read -r -t 0.05 -n 4096 _t 2>/dev/null; do :; done; return 0
}
# read_secret VAR PROMPT
read_secret() {
    local _v
    flush_stdin
    read -rsp "$2" _v; echo
    _v="${_v//$'\e[I'/}"; _v="${_v//$'\e[O'/}"
    printf -v "$1" '%s' "$_v"
}
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# --- on the target (root): survey / clean ------------------------------------
# survey USER: prints "uid=N" plus what would be removed; exit 1 = refuse
survey_here() {
    local u="$1" home uid
    valid_name "$u" || { echo "使用者名稱不正確"; return 1; }
    if grep -q "^${u}:" /etc/passwd; then
        echo "這台有同名「本機帳號」${u},不是 LDAP 使用者,不處理"; return 1
    fi
    home="/home/${u}"
    uid=""
    if [ -d "$home" ] && [ ! -L "$home" ]; then
        uid="$(stat -c %u "$home")"
    elif [ -e "$home" ]; then
        echo "${home} 不是一般目錄(可能是連結),不處理"; return 1
    fi
    if [ -z "$uid" ]; then
        # no home: fall back to the sssd cache (may still know the uid)
        uid="$(getent passwd "$u" | cut -d: -f3 || true)"
    fi
    [ -n "$uid" ] || { echo "沒有找到 ${u} 留下的東西"; return 1; }
    [ "$uid" -ge "$MIN_ID" ] || { echo "${home} 的擁有者 uid ${uid} 小於 ${MIN_ID},不是 LDAP 使用者,不處理"; return 1; }
    if getent passwd "$uid" | grep -qv "^${u}:"; then
        echo "uid ${uid} 目前屬於其他使用者 $(getent passwd "$uid" | cut -d: -f1),不處理"; return 1
    fi
    echo "uid=${uid}"
    [ -d "$home" ] && echo "  家目錄   ${home}($(du -sh "$home" 2>/dev/null | cut -f1))"
    local n; n="$(pgrep -u "$uid" 2>/dev/null | wc -l || true)"
    [ "$n" -gt 0 ] && echo "  程式     ${n} 個執行中(會被結束)"
    [ -f "/var/mail/${u}" ] && echo "  mail     /var/mail/${u}"
    [ -f "/var/spool/cron/crontabs/${u}" ] && echo "  cron     /var/spool/cron/crontabs/${u}"
    n="$(find /var/spool/cron/atjobs -maxdepth 1 -type f -uid "$uid" 2>/dev/null | wc -l || true)"
    [ "$n" -gt 0 ] && echo "  at       ${n} 個排程"
    [ -e "/var/lib/systemd/linger/${u}" ] && echo "  linger   /var/lib/systemd/linger/${u}"
    echo "  sssd     快取中的 ${u}"
    return 0
}

clean_here() {
    local u="$1" uid="$2" home="/home/$1"
    [ "$(id -u)" -eq 0 ] || die "需要 root"
    valid_name "$u" && [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge "$MIN_ID" ] || die "參數不正確:$u $uid"
    grep -q "^${u}:" /etc/passwd && die "${u} 是本機帳號,不處理"

    if pgrep -u "$uid" >/dev/null 2>&1; then
        log "結束 ${u}(uid ${uid})的程式"
        pkill -TERM -u "$uid" || true
        sleep 3
        pkill -KILL -u "$uid" || true
    fi
    if [ -d "$home" ] && [ ! -L "$home" ]; then
        [ "$(stat -c %u "$home")" = "$uid" ] || die "${home} 的擁有者不是 uid ${uid},停止"
        log "刪除 ${home}"
        rm -rf --one-file-system -- "$home"
    fi
    if [ -f "/var/mail/${u}" ] && [ "$(stat -c %u "/var/mail/${u}")" = "$uid" ]; then
        log "刪除 /var/mail/${u}"; rm -f -- "/var/mail/${u}"
    fi
    if [ -f "/var/spool/cron/crontabs/${u}" ]; then
        log "刪除 cron 排程"; rm -f -- "/var/spool/cron/crontabs/${u}"
    fi
    if [ -d /var/spool/cron/atjobs ]; then
        find /var/spool/cron/atjobs -maxdepth 1 -type f -uid "$uid" -print -delete 2>/dev/null \
            | sed 's/^/==> 刪除 at 排程 /' || true
    fi
    if [ -e "/var/lib/systemd/linger/${u}" ]; then
        log "刪除 systemd linger"; rm -f -- "/var/lib/systemd/linger/${u}"
    fi
    if command -v sss_cache >/dev/null; then
        log "清除 sssd 快取中的 ${u}"
        sss_cache -u "$u" 2>/dev/null || true
        # an online lookup lets sssd see the user is gone and drop the entry
        getent passwd "$u" >/dev/null 2>&1 || true
    fi
    log "$(hostname) 清除完成"
}

# --- LDAP (PC side) ----------------------------------------------------------
nas_reachable() { timeout 5 bash -c "</dev/tcp/${LDAP_HOST}/${LDAP_PORT}" 2>/dev/null; }

ldap_query_as() {
    local dn="$1" pw="$2"; shift 2
    local pwf rc=0; pwf="$(mktemp)"; chmod 600 "$pwf"
    printf '%s' "$pw" > "$pwf"
    LDAPTLS_REQCERT="$TLS_REQCERT" ldapsearch -x -LLL -o ldif-wrap=no \
        -H "ldaps://${LDAP_HOST}:${LDAP_PORT}" -D "$dn" -y "$pwf" "$@" || rc=$?
    rm -f "$pwf"
    return "$rc"
}

ssh_resolve() { ssh -G "$1" 2>/dev/null | awk -v f="$2" '$1==f {print $2; exit}'; }

set_nas() {
    local arg addr r
    arg="$(echo "$1" | xargs)"
    if [[ "$arg" == *@* ]]; then NAS_USER="${arg%@*}"; addr="${arg##*@}"; else addr="$arg"; fi
    [ -z "$NAS_USER" ] || valid_name "$NAS_USER" || { warn "LDAP 帳號不正確:$NAS_USER"; NAS_USER=""; return 1; }
    [[ "$addr" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "NAS 位址不正確:$addr"; return 1; }
    r="$(ssh_resolve "$addr" hostname || true)"
    LDAP_HOST="${r:-$addr}"
    [ "$LDAP_HOST" = "$addr" ] || log "NAS ${addr} -> ${LDAP_HOST}(來自 ssh 設定)"
}

set_domain() {
    local d part dn=""
    d="$(echo "$1" | xargs)"
    if [[ "$d" =~ ^[A-Za-z0-9-]+$ ]]; then d="${d}.com"; log "LDAP 網域沒有 .xxx 結尾,自動補成 ${d}"; fi
    [[ "$d" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { warn "LDAP 網域格式不正確:$d(格式為 <名稱>.<頂級網域>)"; return 1; }
    IFS='.' read -ra _parts <<< "$d"
    for part in "${_parts[@]}"; do dn+="${dn:+,}dc=${part}"; done
    LDAP_DOMAIN="$d"; BASE_DN="$dn"
    USER_BASE="ou=people,${BASE_DN}"
}

# Log in with the scan account and make sure TARGET_USER no longer exists.
confirm_deleted_on_nas() {
    local a
    printf '\n%s\n' "【NAS】用查詢帳號確認 ${TARGET_USER} 在 NAS 上已經刪除"
    if [ -n "$NAS_ARG" ]; then set_nas "$NAS_ARG" || die "--nas 不正確:$NAS_ARG"
    else until read -rp "NAS [SCAN_USER@]IP:" a && [ -n "$a" ] && set_nas "$a"; do :; done; fi
    if [ -n "$LDAP_DOMAIN" ]; then set_domain "$LDAP_DOMAIN" || die "--domain 不正確:$LDAP_DOMAIN"
    else until read -rp "LDAP 網域(例如 example.com):" a && set_domain "$a"; do :; done; fi
    [ -n "$NAS_USER" ] || NAS_USER="$CFG_SCAN_USER"
    nas_reachable || die "這台電腦連不到 ${LDAP_HOST}:${LDAP_PORT}"

    local u="${NAS_USER:-$DEFAULT_SCAN_USER}" pw dn try rc out
    for try in 1 2 3; do
        if [ "$try" -gt 1 ]; then
            read -rp "要修改 LDAP 網域或查詢帳號嗎?(Enter = 只重新輸入密碼)[y/N] " a
            if [[ "$a" =~ ^[Yy]$ ]]; then
                until read -rp "LDAP 網域 [${LDAP_DOMAIN}]:" a && set_domain "${a:-$LDAP_DOMAIN}"; do :; done
                read -rp "查詢帳號 [${u}]:" a; u="${a:-$u}"
            fi
        elif [ -n "$NAS_USER" ]; then echo "查詢帳號:${u}"
        else read -rp "查詢帳號 [${u}]:" a; u="${a:-$u}"; fi
        valid_name "$u" || { warn "帳號名稱不正確:$u"; continue; }
        dn="uid=${u},${USER_BASE}"
        read_secret pw "${u} 的密碼:"
        [ -n "$pw" ] || { warn "密碼是空的"; continue; }
        rc=0
        out="$(ldap_query_as "$dn" "$pw" -b "$USER_BASE" "(uid=${TARGET_USER})" dn 2>/dev/null)" || rc=$?
        pw=""
        case "$rc" in
            0)  if [[ "$out" == *"dn:"* ]]; then
                    die "${TARGET_USER} 在 NAS 上還存在,請先到 NAS 刪除帳號;沒有修改任何東西"
                fi
                log "已確認:${TARGET_USER} 在 NAS 上不存在"; return ;;
            32) die "找不到 ${USER_BASE},LDAP 網域 ${LDAP_DOMAIN} 可能不對" ;;
            49) warn "${u} 登入失敗(第 ${try}/3 次):LDAP 網域 ${LDAP_DOMAIN}、帳號或密碼其中有錯(LDAP 不會說是哪一個)" ;;
            *)  die "無法查詢 ldaps://${LDAP_HOST}:${LDAP_PORT}(ldapsearch 結束碼 ${rc})" ;;
        esac
    done
    die "已試 3 次,停止"
}

# --- remote (password SSH) ---------------------------------------------------
cleanup() {
    local s
    [ -n "$WORK" ] && [ -d "$WORK" ] || return 0
    for s in "$WORK"/cm-*; do [ -S "$s" ] && ssh -o ControlPath="$s" -O exit _ >/dev/null 2>&1; done
    rm -rf "$WORK"
}

check_ssh_version() {
    local v; v="$(ssh -V 2>&1)"
    [[ "$v" =~ OpenSSH_([0-9]+)\.([0-9]+) ]] || die "看不懂 ssh 版本:$v"
    { [ "${BASH_REMATCH[1]}" -gt 8 ] || { [ "${BASH_REMATCH[1]}" -eq 8 ] && [ "${BASH_REMATCH[2]}" -ge 4 ]; }; } \
        || die "這台電腦需要 OpenSSH 8.4 以上(SSH_ASKPASS_REQUIRE),目前是 $v"
}

set_so() {
    SO=(-o "ControlPath=${WORK}/cm-$1")
    [ -z "${T_USER[$1]}" ] || SO+=(-o "User=${T_USER[$1]}")
    SO+=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
        -o "PreferredAuthentications=password,keyboard-interactive" -o NumberOfPasswordPrompts=1)
}
r_open() {
    set_so "$1"
    SSH_ASKPASS="${WORK}/askpass" SSH_ASKPASS_REQUIRE=force PW_FILE="${WORK}/pw.$1" \
        ssh "${SO[@]}" -o ControlMaster=yes -o ControlPersist=30m -fN "${T_HOST[$1]}" </dev/null
}
r_ssh()    { local i="$1"; shift; set_so "$i"; ssh -n "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"; }
r_ssh_in() { local i="$1"; shift; set_so "$i"; ssh    "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"; }
r_scp()    { local i="$1" dest="$2"; shift 2; set_so "$i"; scp -q "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "$@" "${T_HOST[$i]}:${dest}/"; }

add_host() {
    local arg h u="" pw i rh ru
    arg="$(echo "$1" | xargs)"
    if [[ "$arg" == *@* ]]; then u="${arg%@*}"; h="${arg##*@}"; else h="$arg"; fi
    [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "位址不正確:$h"; return 2; }
    [ -z "$u" ] || valid_name "$u" || { warn "使用者名稱不正確:$u"; return 2; }
    rh="$(ssh_resolve "$h" hostname || true)"; rh="${rh:-$h}"
    ru="${u:-$(ssh_resolve "$h" user || true)}"; ru="${ru:-$(id -un)}"
    [ "$rh" = "$h" ] || log "${h} -> ${ru}@${rh}(來自 ssh 設定)"
    read_secret pw "${ru}@${rh} 的密碼:"
    [ -n "$pw" ] || { warn "密碼是空的"; return 1; }
    i=${#T_HOST[@]}
    T_HOST+=("$h"); T_USER+=("$u"); T_SHOW+=("${ru}@${rh}"); T_ROOT+=(0); T_INFO+=("")
    ( umask 077; printf '%s\n' "$pw" > "${WORK}/pw.$i" )
}

ask_hosts() {
    local h more rc
    printf '\n%s\n' "【目標機器】輸入目標機器的本機帳號(要有 sudo),不是 LDAP 帳號"
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

# sudo_cmd INDEX CMD: run CMD as root on that host (password via stdin)
sudo_cmd() {
    local i="$1" cmd="$2"
    if [ "${T_ROOT[$i]}" -eq 1 ]; then r_ssh "$i" "$cmd"
    else r_ssh_in "$i" "sudo -S -p '' $cmd" < "${WORK}/pw.$i"; fi
}

# copy this script to a private temp dir on the host, run ARGS as root, remove
run_self() {
    local i="$1"; shift
    local rdir rc=0 cmd
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/ldap-user-rm.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }
    cmd="bash $(printf '%q' "$rdir/$(basename "$SELF")")"
    local x; for x in "$@"; do cmd+=" $(printf '%q' "$x")"; done
    sudo_cmd "$i" "$cmd" || rc=$?
    r_ssh "$i" "rm -rf '$rdir'" || true
    return "$rc"
}

precheck() {
    local i="$1" out
    REASON=""
    r_open "$i" || { REASON="SSH 密碼登入失敗"; return 1; }
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${T_SHOW[$i]%@*} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    if out="$(run_self "$i" survey "$TARGET_USER" 2>&1)"; then
        T_INFO[i]="$out"
    else
        REASON="$(echo "$out" | tail -n1)"; return 1
    fi
}

remote_main() {
    [ -t 0 ] || die "需要互動式終端機"
    command -v ldapsearch >/dev/null || die "這台電腦沒有 ldapsearch:sudo apt install ldap-utils"
    check_ssh_version
    WORK="$(mktemp -d /tmp/ldap-user-rm.XXXXXX)"; chmod 700 "$WORK"
    trap cleanup EXIT
    printf '#!/bin/sh\nexec cat "$PW_FILE"\n' > "${WORK}/askpass"; chmod 700 "${WORK}/askpass"

    if [ -z "$TARGET_USER" ]; then
        printf '\n%s\n' "【使用者】要清除的 LDAP 使用者(NAS 上必須已經刪除)"
        until read -rp "使用者名稱:" TARGET_USER && valid_name "$TARGET_USER"; do warn "名稱不正確"; done
    fi
    valid_name "$TARGET_USER" || die "--user 不正確:$TARGET_USER"
    [ "$TARGET_USER" != "admin" ] || die "不能清除 admin"

    confirm_deleted_on_nas
    ask_hosts

    local i ok=() bad=() results=()
    echo
    for i in "${!T_HOST[@]}"; do
        log "檢查 ${T_SHOW[$i]}"
        if precheck "$i"; then ok+=("$i"); else bad+=("${T_SHOW[$i]}:$REASON"); fi
    done
    [ ${#ok[@]} -gt 0 ] || { for i in "${bad[@]}"; do echo "  跳過    $i"; done; die "沒有需要清除的機器,沒有修改任何東西"; }

    echo; echo "================ 摘要:清除 ${TARGET_USER} ================"
    for i in "${ok[@]}"; do
        echo " ${T_SHOW[$i]}"
        echo "${T_INFO[$i]}" | grep -v -e '^uid=' -e '^[[:space:]]*$' | sed 's/^/ /'
    done
    for i in "${bad[@]}"; do echo " 跳過 $i"; done
    echo " 其他地方屬於 ${TARGET_USER} 的檔案不會動"
    echo "=========================================================="
    if [ "$ASSUME_YES" -eq 0 ]; then
        echo "此操作無法復原。"
        flush_stdin
        local a; read -rp "請再次輸入使用者名稱以確認:" a
        [ "$a" = "$TARGET_USER" ] || die "確認的名稱不相符,已中止,沒有修改任何東西"
    fi

    local uid
    for i in "${ok[@]}"; do
        echo; log "========== ${T_SHOW[$i]} =========="
        uid="$(echo "${T_INFO[$i]}" | sed -n 's/^uid=//p' | head -n1)"
        if run_self "$i" clean "$TARGET_USER" "$uid"; then results+=("完成    ${T_SHOW[$i]}")
        else results+=("失敗    ${T_SHOW[$i]}"); fi
    done
    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
}

main() {
    case "${1:-}" in
        survey) [ "$(id -u)" -eq 0 ] || die "需要 root"; survey_here "${2:?}"; return ;;
        clean)  clean_here "${2:?}" "${3:?}"; return ;;
        -h|--help|help) usage 0 ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --user)        TARGET_USER="${2:?}"; shift 2 ;;
            --nas)         NAS_ARG="${2:?}"; shift 2 ;;
            --domain)      LDAP_DOMAIN="${2:?}"; shift 2 ;;
            --host)        IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --tls-reqcert) TLS_REQCERT="${2:?}"; shift 2 ;;
            --yes|-y)      ASSUME_YES=1; shift ;;
            *) die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    case "$TLS_REQCERT" in never|allow|try|demand) ;; *) die "--tls-reqcert 值不正確:$TLS_REQCERT" ;; esac
    [ -n "$NAS_ARG" ]     || NAS_ARG="$CFG_NAS"
    [ -n "$LDAP_DOMAIN" ] || LDAP_DOMAIN="$CFG_DOMAIN"
    if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
    remote_main
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

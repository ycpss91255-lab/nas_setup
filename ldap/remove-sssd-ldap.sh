#!/usr/bin/env bash
# 移除 install-sssd-ldap.sh 在目標機器上做的 LDAP 登入設定。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash remove-sssd-ldap.sh
#
#   1. 目標機器 [SSH_USER@]IP(SSH_USER 可省略,省略就用 ssh 設定;
#      IP 也可以寫 ~/.ssh/config 的名稱),再輸入密碼,可以連續加多台
#   2. 逐台檢查(SSH、sudo、是否裝過),顯示摘要,輸入 y 後全部自動完成
# 第 2 步確認之前,任何機器都不會被修改。
#
# 在目標機器上直接執行:
#   sudo bash remove-sssd-ldap.sh here
#
# 會做的事:
#   - 停用 sssd
#   - 還原 /etc/nsswitch.conf(拿掉 sss)
#   - 停用 PAM mkhomedir(只有當初是安裝腳本啟用的才停)
#   - 刪除 /etc/sudoers.d/90-ldap-groups
#   - 刪除 /etc/sssd/sssd.conf(裡面有查詢帳號密碼)與 sssd 快取(含離線登入用的密碼雜湊)
# 不會做的事:移除套件、刪除 /home 底下 LDAP 使用者的家目錄。
#
# 參數
#   --host [SSH_USER@]IP   目標機器,可重複或用逗號 a,b,c。預設執行時詢問
#   --yes                  跳過最後的確認
#   -h, --help             顯示這份說明
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_HOSTS=""          # --host,例如 admin@192.168.1.21,admin@192.168.1.22
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

SSSD_CONF="/etc/sssd/sssd.conf"
SUDOERS_FILE="/etc/sudoers.d/90-ldap-groups"
STATE_DIR="/var/lib/install-sssd-ldap"
STATE_FILE="${STATE_DIR}/state"
SSS_CACHE_DIRS=(/var/lib/sss/db /var/lib/sss/mc)

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

# --- remove on THIS machine (root) ------------------------------------------
remove_here() {
    [ "$(id -u)" -eq 0 ] || die "需要 root:sudo bash $SELF here"
    if [ ! -f "$STATE_FILE" ] && [ ! -f "$SSSD_CONF" ]; then
        log "$(hostname) 沒有安裝紀錄,也沒有 $SSSD_CONF,不需要移除"
        return 0
    fi

    log "停用 sssd"
    systemctl disable --now sssd >/dev/null 2>&1 || true

    log "刪除 $SUDOERS_FILE"
    rm -f "$SUDOERS_FILE"

    if [ -f "$STATE_FILE" ] && grep -q "mkhomedir_enabled_by_us=1" "$STATE_FILE"; then
        log "停用 PAM mkhomedir(當初是安裝腳本啟用的)"
        DEBIAN_FRONTEND=noninteractive pam-auth-update --disable mkhomedir || true
    fi

    local nss_bak=""
    [ -f "$STATE_FILE" ] && nss_bak="$(grep -m1 '^/etc/nsswitch.conf.bak-sssd-ldap-' "$STATE_FILE" || true)"
    if [ -n "$nss_bak" ] && [ -f "$nss_bak" ]; then
        log "還原 /etc/nsswitch.conf(來自 $nss_bak)"
        cp -a "$nss_bak" /etc/nsswitch.conf
    fi
    # also covers a missing backup: drop sss from passwd/group/shadow
    sed -i -E 's/^((passwd|group|shadow):.*)[[:space:]]+sss\b/\1/' /etc/nsswitch.conf

    log "刪除 $SSSD_CONF 與 sssd 快取"
    rm -f "$SSSD_CONF"
    local d
    for d in "${SSS_CACHE_DIRS[@]}"; do
        [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -type f -delete
    done

    rm -rf "$STATE_DIR"
    log "$(hostname) 移除完成。LDAP 使用者已無法登入;本機帳號不受影響。"
    log "套件保留,要移除可執行:apt purge sssd sssd-ldap sssd-tools libnss-sss libpam-sss"
    log "/home 底下 LDAP 使用者的家目錄沒有刪除。"
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

ssh_resolve() { ssh -G "$1" 2>/dev/null | awk -v f="$2" '$1==f {print $2; exit}'; }

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
    read_secret pw "${ru}@${rh} 的密碼:"
    [ -n "$pw" ] || { warn "密碼是空的"; return 1; }
    i=${#T_HOST[@]}
    T_HOST+=("$h"); T_USER+=("$u"); T_SHOW+=("${ru}@${rh}"); T_ROOT+=(0)
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

precheck() {
    local i="$1"
    REASON=""
    r_open "$i" || { REASON="SSH 密碼登入失敗"; return 1; }
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${T_SHOW[$i]%@*} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    r_ssh "$i" "[ -f '$STATE_FILE' ] || [ -f '$SSSD_CONF' ]" >/dev/null 2>&1 \
        || { REASON="沒有安裝紀錄,也沒有 $SSSD_CONF,不需要移除"; return 1; }
}

run_on() {
    local i="$1" rdir rc=0
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/sssd-ldap-rm.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }
    local cmd; cmd="bash $(printf '%q' "$rdir/$(basename "$SELF")") here"
    if [ "${T_ROOT[$i]}" -eq 1 ]; then
        r_ssh "$i" "$cmd" || rc=$?
    else
        r_ssh_in "$i" "sudo -S -p '' $cmd" < "${WORK}/pw.$i" || rc=$?
    fi
    r_ssh "$i" "rm -rf '$rdir'" || warn "${T_SHOW[$i]}:無法刪除 $rdir"
    return "$rc"
}

remote_main() {
    [ -t 0 ] || die "需要互動式終端機"
    command -v ssh >/dev/null && command -v scp >/dev/null || die "找不到 ssh 或 scp"
    check_ssh_version
    WORK="$(mktemp -d /tmp/sssd-remove.XXXXXX)"; chmod 700 "$WORK"
    trap cleanup EXIT
    printf '#!/bin/sh\nexec cat "$PW_FILE"\n' > "${WORK}/askpass"
    chmod 700 "${WORK}/askpass"

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
    [ ${#ok[@]} -gt 0 ] || die "沒有需要移除的機器,沒有修改任何東西"

    for i in "${ok[@]}"; do names+=("${T_SHOW[$i]}"); done
    cat <<EOF

================ 摘要 ================
 目標機器 :${names[*]}
 會移除   :LDAP 登入設定(sssd 停用、nsswitch 還原、sudo 設定、
           sssd.conf 與快取);套件與家目錄保留
 移除後   :LDAP 使用者無法登入這些機器,本機帳號不受影響
======================================
EOF
    if [ "$ASSUME_YES" -eq 0 ]; then
        local a; read -rp "確定移除?[y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
    fi

    for i in "${ok[@]}"; do
        echo; log "========== ${T_SHOW[$i]} =========="
        if run_on "$i"; then results+=("完成    ${T_SHOW[$i]}"); else results+=("失敗    ${T_SHOW[$i]}"); fi
    done
    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
}

main() {
    case "${1:-}" in
        here)           remove_here; return ;;
        -h|--help|help) usage 0 ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --host) IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
    remote_main
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

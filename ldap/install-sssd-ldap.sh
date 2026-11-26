#!/usr/bin/env bash
# 讓 Debian/Ubuntu 機器(CI runner 主機、叢集節點等)透過 sssd
# 使用 NAS 內建 LDAP 的帳號登入。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash install-sssd-ldap.sh
#
#   1. NAS [SCAN_USER@]IP(SCAN_USER 可省略,省略就下一步再問;
#      IP 也可以寫 ~/.ssh/config 的名稱)
#      LDAP 網域(NAS「LDAP 伺服器」頁的「完整網域名稱」,例如 example.com;
#      只打 example 會自動補成 example.com)
#   2. 查詢用的 LDAP 帳號(第 1 步沒寫就問,預設 scan_group)與密碼;
#      不是登入目標機器的帳號,登入時大家用自己的 LDAP 帳號
#   3. 勾選可登入的群組(複選),再勾選其中哪些可以 sudo
#   4. 目標機器 [SSH_USER@]IP(SSH_USER 可省略,省略就用 ssh 設定;
#      IP 也可以寫 ~/.ssh/config 的名稱),再輸入密碼,可以連續加多台
#   5. 逐台檢查(SSH、sudo、該機連得到 NAS:636),顯示摘要,
#      輸入 y 後全部自動完成
# 第 5 步確認之前,任何機器都不會被修改。
# 密碼只在執行時輸入,不會存在這台電腦(暫存檔結束時刪除)。
#
# 在單一機器上直接執行:
#   bash install-sssd-ldap.sh install [參數]   # 同樣的問題,只設定這一台
#   bash install-sssd-ldap.sh check   [使用者] # 唯讀檢查狀態
# 移除請用同目錄的 remove-sssd-ldap.sh。
#
# 參數(每個參數會跳過對應的問題)
# 沒給的參數先用腳本最上面「預設值」區塊的值,那裡也空白才會問。
# 密碼沒有參數可以給,一律執行時輸入。
#   --nas [SCAN_USER@]IP   NAS 與查詢用的 LDAP 帳號。IP 可用 ssh 設定名稱(只取 HostName,
#                          不取 ssh 的 User);沒寫 SCAN_USER 會問,預設 scan_group
#   --domain DOMAIN        LDAP 網域,例如 example.com(沒有 .xxx 結尾會自動補 .com)
#   --host [SSH_USER@]IP   目標機器,可重複或用逗號 a,b,c。IP 可用 ssh 設定名稱,
#                          沒寫 SSH_USER 時用 ssh 設定的 User(再沒有就是你的使用者名稱)
#   --allow-groups LIST    可登入的群組,逗號分隔。預設用選單勾選
#   --sudo-groups LIST     可 sudo 的群組,"" = 不給。預設用選單勾選
#   --tls-reqcert MODE     never|allow|try|demand。預設 allow
#   --no-cache-credentials 關閉離線登入快取
#   --yes                  跳過最後的確認
#   --force                (install)連不到 NAS 也繼續
#   -h, --help             顯示這份說明
#
# 範例:
#   bash install-sssd-ldap.sh --nas <SCAN_USER>@<NAS_IP> --domain <LDAP_DOMAIN> \
#        --host <SSH_USER>@<HOST_IP>,<SSH_HOST_ALIAS> \
#        --allow-groups cluster-admins --sudo-groups cluster-admins
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_NAS=""            # --nas,NAS 位址,例如 192.168.1.10(可寫成 帳號@IP)
CFG_SCAN_USER="scan_group"  # 查詢帳號;空白 = 每次問
CFG_DOMAIN=""         # --domain,例如 example.com
CFG_HOSTS=""          # --host,例如 admin@192.168.1.21,admin@192.168.1.22
CFG_ALLOW_GROUPS=""   # --allow-groups,例如 cluster-admins,cluster-users
CFG_SUDO_GROUPS=""    # --sudo-groups,例如 cluster-admins;none = 不給;空白 = 選單
CFG_YES=0             # 1 = 所有確認自動回答 y
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# --- defaults ---------------------------------------------------------------
NAS_ARG=""               # --nas [SCAN_USER@]IP (asked when empty)
NAS_USER=""              # USER part of --nas
LDAP_HOST=""             # resolved NAS address
LDAP_DOMAIN=""           # --domain (asked when empty)
ARG_HOSTS=()             # --host [SSH_USER@]IP
LDAP_PORT="636"
BASE_DN=""               # derived from LDAP_DOMAIN: <a>.<b> -> dc=<a>,dc=<b>
USER_BASE=""
GROUP_BASE=""
SSSD_DOMAIN=""
ALLOW_GROUPS=""          # empty -> choose interactively
SUDO_GROUPS=""
SUDO_GROUPS_SET=0        # 1 when --sudo-groups was given (even if empty)
ASSUME_YES=0
FORCE=0
# Never offered in the menus: "Domain Users" contains every LDAP account,
# including the bind account, and names with spaces break sudoers.
EXCLUDED_GROUPS=("Domain Users")
DEFAULT_SCAN_USER="scan_group"
BIND_DN=""
BIND_PW_FILE=""          # internal (deploy -> host)
BIND_PW=""
FROM_DEPLOY=0            # internal: install started by deploy on the PC
TLS_REQCERT="allow"
CACHE_CREDS="true"
MIN_ID="1000000"
DEFAULT_SHELL="/bin/bash"

# deploy state (PC side)
WORK=""                  # 700 temp dir: askpass helper, password files, sockets
T_HOST=()                # host address as typed (IP or ssh config name)
T_USER=()                # SSH user typed as USER@, empty = ssh config decides
T_SHOW=()                # user@hostname as ssh resolves it, for display
T_ROOT=()                # 1 when that user is root (no sudo needed)
T_CONFLICT=()            # local accounts on the host that shadow LDAP users
MEMBERS=()               # LDAP users in the allowed login groups
SO=()                    # ssh options for the current host (set_so)

SSSD_CONF="/etc/sssd/sssd.conf"
SUDOERS_FILE="/etc/sudoers.d/90-ldap-groups"
STATE_DIR="/var/lib/install-sssd-ldap"
STATE_FILE="${STATE_DIR}/state"
STAMP="$(date +%Y%m%d-%H%M%S)"
PKGS=(sssd sssd-ldap sssd-tools libnss-sss libpam-sss ldap-utils)

die()  { echo "錯誤:$*" >&2; exit 1; }

APT_LOG="/var/log/install-sssd-ldap-apt.log"
# apt_q ARGS...: run apt-get quietly, full output in $APT_LOG, tail on failure
apt_q() {
    if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
         apt-get -y -q "$@" </dev/null >>"$APT_LOG" 2>&1; then
        tail -n 20 "$APT_LOG" >&2
        die "apt-get $* 失敗,完整記錄在 $APT_LOG"
    fi
}
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }

# usage [EXIT_CODE]: print the header comment without the leading "# "
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
# preset_secret NAME VAR: password prepared by install-all.sh (600 file in a
# 700 temp dir it deletes at exit); 1 = none, ask as usual
preset_secret() {
    local f="${INSTALL_ALL_SECRETS:-}/$1"
    [ -n "${INSTALL_ALL_SECRETS:-}" ] && [ -r "$f" ] || return 1
    printf -v "$2" '%s' "$(head -n1 "$f")"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "==> 需要 root 權限,用 sudo 重新執行..."
        exec sudo bash "$SELF" "$@"
    fi
}

parse_opts() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --nas)                  NAS_ARG="${2:?}"; shift 2 ;;
            --domain)               LDAP_DOMAIN="${2:?}"; shift 2 ;;
            --host)                 IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --allow-groups)         ALLOW_GROUPS="${2:?}"; shift 2 ;;
            --sudo-groups)          SUDO_GROUPS="${2:-}"; SUDO_GROUPS_SET=1; shift 2 ;;
            --tls-reqcert)          TLS_REQCERT="${2:?}"; shift 2 ;;
            --no-cache-credentials) CACHE_CREDS="false"; shift ;;
            --yes|-y)               ASSUME_YES=1; shift ;;
            --force)                FORCE=1; shift ;;
            # internal, used by deploy when it runs install on a host
            --bind-dn)              BIND_DN="${2:?}"; shift 2 ;;
            --bind-pw-file)         BIND_PW_FILE="${2:?}"; shift 2 ;;
            --from-deploy)          FROM_DEPLOY=1; shift ;;
            *)                      die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    case "$TLS_REQCERT" in never|allow|try|demand) ;; *) die "--tls-reqcert 值不正確:$TLS_REQCERT" ;; esac
    [ "$FROM_DEPLOY" -eq 1 ] || apply_defaults
}

# apply_defaults: fill what the options did not give from the CFG_* block
apply_defaults() {
    [ -n "$NAS_ARG" ]      || NAS_ARG="$CFG_NAS"
    [ -n "$LDAP_DOMAIN" ]  || LDAP_DOMAIN="$CFG_DOMAIN"
    [ -n "$ALLOW_GROUPS" ] || ALLOW_GROUPS="$CFG_ALLOW_GROUPS"
    if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
    if [ "$SUDO_GROUPS_SET" -eq 0 ] && [ -n "$CFG_SUDO_GROUPS" ]; then
        SUDO_GROUPS="$CFG_SUDO_GROUPS"; [ "$SUDO_GROUPS" != "none" ] || SUDO_GROUPS=""
        SUDO_GROUPS_SET=1
    fi
    [ "$CFG_YES" != "1" ] || ASSUME_YES=1
}

nas_reachable() { timeout 5 bash -c "</dev/tcp/${LDAP_HOST}/${LDAP_PORT}" 2>/dev/null; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# --- LDAP helpers -----------------------------------------------------------
# ldap_query_as DN PASSWORD ldapsearch-args...  (password via a 600 temp file)
ldap_query_as() {
    local dn="$1" pw="$2"; shift 2
    local pwf rc=0; pwf="$(mktemp)"; chmod 600 "$pwf"
    printf '%s' "$pw" > "$pwf"
    LDAPTLS_REQCERT="$TLS_REQCERT" ldapsearch -x -LLL -o ldif-wrap=no \
        -H "ldaps://${LDAP_HOST}:${LDAP_PORT}" -D "$dn" -y "$pwf" "$@" || rc=$?
    rm -f "$pwf"
    return "$rc"
}

# stdin: ldapsearch output -> one cn per line (decodes base64 "cn::")
decode_cn() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "cn:: "*) printf '%s\n' "${line#cn:: }" | base64 -d; echo ;;
            "cn: "*)  printf '%s\n' "${line#cn: }" ;;
        esac
    done
}

# ssh_resolve ADDR FIELD: what ssh would use (~/.ssh/config), e.g. hostname/user
ssh_resolve() {
    command -v ssh >/dev/null || return 1
    ssh -G "$1" 2>/dev/null | awk -v f="$2" '$1==f {print $2; exit}'
}

# set_nas "[USER@]ADDR": NAS_USER + LDAP_HOST (ssh config name -> HostName)
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

# set_domain DOMAIN: <a>.<b> -> dc=<a>,dc=<b>
set_domain() {
    local d part dn=""
    d="$(echo "$1" | xargs)"
    # forgot the top-level part ("example" instead of "example.com"): add .com
    if [[ "$d" =~ ^[A-Za-z0-9-]+$ ]]; then
        d="${d}.com"
        log "LDAP 網域沒有 .xxx 結尾,自動補成 ${d}"
    fi
    [[ "$d" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { warn "LDAP 網域格式不正確:$d(格式為 <名稱>.<頂級網域>)"; return 1; }
    IFS='.' read -ra _parts <<< "$d"
    for part in "${_parts[@]}"; do dn+="${dn:+,}dc=${part}"; done
    LDAP_DOMAIN="$d"; SSSD_DOMAIN="$d"; BASE_DN="$dn"
    USER_BASE="ou=people,${BASE_DN}"; GROUP_BASE="ou=group,${BASE_DN}"
}

# Ask for whatever --nas / --domain did not give. Nothing is hard coded.
ask_nas() {
    local a
    if [ -z "$NAS_ARG" ] || [ -z "$LDAP_DOMAIN" ]; then
        printf '\n%s\n' "【NAS】SCAN_USER 是查詢用的 LDAP 帳號,不是登入目標機器的帳號"
    fi
    if [ -n "$NAS_ARG" ]; then
        set_nas "$NAS_ARG" || die "--nas 不正確:$NAS_ARG"
    else
        [ -t 0 ] || die "需要 --nas"
        until read -rp "NAS [SCAN_USER@]IP:" a && [ -n "$a" ] && set_nas "$a"; do :; done
    fi
    [ -n "$NAS_USER" ] || NAS_USER="$CFG_SCAN_USER"
    if [ -n "$LDAP_DOMAIN" ]; then
        set_domain "$LDAP_DOMAIN" || die "--domain 不正確:$LDAP_DOMAIN"
    else
        [ -t 0 ] || die "需要 --domain"
        until read -rp "LDAP 網域(例如 example.com):" a && set_domain "$a"; do :; done
    fi
    log "LDAP:ldaps://${LDAP_HOST}:${LDAP_PORT},base DN ${BASE_DN}"
}

# check_nas: returns 1 (with a message) when this machine cannot reach the NAS
check_nas() {
    log "檢查 $(hostname) -> ${LDAP_HOST}:${LDAP_PORT} 是否連得到"
    nas_reachable && return 0
    warn "$(hostname) 連不到 ${LDAP_HOST}:${LDAP_PORT}"
    return 1
}

# Typed by hand every time (no file/option form). The account is used to
# read groups AND is written into sssd.conf on every host as the bind account.
nas_login() {
    [ -t 0 ] || die "需要互動式終端機(不支援自動登入)"
    printf '\n%s\n' "【查詢帳號】目標機器用它向 NAS 查詢使用者,密碼會存在每台目標機器"
    local u="${NAS_USER:-$DEFAULT_SCAN_USER}" a try rc
    for try in 1 2 3; do
        if [ "$try" -gt 1 ]; then
            # a wrong domain/account also gives "invalid credentials"
            read -rp "要修改 LDAP 網域或查詢帳號嗎?(Enter = 只重新輸入密碼)[y/N] " a
            if [[ "$a" =~ ^[Yy]$ ]]; then
                until read -rp "LDAP 網域 [${LDAP_DOMAIN}]:" a && set_domain "${a:-$LDAP_DOMAIN}"; do :; done
                read -rp "查詢帳號 [${u}]:" a; u="${a:-$u}"
            fi
        elif [ -n "$NAS_USER" ]; then
            echo "查詢帳號:${u}"
        else
            read -rp "查詢帳號 [${u}]:" a
            u="${a:-$u}"
        fi
        if ! valid_name "$u"; then warn "帳號名稱不正確:$u"; u="$DEFAULT_SCAN_USER"; continue; fi
        if [ "$u" = "admin" ]; then warn "不能用 admin(它的密碼會被存到每台機器上)"; u="$DEFAULT_SCAN_USER"; continue; fi
        BIND_DN="uid=${u},${USER_BASE}"
        if [ "$try" -eq 1 ] && preset_secret bind BIND_PW; then :; else read_secret BIND_PW "${u} 的密碼:"; fi
        [ -n "$BIND_PW" ] || { warn "密碼是空的"; continue; }
        rc=0
        ldap_query_as "$BIND_DN" "$BIND_PW" -b "$GROUP_BASE" -s base "(objectClass=*)" dn >/dev/null 2>&1 || rc=$?
        case "$rc" in
            0)  log "已登入:${BIND_DN}"; refuse_privileged "$u"; return ;;
            49) warn "${u} 登入失敗(第 ${try}/3 次):LDAP 網域 ${LDAP_DOMAIN}、帳號或密碼其中有錯(LDAP 不會說是哪一個)" ;;
            *)  die "無法連線到 ldaps://${LDAP_HOST}:${LDAP_PORT}(ldapsearch 結束碼 ${rc},TLS 模式 ${TLS_REQCERT})" ;;
        esac
    done
    die "已試 3 次,停止"
}

# The bind account's password sits on every host: it must not be able to log in.
refuse_privileged() {
    local u="$1" g bad=()
    while IFS= read -r g; do
        [ -n "$g" ] && ! is_excluded "$g" && bad+=("$g")
    done < <(ldap_query_as "$BIND_DN" "$BIND_PW" -b "$GROUP_BASE" \
                 "(&(objectClass=posixGroup)(memberUid=${u}))" cn 2>/dev/null | decode_cn)
    [ ${#bad[@]} -eq 0 ] || die "${u} 屬於群組:${bad[*]}。這個帳號的密碼會存在每台機器上,不能加入任何群組。請在 NAS 另建專用帳號(例如 ${DEFAULT_SCAN_USER})。"
}

# install from deploy: bind password comes in a 600 file from the PC
read_bind_pw_file() {
    [ -r "$BIND_PW_FILE" ] || die "讀不到 $BIND_PW_FILE"
    BIND_PW="$(head -n1 "$BIND_PW_FILE")"
    [ -n "$BIND_PW" ] || die "sssd 帳號密碼是空的"
}

test_bind() {
    log "從 $(hostname) 測試 LDAP 帳號 ${BIND_DN}"
    ldap_query_as "$BIND_DN" "$BIND_PW" -b "$GROUP_BASE" "(objectClass=posixGroup)" cn >/dev/null 2>&1 \
        || die "從 $(hostname) 登入 LDAP 失敗"
}

fetch_groups() {
    ldap_query_as "$BIND_DN" "$BIND_PW" -b "$GROUP_BASE" "(objectClass=posixGroup)" cn 2>/dev/null \
        | decode_cn | sort -u
}

is_excluded() {
    local g="$1" x
    for x in "${EXCLUDED_GROUPS[@]}"; do [ "$g" = "$x" ] && return 0; done
    valid_name "$g" || return 0
    return 1
}

# pick_groups TITLE CANDIDATE... -> prints chosen groups comma separated
pick_groups() {
    local title="$1"; shift
    local cands=("$@") chosen=() g i
    [ ${#cands[@]} -gt 0 ] || { echo ""; return; }
    if command -v whiptail >/dev/null && [ -t 0 ]; then
        local items=() out
        for g in "${cands[@]}"; do items+=("$g" "" OFF); done
        out="$(whiptail --title "install-sssd-ldap" --separate-output \
              --checklist "$title\n(空白鍵 = 勾選/取消,Enter = 確定)" 20 70 10 \
              "${items[@]}" 3>&1 1>&2 2>&3)" || die "已取消"
        while IFS= read -r g; do [ -n "$g" ] && chosen+=("$g"); done <<< "$out"
    else
        {
            echo
            echo "$title"
            for i in "${!cands[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${cands[$i]}"; done
        } >&2
        local ans n
        read -rp "輸入編號,用逗號分隔(空白 = 都不選):" ans
        IFS=',' read -ra _nums <<< "$ans"
        for n in "${_nums[@]}"; do
            n="$(echo "$n" | xargs)"; [ -n "$n" ] || continue
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#cands[@]} ] \
                || die "選項不正確:$n"
            chosen+=("${cands[$((n-1))]}")
        done
    fi
    local IFS=','; echo "${chosen[*]}"
}

# Menus (unless given by options) + every chosen group must exist on the NAS.
choose_groups() {
    local target="$1" all=() offer=() g
    log "從 ${LDAP_HOST} 讀取 LDAP 群組"
    while IFS= read -r g; do [ -n "$g" ] && all+=("$g"); done < <(fetch_groups)
    [ ${#all[@]} -gt 0 ] || die "$GROUP_BASE 底下找不到任何群組"
    for g in "${all[@]}"; do is_excluded "$g" || offer+=("$g"); done
    log "NAS 上的群組:${all[*]}"
    [ ${#offer[@]} -gt 0 ] || die "沒有可選的群組(請先在 NAS 建立,例如 cluster-admins)"

    if [ -z "$ALLOW_GROUPS" ]; then
        printf '\n%s\n' "【群組】選哪些群組可以登入、哪些可以 sudo"
        ALLOW_GROUPS="$(pick_groups "哪些群組可以登入「${target}」?" "${offer[@]}")"
    fi
    [ -n "$ALLOW_GROUPS" ] || die "沒有選可登入的群組,這樣 LDAP 使用者都登不進去"

    local req found x
    IFS=',' read -ra req <<< "$ALLOW_GROUPS"
    for g in "${req[@]}"; do
        g="$(echo "$g" | xargs)"; found=0
        for x in "${all[@]}"; do [ "$x" = "$g" ] && found=1 && break; done
        [ "$found" -eq 1 ] || die "NAS 上沒有群組 $g"
        is_excluded "$g" && die "群組 $g 不能使用(Domain Users 或名稱含空白)"
    done

    if [ "$SUDO_GROUPS_SET" -eq 0 ]; then
        SUDO_GROUPS="$(pick_groups "其中哪些群組可以在「${target}」使用 sudo?" "${req[@]}")"
        SUDO_GROUPS_SET=1
    fi
}

# --- install on THIS machine -------------------------------------------------
# backup FILE: once per install. A re-run keeps the first backup (the one taken
# before this script ever touched the file), so remove restores the original.
backup() {
    local f="$1"
    grep -q "^${f}.bak-sssd-ldap-" "$STATE_FILE" 2>/dev/null && return 0
    [ -e "$f" ] && cp -a "$f" "${f}.bak-sssd-ldap-${STAMP}" && echo "$f.bak-sssd-ldap-${STAMP}" >> "$STATE_FILE"
    return 0
}

write_sssd_conf() {
    log "寫入 $SSSD_CONF"
    install -d -m0711 /etc/sssd
    backup "$SSSD_CONF"
    umask 077
    cat > "$SSSD_CONF" <<EOF
# Managed by install-sssd-ldap.sh (${STAMP}). LDAP server: ${LDAP_HOST}.
[sssd]
config_file_version = 2
services = nss, pam
domains = ${SSSD_DOMAIN}

[nss]

[pam]

[domain/${SSSD_DOMAIN}]
id_provider = ldap
auth_provider = ldap
# Passwords are changed on the NAS, not from Linux.
chpass_provider = none
access_provider = simple
simple_allow_groups = ${ALLOW_GROUPS}

ldap_uri = ldaps://${LDAP_HOST}:${LDAP_PORT}
ldap_schema = rfc2307
ldap_search_base = ${BASE_DN}
ldap_user_search_base = ${USER_BASE}
ldap_group_search_base = ${GROUP_BASE}
ldap_default_bind_dn = ${BIND_DN}
ldap_default_authtok_type = password
ldap_default_authtok = ${BIND_PW}
# allow = encrypted, server certificate not verified (see --tls-reqcert).
ldap_tls_reqcert = ${TLS_REQCERT}

min_id = ${MIN_ID}
enumerate = false
cache_credentials = ${CACHE_CREDS}
# Used when an LDAP user has no loginShell attribute.
default_shell = ${DEFAULT_SHELL}
fallback_homedir = /home/%u
EOF
    chmod 600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"
    umask 022
}

patch_nsswitch() {
    log "在 /etc/nsswitch.conf 的 passwd、group、shadow 加入 sss"
    backup /etc/nsswitch.conf
    local db
    for db in passwd group shadow; do
        if grep -qE "^${db}:" /etc/nsswitch.conf; then
            grep -qE "^${db}:.*\bsss\b" /etc/nsswitch.conf || \
                sed -i -E "s/^(${db}:.*)$/\1 sss/" /etc/nsswitch.conf
        else
            echo "${db}: files sss" >> /etc/nsswitch.conf
        fi
    done
}

enable_mkhomedir() {
    if [ -f /usr/share/pam-configs/mkhomedir ]; then
        if ! grep -q pam_mkhomedir /etc/pam.d/common-session 2>/dev/null; then
            log "啟用 PAM mkhomedir(第一次登入時自動建立家目錄)"
            DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir
            echo "mkhomedir_enabled_by_us=1" >> "$STATE_FILE"
        else
            log "PAM mkhomedir 已經啟用"
        fi
    else
        warn "找不到 /usr/share/pam-configs/mkhomedir,家目錄不會自動建立"
    fi
}

write_sudoers() {
    [ -n "$SUDO_GROUPS" ] || { log "沒有 sudo 群組,不寫 sudoers"; return; }
    log "給這些 LDAP 群組 sudo 權限:$SUDO_GROUPS"
    local tmp g; tmp="$(mktemp)"
    echo "# Managed by install-sssd-ldap.sh (${STAMP})" > "$tmp"
    IFS=',' read -ra _g <<< "$SUDO_GROUPS"
    for g in "${_g[@]}"; do
        g="$(echo "$g" | xargs)"
        valid_name "$g" || die "sudo 群組名稱不能含空白:$g"
        echo "%${g} ALL=(ALL:ALL) ALL" >> "$tmp"
    done
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "產生的 sudoers 沒通過 visudo 檢查"; }
    install -m0440 -o root -g root "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"
}

confirm() {
    cat <<EOF

================ 摘要 ================
 目標機器     :$1
 LDAP         :ldaps://${LDAP_HOST}:${LDAP_PORT}(tls_reqcert=${TLS_REQCERT})
 sssd 帳號    :${BIND_DN}(存在 ${SSSD_CONF},權限 600)
 可登入群組   :${ALLOW_GROUPS}
 sudo 群組    :${SUDO_GROUPS:-<無>}
 離線登入快取 :${CACHE_CREDS}
 會修改       :${SSSD_CONF}、/etc/nsswitch.conf、PAM mkhomedir、
               ${SUDOERS_FILE}
======================================
EOF
    [ "$ASSUME_YES" -eq 1 ] && return
    local a; read -rp "確定套用?[y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
}

install_tool() {
    parse_opts "$@"
    command -v apt-get >/dev/null || die "只支援 Debian/Ubuntu(apt)"

    ask_nas
    if ! check_nas; then
        [ "$FORCE" -eq 1 ] && [ "$FROM_DEPLOY" -eq 0 ] || die "這台連不到 NAS,LDAP 登入會失敗"
        warn "因為 --force,繼續執行"
    fi

    log "安裝 ldap-utils"
    apt_q update
    apt_q install ldap-utils

    if [ "$FROM_DEPLOY" -eq 1 ]; then
        # Groups were chosen on the PC; still validate them against the NAS.
        [ -n "$BIND_DN" ] && [ -n "$BIND_PW_FILE" ] && [ -n "$ALLOW_GROUPS" ] && [ "$SUDO_GROUPS_SET" -eq 1 ] \
            || die "--from-deploy 需要 --bind-dn、--bind-pw-file、--allow-groups、--sudo-groups"
        read_bind_pw_file; test_bind
        choose_groups "$(hostname)"
    else
        nas_login
        choose_groups "$(hostname)"
    fi
    [ "$FROM_DEPLOY" -eq 1 ] || confirm "$(hostname)"

    install -d -m0700 "$STATE_DIR"
    # keep the state of an earlier install (re-run): it records what to undo
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    log "安裝套件:${PKGS[*]}"
    apt_q install "${PKGS[@]}"

    write_sssd_conf
    BIND_PW=""
    patch_nsswitch
    enable_mkhomedir
    write_sudoers

    log "重新啟動 sssd"
    systemctl enable sssd >/dev/null 2>&1 || true
    systemctl restart sssd
    sss_cache -E 2>/dev/null || true

    if [ "$FROM_DEPLOY" -eq 1 ]; then
        log "$(hostname) 完成"
    else
        log "$(hostname) 完成。檢查:bash $SELF check <LDAP 使用者>"
    fi
    log "SSH:LDAP 使用者用 LDAP 密碼登入,sshd 必須允許 PasswordAuthentication(本腳本不改)。"
    log "     SSH 公鑰不在 LDAP 裡,第一次登入後自己放到 ~/.ssh/authorized_keys。"
}

# --- deploy from YOUR PC (password SSH, no keys needed) ---------------------
# One ControlMaster connection per host: the password is used once to log
# in (through an askpass helper reading a 600 file, so it is never on a
# command line), every later ssh/scp reuses that connection.
deploy_cleanup() {
    local s
    [ -n "$WORK" ] && [ -d "$WORK" ] || return 0
    for s in "$WORK"/cm-*; do
        [ -S "$s" ] && ssh -o ControlPath="$s" -O exit _ >/dev/null 2>&1
    done
    rm -rf "$WORK"
}

check_ssh_version() {
    local v maj min
    v="$(ssh -V 2>&1)"
    [[ "$v" =~ OpenSSH_([0-9]+)\.([0-9]+) ]] || die "看不懂 ssh 版本:$v"
    maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"
    { [ "$maj" -gt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -ge 4 ]; }; } \
        || die "這台電腦需要 OpenSSH 8.4 以上(SSH_ASKPASS_REQUIRE),目前是 $v"
}

# set_so INDEX -> SO = ssh options for that host
set_so() {
    SO=(-o "ControlPath=${WORK}/cm-$1")
    [ -z "${T_USER[$1]}" ] || SO+=(-o "User=${T_USER[$1]}")
    SO+=(-o ConnectTimeout=8
        -o StrictHostKeyChecking=accept-new
        -o "PreferredAuthentications=password,keyboard-interactive"
        -o NumberOfPasswordPrompts=1)
}

# r_open INDEX: log in once with the password, keep the master connection
r_open() {
    set_so "$1"
    SSH_ASKPASS="${WORK}/askpass" SSH_ASKPASS_REQUIRE=force DEPLOY_PW_FILE="${WORK}/pw.$1" \
        ssh "${SO[@]}" -o ControlMaster=yes -o ControlPersist=30m -fN "${T_HOST[$1]}" </dev/null
}

# r_ssh INDEX CMD: run over the existing master (never prompts, stdin from
# /dev/null so it cannot eat what you type); r_ssh_in passes stdin through.
r_ssh() {
    local i="$1"; shift
    set_so "$i"
    ssh -n "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"
}
r_ssh_in() {
    local i="$1"; shift
    set_so "$i"
    ssh "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "${T_HOST[$i]}" "$@"
}

r_scp() {
    local i="$1" dest="$2"; shift 2
    set_so "$i"
    scp -q "${SO[@]}" -o ControlMaster=no -o BatchMode=yes "$@" "${T_HOST[$i]}:${dest}/"
}

# add_host "[USER@]ADDR": ADDR may be an ssh config name; without USER@ the
# ssh config User applies. Asks the password. 1 = bad password input,
# 2 = bad address (retrying the same text will not help).
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
    T_HOST+=("$h"); T_USER+=("$u"); T_SHOW+=("${ru}@${rh}"); T_ROOT+=(0); T_CONFLICT+=("")
    ( umask 077; printf '%s\n' "$pw" > "${WORK}/pw.$i" )
}

ask_hosts() {
    local h more
    printf '\n%s\n' "【目標機器】輸入目標機器的本機帳號(要有 sudo),不是 LDAP 帳號"
    if [ ${#ARG_HOSTS[@]} -gt 0 ]; then
        local rc
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

# precheck INDEX -> 0 ok, else 1 with REASON set (no subshell: sets T_ROOT)
REASON=""
precheck() {
    local i="$1" h="${T_HOST[$1]}"
    REASON=""
    if ! r_open "$i"; then REASON="SSH 密碼登入失敗"; return 1; fi
    ssh-keygen -lF "${T_SHOW[$i]##*@}" 2>/dev/null | grep -v '^#' | sed 's/^/    host key: /' >&2 || true
    r_ssh "$i" 'command -v apt-get' >/dev/null 2>&1 || { REASON="不是 Debian/Ubuntu(沒有 apt-get)"; return 1; }
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${T_SHOW[$i]%@*} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    r_ssh "$i" "timeout 5 bash -c '</dev/tcp/${LDAP_HOST}/${LDAP_PORT}'" >/dev/null 2>&1 \
        || { REASON="這台連不到 ${LDAP_HOST}:${LDAP_PORT}(LDAP 登入會失敗)"; return 1; }
    check_conflicts "$i"
    return 0
}

# LDAP users (memberUid) of the allowed login groups -> MEMBERS
fetch_members() {
    local g line m
    MEMBERS=()
    IFS=',' read -ra _ag <<< "$ALLOW_GROUPS"
    for g in "${_ag[@]}"; do
        g="$(echo "$g" | xargs)"
        while IFS= read -r line; do
            m="${line#memberUid: }"
            [ "$m" != "$line" ] && valid_name "$m" && MEMBERS+=("$m")
        done < <(ldap_query_as "$BIND_DN" "$BIND_PW" -b "cn=${g},${GROUP_BASE}" -s base memberUid 2>/dev/null)
    done
    [ ${#MEMBERS[@]} -gt 0 ] || return 0
    mapfile -t MEMBERS < <(printf '%s\n' "${MEMBERS[@]}" | sort -u)
}

# local accounts in /etc/passwd with the same name as an LDAP user win
# (nsswitch "files" comes before "sss"): that LDAP user cannot log in there
check_conflicts() {
    local i="$1" q=""
    [ ${#MEMBERS[@]} -gt 0 ] || return 0
    q="$(printf '%q ' "${MEMBERS[@]}")"
    T_CONFLICT[i]="$(r_ssh "$i" "for u in $q; do grep -q \"^\$u:\" /etc/passwd && printf '%s ' \"\$u\"; done; true" 2>/dev/null || true)"
}

# run_on INDEX: copy script + bind password, run install, clean up
run_on() {
    local i="$1" rdir cmd rc=0 base
    base="$(basename "$SELF")"
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/sssd-ldap.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" "${WORK}/bindpw" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }

    cmd="bash $(printf '%q' "$rdir/$base") install --from-deploy --yes"
    cmd+=" --nas $(printf '%q' "$LDAP_HOST")"
    cmd+=" --domain $(printf '%q' "$LDAP_DOMAIN")"
    cmd+=" --allow-groups $(printf '%q' "$ALLOW_GROUPS")"
    cmd+=" --sudo-groups $(printf '%q' "$SUDO_GROUPS")"
    cmd+=" --bind-dn $(printf '%q' "$BIND_DN")"
    cmd+=" --bind-pw-file $(printf '%q' "$rdir/bindpw")"
    cmd+=" --tls-reqcert $(printf '%q' "$TLS_REQCERT")"
    [ "$CACHE_CREDS" = "false" ] && cmd+=" --no-cache-credentials"

    if [ "${T_ROOT[$i]}" -eq 1 ]; then
        r_ssh "$i" "$cmd" || rc=$?
    else
        # first stdin line = sudo password; with NOPASSWD it is simply unread
        r_ssh_in "$i" "sudo -S -p '' $cmd" < "${WORK}/pw.$i" || rc=$?
    fi
    r_ssh "$i" "rm -rf '$rdir'" || warn "${T_HOST[$i]}:無法刪除 $rdir(裡面有 sssd 帳號密碼,請手動刪除!)"
    return "$rc"
}

deploy_tool() {
    parse_opts "$@"
    [ "$FROM_DEPLOY" -eq 0 ] || die "--from-deploy 是內部用參數"
    [ "$(id -u)" -ne 0 ] || warn "在這台電腦執行不需要 root"
    [ -t 0 ] || die "需要互動式終端機"
    command -v ldapsearch >/dev/null || die "這台電腦沒有 ldapsearch:sudo apt install ldap-utils"
    command -v ssh >/dev/null && command -v scp >/dev/null || die "找不到 ssh 或 scp"
    check_ssh_version

    WORK="$(mktemp -d /tmp/sssd-deploy.XXXXXX)"; chmod 700 "$WORK"
    trap deploy_cleanup EXIT
    printf '#!/bin/sh\nexec cat "$DEPLOY_PW_FILE"\n' > "${WORK}/askpass"
    chmod 700 "${WORK}/askpass"

    # 1-3: NAS, lookup/bind account, groups
    ask_nas
    check_nas || die "這台電腦連不到 NAS"
    nas_login
    choose_groups "目標機器"
    fetch_members
    ( umask 077; printf '%s\n' "$BIND_PW" > "${WORK}/bindpw" )
    BIND_PW=""

    # 4: target hosts
    ask_hosts

    # 5: checks
    local i ok=() bad=() results=()
    echo
    for i in "${!T_HOST[@]}"; do
        log "檢查 ${T_SHOW[$i]}"
        if precheck "$i"; then ok+=("$i"); else bad+=("${T_SHOW[$i]}:$REASON"); fi
    done
    echo
    for i in "${ok[@]}"; do
        echo "  通過    ${T_SHOW[$i]}"
        if [ -n "${T_CONFLICT[$i]}" ]; then
            echo "          注意:這台已有同名本機帳號 ${T_CONFLICT[$i]}"
            echo "          本機帳號優先,這些 LDAP 使用者在這台登入時會變成本機帳號,不是 LDAP 帳號"
        fi
    done
    for i in "${bad[@]}"; do echo "  跳過    $i"; done
    [ ${#ok[@]} -gt 0 ] || die "沒有可以設定的機器,沒有修改任何東西"

    local names=()
    for i in "${ok[@]}"; do names+=("${T_SHOW[$i]}"); done
    confirm "${names[*]}"

    # 6: automatic from here
    for i in "${ok[@]}"; do
        echo; log "========== ${T_HOST[$i]} =========="
        if run_on "$i"; then results+=("完成    ${T_HOST[$i]}"); else results+=("失敗    ${T_HOST[$i]}"); fi
    done

    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
    echo "到目標機器上檢查:getent passwd <LDAP 使用者>、id <LDAP 使用者>,再試 ssh <LDAP 使用者>@<機器>"
}

# --- check (on this machine) ---------------------------------------
check_tool() {
    local u="${1:?用法:check <LDAP 使用者>}"
    echo "--- sssd 服務";   systemctl is-active sssd || true
    echo "--- 網域狀態";  sssctl domain-status "$SSSD_DOMAIN" 2>&1 | head -20 || true
    echo "--- getent passwd $u"; getent passwd "$u" || echo "(找不到)"
    echo "--- id $u";           id "$u" 2>&1 || true
    echo "--- 登入限制";  grep -E "^(access_provider|simple_allow_groups|ldap_tls_reqcert|ldap_default_bind_dn)" "$SSSD_CONF" 2>/dev/null || echo "(沒有 $SSSD_CONF)"
    echo "--- sudoers";        cat "$SUDOERS_FILE" 2>/dev/null || echo "(沒有)"
}

main() {
    local cmd="${1:-}"; [ $# -gt 0 ] && shift
    case "$cmd" in
        -h|--help|help)   usage 0 ;;
        ""|deploy)        deploy_tool "$@" ;;
        --*)              deploy_tool "$cmd" "$@" ;;
        install)          require_root install "$@"; install_tool "$@" ;;
        check)            require_root check "$@";   check_tool "$@" ;;
        remove|uninstall) die "移除請用 remove-sssd-ldap.sh" ;;
        *)                usage ;;
    esac
}

# allow `source` for testing the helpers
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

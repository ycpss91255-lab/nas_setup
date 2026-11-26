#!/usr/bin/env bash
# 新節點一次設定完:LDAP 登入 -> 本機帳號改號 -> NAS 資料夾(~/nas-home、~/nas-share)。
# 依序執行同目錄的三支腳本,參數由這裡轉過去:
#   1. install-sssd-ldap.sh     用本機管理員登入(這時還沒有 LDAP)
#   2. fix-local-uid.sh         用有 sudo 的 LDAP 帳號登入(不能用要改號的帳號自己改自己)
#   3. install-nas-folders.sh   用同一個 LDAP 帳號登入
# 密碼在一開始一次問完(查詢帳號、每台的本機管理員、LDAP 帳號),放在只有你能讀
# 的暫存資料夾給三支腳本使用,結束時(含中途失敗)刪除;不寫進命令列、不留在電腦上。
# 每支腳本在自己的確認之前都不會修改機器;加 --yes 則所有確認都自動回答 y。
#
# 執行前在 NAS 網頁先做:把新節點的 IP 加進 homes、share 的 NFS 主機存取
# (之後若改成整個節點網段,這步就不用每台做)。
#
# 用法(在你自己的電腦上執行):
#   bash install-all.sh --nas <NAS_IP> --domain <LDAP_DOMAIN> \
#        --host <LOCAL_ADMIN>@<HOST_IP> --ldap-admin <LDAP_USER>
#
# 參數(沒給的先用腳本最上面「預設值」區塊的值,那裡也空白才會問)
#   --nas IP               NAS 位址(IP 或 ssh 設定名稱)
#   --scan-user NAME       查詢用的 LDAP 帳號,預設 scan_group(不用再問)
#   --domain DOMAIN        LDAP 網域
#   --host [USER@]IP       目標機器與本機管理員,可重複或用逗號 a,b,c
#   --ldap-admin NAME      第 2、3 步用來登入的 LDAP 帳號,不一定要是 NAS 管理員,
#                          只要能登入這些機器並有 sudo(屬於 --sudo-groups 的群組)
#   --allow-groups LIST    可登入的群組(交給 install-sssd-ldap.sh),預設用選單勾選
#   --sudo-groups LIST     可 sudo 的群組(交給 install-sssd-ldap.sh),預設用選單勾選
#   --personal F:P         預設 homes:nas-home(交給 install-nas-folders.sh),可重複
#   --shared F:P           預設 share:nas-share(交給 install-nas-folders.sh),可重複
#   --from N               從第 N 步開始(1-3),例如第 1 步做過了就 --from 2
#   -y, --yes              所有確認都自動回答 y(這支開頭的確認也一樣)
#   -h, --help             顯示這份說明
#
# 範例:
#   bash install-all.sh --nas <NAS_IP> --domain <LDAP_DOMAIN> \
#        --host <LOCAL_ADMIN>@<HOST_IP>,<LOCAL_ADMIN>@<HOST_IP2> --ldap-admin <LDAP_USER> \
#        --allow-groups cluster-admins,cluster-users --sudo-groups cluster-admins
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_NAS=""                    # --nas,例如 192.168.1.10
CFG_SCAN_USER="scan_group"    # --scan-user,查詢帳號
CFG_DOMAIN=""                 # --domain,例如 example.com
CFG_HOSTS=""                  # --host,本機管理員@IP,例如 admin@192.168.1.21,admin@192.168.1.22
CFG_LDAP_ADMIN=""             # --ldap-admin,第 2、3 步登入用、有 sudo 的 LDAP 帳號
CFG_ALLOW_GROUPS=""           # --allow-groups,例如 cluster-admins,cluster-users;空白 = 選單
CFG_SUDO_GROUPS=""            # --sudo-groups,例如 cluster-admins;none = 不給;空白 = 選單
CFG_PERSONAL="homes:nas-home" # --personal,多個用逗號;--personal/--shared 都沒給才用
CFG_SHARED="share:nas-share"  # --shared,多個用逗號
CFG_YES=0                     # 1 = 所有確認自動回答 y(同 -y)
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
DIR="$(dirname "$SELF")"

NAS=""; SCAN_USER=""; DOMAIN=""; LDAP_ADMIN=""
WORK=""
HOSTS=(); PERSONAL=(); SHARED=()
ALLOW_GROUPS=""; SUDO_GROUPS=""; SUDO_SET=0
FROM=1; YES=()

die()  { echo "錯誤:$*" >&2; exit 1; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

[ -t 1 ] && printf '\e[?1004l'
# tmux + fish focus sequences: drain before reading, strip from secrets
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
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT
# put_secret DIR NAME VALUE (600 file)
put_secret() { ( umask 077; mkdir -p "$1"; printf '%s\n' "$3" > "$1/$2" ); }

while [ $# -gt 0 ]; do
    case "$1" in
        --nas)          NAS="${2:?}"; shift 2 ;;
        --scan-user)    SCAN_USER="${2:?}"; shift 2 ;;
        --domain)       DOMAIN="${2:?}"; shift 2 ;;
        --host)         IFS=',' read -ra _h <<< "${2:?}"; HOSTS+=("${_h[@]}"); shift 2 ;;
        --ldap-admin)   LDAP_ADMIN="${2:?}"; shift 2 ;;
        --allow-groups) ALLOW_GROUPS="${2:?}"; shift 2 ;;
        --sudo-groups)  SUDO_GROUPS="${2:-}"; SUDO_SET=1; shift 2 ;;
        --personal)     PERSONAL+=("${2:?}"); shift 2 ;;
        --shared)       SHARED+=("${2:?}"); shift 2 ;;
        --from)         FROM="${2:?}"; shift 2 ;;
        --yes|-y)       YES=(--yes); shift ;;
        -h|--help)      usage 0 ;;
        *)              die "不認得的參數:$1(請看 --help)" ;;
    esac
done

# fill what the options did not give from the CFG_* block
[ -n "$NAS" ]          || NAS="$CFG_NAS"
[ -n "$SCAN_USER" ]    || SCAN_USER="$CFG_SCAN_USER"
[ -n "$DOMAIN" ]       || DOMAIN="$CFG_DOMAIN"
[ -n "$LDAP_ADMIN" ]   || LDAP_ADMIN="$CFG_LDAP_ADMIN"
[ -n "$ALLOW_GROUPS" ] || ALLOW_GROUPS="$CFG_ALLOW_GROUPS"
if [ ${#HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra HOSTS <<< "$CFG_HOSTS"; fi
if [ "$SUDO_SET" -eq 0 ] && [ -n "$CFG_SUDO_GROUPS" ]; then
    SUDO_GROUPS="$CFG_SUDO_GROUPS"; [ "$SUDO_GROUPS" != "none" ] || SUDO_GROUPS=""; SUDO_SET=1
fi
if [ ${#PERSONAL[@]} -eq 0 ] && [ ${#SHARED[@]} -eq 0 ]; then
    [ -z "$CFG_PERSONAL" ] || IFS=',' read -ra PERSONAL <<< "$CFG_PERSONAL"
    [ -z "$CFG_SHARED" ]   || IFS=',' read -ra SHARED   <<< "$CFG_SHARED"
fi
[ "$CFG_YES" != "1" ] || YES=(--yes)

[ -t 0 ] || die "需要互動式終端機(密碼要當下輸入)"
for s in install-sssd-ldap.sh fix-local-uid.sh install-nas-folders.sh; do
    [ -f "$DIR/$s" ] || die "同目錄找不到 $s"
done
[[ "$FROM" =~ ^[1-3]$ ]] || die "--from 只能是 1、2、3"

ask() { local v; read -rp "$1" v; [ -n "$v" ] || die "$2 不能空白"; printf '%s' "$v"; }
[ -n "$NAS" ]        || NAS="$(ask "NAS IP:" "NAS")"
if [ "$FROM" -le 1 ]; then
    [ -n "$DOMAIN" ] || DOMAIN="$(ask "LDAP 網域(例如 example.com):" "LDAP 網域")"
fi
if [ ${#HOSTS[@]} -eq 0 ]; then
    while :; do
        HOSTS+=("$(ask "目標機器 [本機管理員@]IP:" "目標機器")")
        read -rp "還要加其他機器嗎?[y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || break
    done
fi
[ -n "$LDAP_ADMIN" ] || LDAP_ADMIN="$(ask "第 2、3 步登入用的 LDAP 帳號(要有 sudo):" "LDAP 帳號")"
valid_name "$LDAP_ADMIN" || die "LDAP 帳號不正確:$LDAP_ADMIN"
[ ${#PERSONAL[@]} -gt 0 ] || [ ${#SHARED[@]} -gt 0 ] || die "沒有要對應的資料夾(--personal / --shared)"

# same machines with the LDAP admin as SSH user (drop the local admin part)
LDAP_HOSTS=()
for h in "${HOSTS[@]}"; do LDAP_HOSTS+=("${LDAP_ADMIN}@${h##*@}"); done
join() { local IFS=','; echo "$*"; }

cat <<EOF

================ 摘要 ================
 NAS          :${NAS}
 目標機器     :${HOSTS[*]}
 第 1 步      :install-sssd-ldap.sh     用 ${HOSTS[*]} 登入$([ "$FROM" -gt 1 ] && echo "(跳過)")
 第 2 步      :fix-local-uid.sh         用 ${LDAP_ADMIN} 登入$([ "$FROM" -gt 2 ] && echo "(跳過)")
 第 3 步      :install-nas-folders.sh   用 ${LDAP_ADMIN} 登入
 對應         :$(for p in "${PERSONAL[@]}"; do printf '%s(每人一個) ' "$p"; done)$(for p in "${SHARED[@]}"; do printf '%s(大家共用) ' "$p"; done)
 NAS 要先做   :這些機器的 IP 已加進 homes、share 的 NFS 主機存取
======================================
$([ ${#YES[@]} -gt 0 ] && echo "--yes:所有確認自動回答 y" || echo "每支腳本開始前還會各自顯示摘要並確認。")
EOF
if [ ${#YES[@]} -eq 0 ]; then
    read -rp "開始?[y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
fi

# --- all passwords now, once ------------------------------------------------
WORK="$(mktemp -d /tmp/install-all.XXXXXX)"; chmod 700 "$WORK"
S1="$WORK/step1"; S23="$WORK/step23"
printf '\n%s\n' "【密碼】流程共用"
if [ "$FROM" -le 1 ]; then
    read_secret pw "查詢帳號 ${SCAN_USER} 的密碼:"; [ -n "$pw" ] || die "密碼是空的"
    put_secret "$S1" bind "$pw"
    last=""
    for h in "${HOSTS[@]}"; do
        if [ -n "$last" ]; then
            read_secret pw "${h} 的密碼(Enter = 跟上一台一樣):"; pw="${pw:-$last}"
        else
            read_secret pw "${h} 的密碼:"
        fi
        [ -n "$pw" ] || die "密碼是空的"
        put_secret "$S1" "host-${h##*@}" "$pw"; last="$pw"
    done
fi
read_secret pw "LDAP 帳號 ${LDAP_ADMIN} 的密碼:"; [ -n "$pw" ] || die "密碼是空的"
for h in "${HOSTS[@]}"; do put_secret "$S23" "host-${h##*@}" "$pw"; done
pw=""; last=""

if [ "$FROM" -le 1 ]; then
    echo; log "【第 1 步】LDAP 登入(install-sssd-ldap.sh)"
    args=(--nas "${SCAN_USER:+${SCAN_USER}@}${NAS}" --domain "$DOMAIN" --host "$(join "${HOSTS[@]}")")
    [ -z "$ALLOW_GROUPS" ] || args+=(--allow-groups "$ALLOW_GROUPS")
    [ "$SUDO_SET" -eq 0 ] || args+=(--sudo-groups "$SUDO_GROUPS")
    INSTALL_ALL_SECRETS="$S1" bash "$DIR/install-sssd-ldap.sh" "${args[@]}" "${YES[@]}" || die "第 1 步失敗,停止。修好後用 --from 1 重跑"
fi

if [ "$FROM" -le 2 ]; then
    echo; log "【第 2 步】本機帳號改號(fix-local-uid.sh),用 ${LDAP_ADMIN} 登入"
    # a failed check is not fatal here: step 3 checks the same conflicts again
    INSTALL_ALL_SECRETS="$S23" bash "$DIR/fix-local-uid.sh" --host "$(join "${LDAP_HOSTS[@]}")" "${YES[@]}" \
        || log "第 2 步有機器沒通過檢查,第 3 步會再檢查一次"
fi

echo; log "【第 3 步】NAS 資料夾(install-nas-folders.sh),用 ${LDAP_ADMIN} 登入"
args=(--nas "$NAS" --host "$(join "${LDAP_HOSTS[@]}")")
for p in "${PERSONAL[@]}"; do args+=(--personal "$p"); done
for p in "${SHARED[@]}";   do args+=(--shared "$p"); done
INSTALL_ALL_SECRETS="$S23" bash "$DIR/install-nas-folders.sh" "${args[@]}" "${YES[@]}" || die "第 3 步失敗。修好後用 --from 3 重跑"

echo; log "全部完成。"

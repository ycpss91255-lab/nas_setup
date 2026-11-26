#!/usr/bin/env bash
# 幫新建的 LDAP 帳號在 NAS 上建立家目錄(homes/<帳號>),讓它不用先登入 NAS 網頁,
# 第一次登入節點就有 ~/nas-home。
# NAS 只在帳號第一次登入 NAS 時建立家目錄,節點沒有權限代建;這支用該帳號的密碼
# 透過 NAS 網頁的登入 API 登入一次、確認家目錄、再登出。不改任何 NAS 設定。
#
# 用法(在你自己的電腦上執行;在 NAS 網頁建好 LDAP 帳號之後):
#   bash init-nas-home.sh --nas <NAS_IP> --user <帳號>
#
# 參數
#   --nas IP          NAS 位址,可用 ssh 設定名稱(只取 HostName)
#   --user NAME       LDAP 帳號,可重複或用逗號 a,b,c
#   -h, --help        顯示這份說明
# 密碼一律執行時輸入(建立帳號時設定的初始密碼),只在記憶體與 600 暫存檔中,結束時刪除。
# NAS 的憑證是自簽的,連線有加密但不驗證憑證(同 install-sssd-ldap.sh 的 allow)。
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_NAS=""            # --nas,例如 192.168.1.10
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
NAS=""; USERS=(); WORK=""

die()  { echo "錯誤:$*" >&2; exit 1; }
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

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
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --nas)     NAS="${2:?}"; shift 2 ;;
        --user)    IFS=',' read -ra _u <<< "${2:?}"; USERS+=("${_u[@]}"); shift 2 ;;
        -h|--help) usage 0 ;;
        *)         die "不認得的參數:$1(請看 --help)" ;;
    esac
done

command -v curl >/dev/null || die "找不到 curl"
command -v base64 >/dev/null || die "找不到 base64"
[ -t 0 ] || die "需要互動式終端機(密碼要當下輸入)"
[ -n "$NAS" ] || NAS="$CFG_NAS"
[ -n "$NAS" ] || { read -rp "NAS IP:" NAS; [ -n "$NAS" ] || die "NAS 不能空白"; }
[[ "$NAS" =~ ^[A-Za-z0-9._-]+$ ]] || die "NAS 位址不正確:$NAS"
r="$(ssh -G "$NAS" 2>/dev/null | awk '$1=="hostname"{print $2; exit}' || true)"
[ -z "$r" ] || [ "$r" = "$NAS" ] || { log "NAS ${NAS} -> ${r}(來自 ssh 設定)"; NAS="$r"; }
if [ ${#USERS[@]} -eq 0 ]; then
    read -rp "LDAP 帳號(多個用逗號):" a; IFS=',' read -ra USERS <<< "$a"
fi
[ ${#USERS[@]} -gt 0 ] || die "沒有帳號"

BASE="https://${NAS}"
WORK="$(mktemp -d /tmp/init-nas-home.XXXXXX)"; chmod 700 "$WORK"

# xml_field XML NAME -> value of <NAME><![CDATA[...]]></NAME>
xml_field() { sed -n "s/.*<$2><!\[CDATA\[\([^]]*\)\]\]><\/$2>.*/\1/p" <<< "$1" | head -n1; }
# api PATH-and-query -> JSON/XML (sid already in the query)
api() { curl -sk --max-time 20 "${BASE}$1"; }

ok=(); bad=()
for u in "${USERS[@]}"; do
    u="$(echo "$u" | xargs)"
    valid_name "$u" || { bad+=("$u:名稱不正確"); continue; }
    echo
    read_secret pw "${u} 的密碼:"
    [ -n "$pw" ] || { bad+=("$u:密碼是空的"); continue; }
    ( umask 077; printf 'user=%s&pwd=%s&remme=0' "$u" "$(printf '%s' "$pw" | base64 -w0)" > "$WORK/body" )
    pw=""
    resp="$(curl -sk --max-time 20 --data @"$WORK/body" "${BASE}/cgi-bin/authLogin.cgi" || true)"
    rm -f "$WORK/body"
    [ -n "$resp" ] || { bad+=("$u:連不到 ${BASE}"); continue; }
    if [ "$(xml_field "$resp" authPassed)" != "1" ]; then
        bad+=("$u:登入 NAS 失敗(密碼錯誤、帳號停用,或帳號不存在)"); continue
    fi
    sid="$(xml_field "$resp" authSid)"
    [ "$(xml_field "$resp" isAdmin)" = "1" ] && warn "$u 是 NAS 管理員"
    # what the web desktop does after login; the NAS creates homes/<user> here
    api "/cgi-bin/filemanager/utilRequest.cgi?func=get_tree&sid=${sid}&is_iso=0&node=share_root" >/dev/null || true
    sleep 2
    home="$(api "/cgi-bin/filemanager/utilRequest.cgi?func=get_list&sid=${sid}&path=/home&limit=1&start=0&sort=filename&dir=ASC&list_mode=all" || true)"
    api "/cgi-bin/authLogin.cgi?logout=1&sid=${sid}" >/dev/null || true
    if grep -q '"datas"' <<< "$home"; then
        log "$u:NAS 家目錄已就緒"; ok+=("$u")
    else
        bad+=("$u:登入成功,但家目錄還沒出現(檢查控制台 → 使用者 → 進階設定 → 使用者家目錄 是否啟用)")
    fi
done

echo; log "結果"
for u in "${ok[@]}";  do echo "  完成    $u"; done
for x in "${bad[@]}"; do echo "  失敗    $x"; done
[ ${#bad[@]} -eq 0 ]

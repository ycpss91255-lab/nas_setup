#!/usr/bin/env bash
# 把目標機器上和 NAS 本機帳號編號重疊的本機帳號改號,讓 NFS 不會認錯人。
# NFS(sec=sys)只看編號:NAS 本機帳號用 uid 1000 起、群組 100 是 everyone;
# Ubuntu 第一個帳號也是 uid 1000,而且會加入群組 100(users)。
# 在 install-nas-folders.sh 之前執行;那支腳本遇到撞號會停下來。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash fix-local-uid.sh
#
#   1. 目標機器 [SSH_USER@]IP(SSH_USER 可省略,省略就用 ssh 設定;
#      IP 也可以寫 ~/.ssh/config 的名稱),再輸入密碼,可以連續加多台
#      SSH_USER 必須是「不需要改號」的帳號,例如有 sudo 的 LDAP 帳號;
#      要改號的帳號在改的時候不能登入中
#   2. 逐台列出要改的帳號與新編號,輸入 y 後全部自動完成
# 第 2 步確認之前,任何機器都不會被修改。
#
# 在目標機器上直接執行:
#   sudo bash fix-local-uid.sh here    # 改這一台
#   bash fix-local-uid.sh check        # 唯讀,只列出撞號的帳號
#
# 每個要改的帳號會:
#   - 結束它所有的登入與程式(先 TERM,再 KILL)
#   - usermod -u <新編號>(家目錄裡的檔案會一起改)
#   - 全機本地磁碟上其他屬於舊編號的檔案改成新編號
#   - linger 設定保留
# 群組 100(users)的所有成員都會被移出這個群組;主要群組(id -g)是 100 或 0
# 的帳號,主要群組改成自己的同名群組(沒有就建立)。
# 帳號名稱、密碼、sudo 等其他設定都不變。
# 之後新增的本機帳號也從新編號開始、不加入群組 100:
#   /etc/login.defs   UID_MIN、GID_MIN(useradd 用)
#   /etc/adduser.conf FIRST_UID、FIRST_GID、USERS_GID=-1(adduser 用)
#   原檔第一次修改前備份成 <檔名>.bak-fix-local-uid;已經設好就不動。
#
# 參數
#   --host [SSH_USER@]IP   目標機器,可重複或用逗號 a,b,c。預設執行時詢問
#   --uid N                第一個新編號,預設 5000;要改多個帳號時依序找下一個沒用過的
#   --yes                  跳過最後的確認
#   -h, --help             顯示這份說明
#
# 範例:
#   bash fix-local-uid.sh --host <LDAP_USER>@<HOST_IP>
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_HOSTS=""          # --host,例如 ldapuser@192.168.1.21,ldapuser@192.168.1.22
CFG_UID=5000          # --uid,改號從這個編號開始
CFG_YES=0             # 1 = 所有確認自動回答 y
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

CONFLICT_MIN=1000        # NAS local accounts start here
CONFLICT_MAX=4999
NEW_UID_START="$CFG_UID"
NAS_GID=100              # NAS "everyone" == Ubuntu "users"

ASSUME_YES=0
ARG_HOSTS=()
WORK=""
T_HOST=(); T_USER=(); T_SHOW=(); T_ROOT=(); T_PLAN=()
SO=()
REASON=""

die()  { echo "錯誤:$*" >&2; exit 1; }
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }

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
# preset_secret NAME VAR: password prepared by install-all.sh (600 file in a
# 700 temp dir it deletes at exit); 1 = none, ask as usual
preset_secret() {
    local f="${INSTALL_ALL_SECRETS:-}/$1"
    [ -n "${INSTALL_ALL_SECRETS:-}" ] && [ -r "$f" ] || return 1
    printf -v "$2" '%s' "$(head -n1 "$f")"
}
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# --- on THIS machine --------------------------------------------------------
# conflicting local accounts: "name uid" per line (only /etc/passwd)
conflict_users() {
    awk -F: -v a="$CONFLICT_MIN" -v b="$CONFLICT_MAX" '$3>=a && $3<=b {print $1, $3}' /etc/passwd
}
# members of group 100 (comma list from /etc/group)
gid100_members() { awk -F: -v g="$NAS_GID" '$3==g {print $4}' /etc/group; }
# human accounts whose PRIMARY group (id -g, /etc/passwd) is 100 or 0: "name gid"
primary_gid_users() {
    awk -F: -v g="$NAS_GID" '$3>=1000 && $3<60000 && ($4==g || $4==0) {print $1, $4}' /etc/passwd
}

# newuser_missing MIN: settings that still let NEW local accounts get a uid/gid
# below MIN or join group 100 (one per line; empty = fine). Also sent to hosts
# with declare -f, so keep it self-contained.
newuser_missing() {
    local min="$1"
    awk -v m="$min" '$1=="UID_MIN"{u=$2+0} $1=="GID_MIN"{g=$2+0}
        END{if(u<m)print "login.defs UID_MIN"; if(g<m)print "login.defs GID_MIN"}' /etc/login.defs 2>/dev/null
    [ -f /etc/adduser.conf ] || return 0
    awk -F= -v m="$min" '/^[ \t]*FIRST_UID=/{u=$2+0} /^[ \t]*FIRST_GID=/{g=$2+0} /^[ \t]*USERS_GID=/{x=$2}
        END{if(u<m)print "adduser.conf FIRST_UID"; if(g<m)print "adduser.conf FIRST_GID"; if(x!="-1")print "adduser.conf USERS_GID"}' /etc/adduser.conf
}

# backup_once FILE: keep the original from before this script ever changed it
backup_once() { [ -e "$1.bak-fix-local-uid" ] || cp -a "$1" "$1.bak-fix-local-uid"; }

# fix_newuser_defaults: new local accounts start at NEW_UID_START, no group 100
fix_newuser_defaults() {
    local miss k f="/etc/login.defs" a="/etc/adduser.conf"
    miss="$(newuser_missing "$NEW_UID_START")"
    [ -n "$miss" ] || return 0
    grep -q '^login.defs' <<< "$miss" && backup_once "$f"
    grep -q '^adduser.conf' <<< "$miss" && backup_once "$a"
    while read -r _ k; do
        case "$k" in
            UID_MIN|GID_MIN)
                if grep -qE "^[[:space:]]*${k}[[:space:]]" "$f"; then
                    sed -i -E "s/^[[:space:]]*${k}[[:space:]].*/${k}\t\t\t${NEW_UID_START}/" "$f"
                else echo "${k} ${NEW_UID_START}" >> "$f"; fi ;;
            FIRST_UID|FIRST_GID|USERS_GID)
                local v="$NEW_UID_START"; [ "$k" = USERS_GID ] && v=-1
                if grep -qE "^[[:space:]]*${k}=" "$a"; then
                    sed -i -E "s/^[[:space:]]*${k}=.*/${k}=${v}/" "$a"
                elif grep -qE "^#[[:space:]]*${k}=" "$a"; then
                    sed -i -E "0,/^#[[:space:]]*${k}=/s//${k}=/; s/^${k}=.*/${k}=${v}/" "$a"
                else echo "${k}=${v}" >> "$a"; fi
                # USERS_GID and USERS_GROUP together is a configuration error
                [ "$k" = USERS_GID ] && sed -i -E 's/^([[:space:]]*USERS_GROUP=)/#\1/' "$a" ;;
        esac
    done <<< "$miss"
    log "$(hostname):之後新增的本機帳號從 ${NEW_UID_START} 開始、不加入群組 ${NAS_GID}"
}

# next unused uid >= $1 (also skips numbers in use as a group, to keep it clean)
next_free_uid() {
    local n="$1"
    while getent passwd "$n" >/dev/null || getent group "$n" >/dev/null; do n=$((n+1)); done
    echo "$n"
}

check_tool() {
    local c m p
    local n; n="$(newuser_missing "$NEW_UID_START")"
    c="$(conflict_users)"; m="$(gid100_members)"; p="$(primary_gid_users)"
    [ -z "$n" ] || { echo "新帳號的編號設定還沒改:"; echo "$n" | sed 's/^/    /'; }
    if [ -z "$c$m$p" ]; then log "$(hostname):沒有撞號的本機帳號"; return 0; fi
    [ -z "$c" ] || { echo "uid ${CONFLICT_MIN}–${CONFLICT_MAX} 的本機帳號:"; echo "$c" | sed 's/^/    /'; }
    [ -z "$m" ] || echo "群組 ${NAS_GID} 的成員:$m"
    [ -z "$p" ] || { echo "主要群組(id -g)是 ${NAS_GID} 或 0 的帳號:"; echo "$p" | sed 's/^/    /'; }
    return 0
}

# fix_primary_gid USER: primary group -> a group of its own (same name; created
# if missing). usermod -g also moves the home files of the old primary group.
fix_primary_gid() {
    local u="$1" g gid
    if getent group "$u" >/dev/null; then
        g="$u"; gid="$(getent group "$u" | cut -d: -f3)"
        [ "$gid" != "$NAS_GID" ] && [ "$gid" != 0 ] || die "$u 的同名群組編號是 $gid,請手動處理"
    else
        gid="$(id -u "$u")"
        getent group "$gid" >/dev/null && gid="$(next_free_uid "$NEW_UID_START")"
        groupadd -g "$gid" "$u"; g="$u"
        log "$u:建立群組 $g($gid)"
    fi
    usermod -g "$g" "$u"
    log "$u:主要群組改成 $g($gid)"
}

# writable local filesystems (no network / virtual / read-only mounts)
local_mounts() {
    findmnt -rn -o TARGET,FSTYPE,OPTIONS | awk '$3 !~ /^ro(,|$)/ && $2 !~ /^(nfs|nfs4|cifs|smb3|fuse\..*|autofs|proc|sysfs|devtmpfs|devpts|tmpfs|cgroup2?|securityfs|pstore|bpf|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|efivarfs|binfmt_misc|overlay|squashfs|nsfs|ramfs|rpc_pipefs)$/ {print $1}' | sort -u
}

fix_user() {
    local u="$1" old="$2" new="$3" linger=0 i m n bad f
    log "$u:uid $old -> $new"
    [ -e "/var/lib/systemd/linger/$u" ] && linger=1
    [ "$linger" -eq 0 ] || loginctl disable-linger "$u" 2>/dev/null || true
    loginctl terminate-user "$u" 2>/dev/null || true
    for i in 1 2 3 4 5; do pgrep -u "$old" >/dev/null || break; sleep 1; done
    if pgrep -u "$old" >/dev/null; then
        pkill -TERM -u "$old" || true; sleep 2
        pkill -KILL -u "$old" || true; sleep 1
    fi
    pgrep -u "$old" >/dev/null && die "$u 還有程式在執行,沒有改號"
    usermod -u "$new" "$u"
    n=0; bad=0
    while IFS= read -r m; do
        while IFS= read -r -d '' f; do
            if chown -h "$new" "$f" 2>/dev/null; then n=$((n+1)); else bad=$((bad+1)); warn "改不了擁有者:$f"; fi
        done < <(find "$m" -xdev -uid "$old" -print0 2>/dev/null)
    done < <(local_mounts)
    [ "$n" -eq 0 ] || log "$u:家目錄以外另外改了 $n 個檔案的擁有者"
    [ "$bad" -eq 0 ] || warn "$u:有 $bad 個檔案改不了,請手動檢查(find / -uid $old)"
    [ "$linger" -eq 0 ] || loginctl enable-linger "$u" 2>/dev/null || true
}

here_tool() {
    [ "$(id -u)" -eq 0 ] || die "需要 root:sudo bash $SELF here"
    local me="${SUDO_USER:-}" u uid new next="$NEW_UID_START" members x
    local plan=()
    while read -r u uid; do
        [ -n "$u" ] || continue
        [ "$u" = "$me" ] && die "$u 就是現在執行這支腳本的帳號,不能替自己改號。請用另一個有 sudo 的帳號(例如有 sudo 的 LDAP 帳號)執行"
        who | awk '{print $1}' | grep -qx "$u" && warn "$u 目前有登入,會被強制登出"
        new="$(next_free_uid "$next")"; next=$((new+1))
        plan+=("$u $uid $new")
    done < <(conflict_users)
    members="$(gid100_members)"
    local pgu; pgu="$(primary_gid_users)"
    if [ ${#plan[@]} -eq 0 ] && [ -z "$members" ] && [ -z "$pgu" ]; then
        if [ -z "$(newuser_missing "$NEW_UID_START")" ]; then log "$(hostname):沒有撞號的本機帳號,不需要修改"; return 0; fi
        fix_newuser_defaults; return 0
    fi

    for x in "${plan[@]}"; do
        # shellcheck disable=SC2086
        fix_user $x
    done
    if [ -n "$members" ]; then
        IFS=',' read -ra _m <<< "$members"
        for u in "${_m[@]}"; do [ -n "$u" ] && gpasswd -d "$u" "$(getent group "$NAS_GID" | cut -d: -f1)" >/dev/null && log "$u:移出群組 ${NAS_GID}"; done
    fi
    # after the uid changes: primary group 100 / 0
    while read -r u _; do [ -n "$u" ] && fix_primary_gid "$u"; done < <(primary_gid_users)
    fix_newuser_defaults
    log "結果:"; check_tool
    for x in "${plan[@]}"; do id "${x%% *}"; done
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
    T_HOST+=("$h"); T_USER+=("$u"); T_SHOW+=("${ru}@${rh}"); T_ROOT+=(0); T_PLAN+=("")
    ( umask 077; printf '%s\n' "$pw" > "${WORK}/pw.$i" )
}

ask_hosts() {
    local h more rc
    printf '\n%s\n' "【目標機器】用不需要改號的帳號登入(要有 sudo),例如有 sudo 的 LDAP 帳號"
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
    local i="$1" me c m p n x
    REASON=""
    r_open "$i" || { REASON="SSH 密碼登入失敗"; return 1; }
    me="$(r_ssh "$i" 'id -un' 2>/dev/null)"
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${me} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    c="$(r_ssh "$i" "awk -F: '\$3>=${CONFLICT_MIN} && \$3<=${CONFLICT_MAX} {print \$1 \"(\" \$3 \")\"}' /etc/passwd" 2>/dev/null | tr '\n' ' ')"
    m="$(r_ssh "$i" "awk -F: '\$3==${NAS_GID} {print \$4}' /etc/group" 2>/dev/null)"
    p="$(r_ssh "$i" "awk -F: '\$3>=1000 && \$3<60000 && (\$4==${NAS_GID} || \$4==0) {print \$1}' /etc/passwd" 2>/dev/null | tr '\n' ' ')"
    n="$(r_ssh "$i" "$(declare -f newuser_missing); newuser_missing ${NEW_UID_START}" 2>/dev/null | tr '\n' ' ')"
    [ -n "$c$m$p$n" ] || { REASON="沒有撞號的本機帳號,不需要修改"; return 2; }
    for x in $c; do
        [ "${x%%(*}" = "$me" ] && { REASON="登入用的 ${me} 自己就要改號;請改用另一個有 sudo 的帳號"; return 1; }
    done
    T_PLAN[i]="改號:${c:-無}  移出群組 ${NAS_GID}:${m:-無}  主要群組改掉:${p:-無}  新帳號設定:$([ -n "$n" ] && echo 要改 || echo 已設好)"
}

run_on() {
    local i="$1" rdir rc=0 cmd
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/fix-uid.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }
    cmd="bash $(printf '%q' "$rdir/$(basename "$SELF")") here --uid ${NEW_UID_START}"
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
    command -v ssh >/dev/null || die "找不到 ssh"
    command -v scp >/dev/null || die "找不到 scp"
    check_ssh_version
    WORK="$(mktemp -d /tmp/fix-uid.XXXXXX)"; chmod 700 "$WORK"
    trap cleanup EXIT
    printf '#!/bin/sh\nexec cat "$PW_FILE"\n' > "${WORK}/askpass"
    chmod 700 "${WORK}/askpass"

    ask_hosts

    local i rc ok=() bad=() fine=() results=() names=()
    echo
    for i in "${!T_HOST[@]}"; do
        log "檢查 ${T_SHOW[$i]}"
        rc=0; precheck "$i" || rc=$?
        case "$rc" in
            0) ok+=("$i") ;;
            2) fine+=("${T_SHOW[$i]}") ;;
            *) bad+=("${T_SHOW[$i]}:$REASON") ;;
        esac
    done
    echo
    for i in "${ok[@]}";   do echo "  通過    ${T_SHOW[$i]}  ${T_PLAN[$i]}"; done
    for i in "${fine[@]}"; do echo "  不用改  $i(沒有撞號的本機帳號)"; done
    for i in "${bad[@]}";  do echo "  跳過    $i"; done
    if [ ${#ok[@]} -eq 0 ]; then
        [ ${#bad[@]} -eq 0 ] && { log "都不需要改號"; exit 0; }
        die "沒有可以修改的機器,沒有修改任何東西"
    fi

    for i in "${ok[@]}"; do names+=("${T_SHOW[$i]}"); done
    cat <<EOF

================ 摘要 ================
 目標機器 :${names[*]}
 新編號   :從 ${NEW_UID_START} 起找沒用過的
 會做     :強制登出要改號的帳號、usermod -u、本地磁碟上舊編號的檔案改擁有者、
           群組 ${NAS_GID} 的成員移出該群組;
           之後新增的本機帳號從 ${NEW_UID_START} 開始、不加入群組 ${NAS_GID}
           (/etc/login.defs、/etc/adduser.conf,原檔備份 .bak-fix-local-uid)
 不會動   :帳號名稱、密碼、sudo 權限
======================================
EOF
    if [ "$ASSUME_YES" -eq 0 ]; then
        local a; read -rp "確定修改?[y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
    fi

    for i in "${ok[@]}"; do
        echo; log "========== ${T_SHOW[$i]} =========="
        if run_on "$i"; then results+=("完成    ${T_SHOW[$i]}"); else results+=("失敗    ${T_SHOW[$i]}"); fi
    done
    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
    echo "改號的帳號請重新登入確認。"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        -h|--help|help) usage 0 ;;
        check)          check_tool; return ;;
        here)           shift ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)  IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --uid)   NEW_UID_START="${2:?}"; shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    if [ "$cmd" != "here" ]; then
        if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
        [ "$CFG_YES" != "1" ] || ASSUME_YES=1
    fi
    [[ "$NEW_UID_START" =~ ^[0-9]+$ ]] && [ "$NEW_UID_START" -gt "$CONFLICT_MAX" ] && [ "$NEW_UID_START" -lt 60000 ] \
        || die "--uid 要介於 $((CONFLICT_MAX+1)) 和 59999 之間"
    if [ "$cmd" = "here" ]; then here_tool; else remote_main; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

#!/usr/bin/env bash
# 讓 LDAP 使用者登入目標機器後,家目錄裡直接有 NAS 上的資料夾(NFS 即時存取,不是同步)。
# 先用 install-sssd-ldap.sh 設好 LDAP 登入,再執行這支。每台機器只要執行一次。
#
# 主要用法:在你自己的電腦上執行,不帶參數,依序回答問題。
#   bash install-nas-folders.sh
#
#   1. NAS IP(也可以寫 ~/.ssh/config 的名稱)
#   2. 要對應的資料夾:<NAS 資料夾>:<家目錄內路徑>,先問每人一個的(例如 homes:nas-home),
#      再問大家共用的(例如 share:nas-share);不要的直接按 Enter
#   3. 目標機器 [SSH_USER@]IP(SSH_USER 可省略,省略就用 ssh 設定;
#      IP 也可以寫 ~/.ssh/config 的名稱),再輸入密碼,可以連續加多台
#   4. 逐台檢查(SSH、sudo、該機連得到 NAS:2049),顯示摘要,
#      輸入 y 後全部自動完成
# 第 4 步確認之前,任何機器都不會被修改。
#
# 對應方式
#   --personal homes:nas-home
#     NAS 的 homes 掛在 /mnt/nas/homes(開機後第一次存取時自動掛載),
#     ~/nas-home 就是使用者在 NAS 網頁上看到的 home。LDAP 使用者每次登入時:
#       - NAS 上沒有 homes/<使用者> 就試著用該使用者的身分建立;NAS 的 homes 不讓
#         一般使用者建立,要先跑 init-nas-home.sh(或登入一次 NAS 網頁)讓 NAS 建立
#       - 建立連結 ~/nas-home -> /mnt/nas/homes/<使用者>
#     家目錄內路徑可以多層(例如 work/nas);已經有同名檔案或資料夾就不動它。
#     已經建好連結的人登入時不碰 NAS;NAS 連不上就跳過,下次登入再建。
#   --shared share:nas-share
#     NAS 的 share 掛在 /mnt/nas/share,所有 LDAP 使用者共用同一個資料夾。
#     LDAP 使用者每次登入時建立連結 ~/nas-share -> /mnt/nas/share(不用碰 NAS)。
#     誰能讀寫由 NAS 的權限決定(例如只給 Domain Users)。
#   兩種都只處理 LDAP 帳號(經由 sssd 取得、不在 /etc/passwd 裡的帳號);本機帳號不受影響。
#
# NAS 端要先做(網頁設定):建立共用資料夾、NFS 主機存取開放這些機器;
# --personal 的資料夾要讓使用者能在頂層建立自己的子資料夾,
# --shared 的資料夾要給 LDAP 使用者讀寫。
#
# 再執行一次:可以加新的資料夾(原本的保留),或用 --nas 換 NAS 位址。
# NAS 只改允許的 IP 時,機器不用重跑。移除請用 remove-nas-folders.sh。
#
# 在單一機器上直接執行:
#   bash install-nas-folders.sh install [參數]   # 同樣的問題,只設定這一台
#   bash install-nas-folders.sh check   [使用者] # 唯讀檢查狀態
#
# 參數(每個參數會跳過對應的問題)
# 沒給的參數先用腳本最上面「預設值」區塊的值,那裡也空白才會問。
#   --nas IP                       NAS 位址,可用 ssh 設定名稱(只取 HostName)
#   --personal NAS資料夾:家目錄內路徑 每人一個子資料夾,可重複
#   --shared   NAS資料夾:家目錄內路徑 大家共用一個資料夾,可重複
#   --host [SSH_USER@]IP           目標機器,可重複或用逗號 a,b,c。IP 可用 ssh 設定名稱,
#                                  沒寫 SSH_USER 時用 ssh 設定的 User(再沒有就是你的使用者名稱)
#   --yes                          跳過最後的確認
#   -h, --help                     顯示這份說明
#
# 範例:
#   bash install-nas-folders.sh --nas <NAS_IP> --personal homes:nas-home \
#        --shared share:nas-share --host <SSH_USER>@<HOST_IP>
set -euo pipefail

# ===== 預設值(可以直接改)=================================================
# 命令列有給的參數優先;沒給就用這裡的值;這裡也空白才會互動詢問。
CFG_NAS=""                    # --nas,例如 192.168.1.10
CFG_PERSONAL="homes:nas-home" # --personal,多個用逗號;--personal/--shared 都沒給才用
CFG_SHARED="share:nas-share"  # --shared,多個用逗號
CFG_HOSTS=""                  # --host,例如 ldapuser@192.168.1.21,ldapuser@192.168.1.22
CFG_YES=0                     # 1 = 所有確認自動回答 y
# =========================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

NAS_ARG=""
NAS_HOST=""
ARG_PERSONAL=()          # --personal FOLDER:REL as given
ARG_SHARED=()            # --shared FOLDER:REL as given
P_KIND=()                # parsed mappings: personal|shared
P_FOLDER=()
P_REL=()
RETIRED=()               # old paths inside home that a new mapping replaced
ARG_HOSTS=()
ASSUME_YES=0
FROM_DEPLOY=0
NFS_PORT="2049"

MNT_BASE="/mnt/nas"
# NFS (sec=sys) trusts numeric ids. NAS local accounts use uid 1000 and up and
# group 100 ("everyone" on the NAS, "users" on Ubuntu; also 0): local accounts
# on the machine must stay out of both, as member or as primary group (id -g).
LOCAL_UID_MIN=1000
LOCAL_UID_SAFE=5000
# prints one line per local account that collides with NAS ids
CONFLICT_SH="awk -F: '\$3>=${LOCAL_UID_MIN} && \$3<${LOCAL_UID_SAFE} {print \"uid \" \$3 \":\" \$1}' /etc/passwd; awk -F: '\$3==100 && \$4!=\"\" {print \"群組 100(\" \$1 \"):\" \$4}' /etc/group; awk -F: '\$3>=1000 && \$3<60000 && (\$4==100 || \$4==0) {print \"主要群組 \" \$4 \":\" \$1}' /etc/passwd"

CONF="/etc/nas-folders.conf"
HOOK="/usr/local/sbin/nas-folders-login"
PAM_PROFILE="/usr/share/pam-configs/nas-folders"
FSTAB="/etc/fstab"
FSTAB_BEGIN="# BEGIN nas-folders (managed by install-nas-folders.sh)"
FSTAB_END="# END nas-folders"
MNT_OPTS="vers=4.1,hard,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=15"
STAMP="$(date +%Y%m%d-%H%M%S)"

# deploy state (PC side)
WORK=""
T_HOST=(); T_USER=(); T_SHOW=(); T_ROOT=()
SO=()
REASON=""

die()  { echo "錯誤:$*" >&2; exit 1; }
warn() { echo "警告:$*" >&2; }
log()  { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed -E 's/^# ?//'; exit "${1:-1}"; }

APT_LOG="/var/log/install-nas-folders-apt.log"
apt_q() {
    if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
         apt-get -y -q "$@" </dev/null >>"$APT_LOG" 2>&1; then
        tail -n 20 "$APT_LOG" >&2
        die "apt-get $* 失敗,完整記錄在 $APT_LOG"
    fi
}

# tmux (focus-events on) + fish: focus-in/out sequences (ESC[I / ESC[O) can
# leak into reads. Turn focus reporting off, drain pending input before a
# read and strip those sequences from secrets.
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

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != "." ] && [ "$1" != ".." ]; }

# valid_rel PATH: relative path inside home, no "." or ".." parts
valid_rel() {
    local p="$1" part
    [[ "$p" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || return 1
    IFS='/' read -ra _parts <<< "$p"
    for part in "${_parts[@]}"; do valid_name "$part" || return 1; done
}

ssh_resolve() {
    command -v ssh >/dev/null || return 1
    ssh -G "$1" 2>/dev/null | awk -v f="$2" '$1==f {print $2; exit}'
}

parse_opts() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --nas)         NAS_ARG="${2:?}"; shift 2 ;;
            --personal)    ARG_PERSONAL+=("${2:?}"); shift 2 ;;
            --shared)      ARG_SHARED+=("${2:?}"); shift 2 ;;
            --host)        IFS=',' read -ra _h <<< "${2:?}"; ARG_HOSTS+=("${_h[@]}"); shift 2 ;;
            --yes|-y)      ASSUME_YES=1; shift ;;
            --from-deploy) FROM_DEPLOY=1; shift ;;   # internal
            *)             die "不認得的參數:$1(請看 --help)" ;;
        esac
    done
    [ "$FROM_DEPLOY" -eq 1 ] || apply_defaults
}

# apply_defaults: fill what the options did not give from the CFG_* block
apply_defaults() {
    [ -n "$NAS_ARG" ] || NAS_ARG="$CFG_NAS"
    if [ ${#ARG_PERSONAL[@]} -eq 0 ] && [ ${#ARG_SHARED[@]} -eq 0 ]; then
        [ -z "$CFG_PERSONAL" ] || IFS=',' read -ra ARG_PERSONAL <<< "$CFG_PERSONAL"
        [ -z "$CFG_SHARED" ]   || IFS=',' read -ra ARG_SHARED   <<< "$CFG_SHARED"
    fi
    if [ ${#ARG_HOSTS[@]} -eq 0 ] && [ -n "$CFG_HOSTS" ]; then IFS=',' read -ra ARG_HOSTS <<< "$CFG_HOSTS"; fi
    [ "$CFG_YES" != "1" ] || ASSUME_YES=1
}

# set_nas ADDR: ssh config name -> HostName
set_nas() {
    local addr r
    addr="$(echo "$1" | xargs)"
    [[ "$addr" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "NAS 位址不正確:$addr"; return 1; }
    r="$(ssh_resolve "$addr" hostname || true)"
    NAS_HOST="${r:-$addr}"
    [ "$NAS_HOST" = "$addr" ] || log "NAS ${addr} -> ${NAS_HOST}(來自 ssh 設定)"
}

# add_mapping KIND "FOLDER:REL"
add_mapping() {
    local kind="$1" arg f r i
    arg="$(echo "$2" | xargs)"
    [[ "$arg" == *:* ]] || { warn "格式是 <NAS 資料夾>:<家目錄內路徑>:$arg"; return 1; }
    f="${arg%%:*}"; r="${arg#*:}"; r="${r%/}"
    valid_name "$f" || { warn "NAS 資料夾名稱不正確:$f"; return 1; }
    valid_rel "$r"  || { warn "家目錄內路徑不正確:$r(例如 data 或 work/nas)"; return 1; }
    for i in "${!P_FOLDER[@]}"; do
        [ "${P_FOLDER[$i]}" = "$f" ] && { warn "NAS 資料夾 $f 重複"; return 1; }
        [ "${P_REL[$i]}" = "$r" ]    && { warn "家目錄內路徑 $r 重複"; return 1; }
    done
    P_KIND+=("$kind"); P_FOLDER+=("$f"); P_REL+=("$r")
}

ask_settings() {
    local a p
    if [ -n "$NAS_ARG" ]; then
        set_nas "$NAS_ARG" || die "--nas 不正確:$NAS_ARG"
    else
        [ -t 0 ] || die "需要 --nas"
        printf '\n%s\n' "【NAS】NAS 的 IP,也可以寫 ~/.ssh/config 的名稱"
        until read -rp "NAS IP:" a && [ -n "$a" ] && set_nas "$a"; do :; done
    fi

    if [ ${#ARG_PERSONAL[@]} -gt 0 ] || [ ${#ARG_SHARED[@]} -gt 0 ]; then
        for p in "${ARG_PERSONAL[@]}"; do add_mapping personal "$p" || die "--personal 不正確:$p"; done
        for p in "${ARG_SHARED[@]}";   do add_mapping shared   "$p" || die "--shared 不正確:$p"; done
        return
    fi
    [ -t 0 ] || die "需要 --personal 或 --shared"
    while :; do
        printf '\n%s\n' "【每人一個】例如 homes:nas-home 會讓 ~/nas-home 指到 NAS 的 homes/<使用者>"
        while read -rp "<NAS 資料夾>:<家目錄內路徑>(空白 = 下一步):" a && [ -n "$a" ]; do
            add_mapping personal "$a" || true
        done
        printf '\n%s\n' "【大家共用】例如 share:nas-share 會讓 ~/nas-share 指到 NAS 的 share"
        while read -rp "<NAS 資料夾>:<家目錄內路徑>(空白 = 結束):" a && [ -n "$a" ]; do
            add_mapping shared "$a" || true
        done
        [ ${#P_FOLDER[@]} -gt 0 ] && break
        warn "至少要一個"
    done
}

# --- install on THIS machine -------------------------------------------------
# Existing mappings in $CONF are kept; a new mapping for the same folder wins.
# A replaced mapping whose path inside home changed is kept as "retired":
# the login hook removes that old link (only if it is ours, i.e. points into
# MNT_BASE).
merge_conf() {
    local kind f r i dup x
    [ -f "$CONF" ] || return 0
    while read -r kind f r; do
        case "$kind" in
            personal|shared) valid_name "$f" && valid_rel "$r" || continue ;;
            retired)         valid_rel "$f" && RETIRED+=("$f"); continue ;;
            *)               continue ;;
        esac
        dup=0
        for i in "${!P_FOLDER[@]}"; do
            if [ "${P_FOLDER[$i]}" = "$f" ] || [ "${P_REL[$i]}" = "$r" ]; then dup=1; break; fi
        done
        if [ "$dup" -eq 1 ]; then
            for x in "${P_REL[@]}"; do [ "$x" = "$r" ] && continue 2; done
            RETIRED+=("$r")
        else
            P_KIND+=("$kind"); P_FOLDER+=("$f"); P_REL+=("$r")
        fi
    done < <(grep -v '^#' "$CONF")
}

write_conf() {
    local i
    log "寫入 $CONF"
    {
        echo "# Managed by install-nas-folders.sh (${STAMP})."
        echo "# personal|shared <NAS folder> <path inside home>"
        echo "nas ${NAS_HOST}"
        for i in "${!P_FOLDER[@]}"; do echo "${P_KIND[$i]} ${P_FOLDER[$i]} ${P_REL[$i]}"; done
        # retired paths that are not in use again, once each
        local r x used
        for r in $(printf '%s\n' "${RETIRED[@]}" | sort -u); do
            used=0; for x in "${P_REL[@]}"; do [ "$x" = "$r" ] && used=1; done
            [ "$used" -eq 1 ] || echo "retired ${r}"
        done
    } > "$CONF"
    chmod 644 "$CONF"
}

write_fstab() {
    local i tmp m keep old=()
    log "更新 $FSTAB(自動掛載到 ${MNT_BASE}/)"
    while read -r _ m _; do
        [[ "$m" == "$MNT_BASE"/* ]] && old+=("$m")
    done < <(awk -v b="$FSTAB_BEGIN" -v e="$FSTAB_END" '$0==b{p=1;next} $0==e{p=0} p && !/^#/' "$FSTAB")
    [ -f "${FSTAB}.bak-nas-folders" ] || cp -a "$FSTAB" "${FSTAB}.bak-nas-folders"
    tmp="$(mktemp)"
    awk -v b="$FSTAB_BEGIN" -v e="$FSTAB_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$FSTAB" > "$tmp"
    {
        echo "$FSTAB_BEGIN"
        for i in "${!P_FOLDER[@]}"; do
            echo "${NAS_HOST}:/${P_FOLDER[$i]} ${MNT_BASE}/${P_FOLDER[$i]} nfs4 ${MNT_OPTS} 0 0"
        done
        echo "$FSTAB_END"
    } >> "$tmp"
    # an existing mount point may already be mounted (rerun): leave it alone
    for i in "${!P_FOLDER[@]}"; do
        [ -d "${MNT_BASE}/${P_FOLDER[$i]}" ] || install -d -m0755 "${MNT_BASE}/${P_FOLDER[$i]}"
    done
    findmnt --verify --tab-file "$tmp" >/dev/null 2>&1 || warn "findmnt --verify 對新的 fstab 有意見,請檢查"
    cat "$tmp" > "$FSTAB"; rm -f "$tmp"
    # mounts dropped from the config: stop and remove them
    for m in "${old[@]}"; do
        keep=0
        for i in "${!P_FOLDER[@]}"; do [ "$m" = "${MNT_BASE}/${P_FOLDER[$i]}" ] && keep=1; done
        [ "$keep" -eq 1 ] && continue
        log "停用不再使用的掛載:$m"
        systemctl stop "$(systemd-escape -p --suffix=automount "$m")" "$(systemd-escape -p --suffix=mount "$m")" >/dev/null 2>&1 || true
        findmnt -n "$m" >/dev/null 2>&1 && { umount "$m" 2>/dev/null || umount -l "$m" || true; }
        findmnt -n "$m" >/dev/null 2>&1 || rmdir "$m" 2>/dev/null || true
    done
    systemctl daemon-reload
    systemctl restart remote-fs.target
}

# test each mount: trigger the automount, it must become nfs4
test_mounts() {
    local i m ok=1
    for i in "${!P_FOLDER[@]}"; do
        m="${MNT_BASE}/${P_FOLDER[$i]}"
        timeout 20 stat "$m/." >/dev/null 2>&1 || true
        if findmnt -n -t nfs4 "$m" >/dev/null 2>&1; then
            log "掛載成功:$m"
        else
            warn "掛載失敗:$m(NAS 的 NFS 主機存取有沒有開放 $(hostname)?資料夾 ${P_FOLDER[$i]} 存在嗎?)"
            ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}

write_hook() {
    log "寫入登入時執行的 $HOOK"
    cat > "$HOOK" <<EOF
#!/bin/bash
# Managed by install-nas-folders.sh. Run by pam_exec at session open (as root).
# "personal" lines in ${CONF}: create <mount>/<user> AS THE USER (root is
# squashed on the NAS) and link ~/<path> to it.
# "shared" lines: link ~/<path> to <mount> (nothing to create on the NAS).
MNT_BASE=${MNT_BASE}
CONF=${CONF}
EOF
    cat >> "$HOOK" <<'EOF'
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
u="${PAM_USER:-}"; [ -n "$u" ] || exit 0
# LDAP accounts only (from sssd, not in /etc/passwd): local accounts have
# uids (1000, ...) that collide across machines and with NAS local users.
grep -q "^${u}:" /etc/passwd && exit 0
ent="$(getent -s sss passwd "$u")" || exit 0
IFS=: read -r _ _ uid gid _ home _ <<< "$ent"
[ "$uid" -gt 0 ] 2>/dev/null || exit 0
[ -d "$home" ] && [ "$(stat -c %u "$home")" = "$uid" ] || exit 0
[ -r "$CONF" ] || exit 0
say() { logger -t nas-folders -- "$u: $*"; }
as_user() { setpriv --reuid="$uid" --regid="$gid" --init-groups -- "$@"; }
# make_link: (re)create $link -> $target as the user; $stale = replace our old link
make_link() {
    if [ "$stale" = 1 ]; then
        as_user ln -sfn "$target" "$link" && say "$link 改指向 $target"
    else
        as_user mkdir -p "$(dirname "$link")" && as_user ln -s "$target" "$link"
    fi
}

nas="$(awk '$1=="nas"{print $2; exit}' "$CONF")"
nas_ok=""   # checked once, only when the NAS is actually needed

while read -r kind folder rel; do
    case "$kind" in
        personal) target="${MNT_BASE}/${folder}/${u}" ;;
        shared)   target="${MNT_BASE}/${folder}" ;;
        retired)  # old path from a replaced mapping: remove only our own link
            old="${home}/${folder}"
            if [ -L "$old" ]; then
                case "$(readlink "$old")" in
                    "${MNT_BASE}"/*) as_user rm -f "$old" && say "移除舊的連結 $old" ;;
                esac
            fi
            continue ;;
        *)        continue ;;
    esac
    link="${home}/${rel}"
    # Already set up: done without touching the NAS (a NAS that is down
    # would hang this login on the hard mount). A link of ours that points
    # to another place under MNT_BASE (mapping changed) is repointed.
    stale=0
    if [ -L "$link" ]; then
        cur="$(readlink "$link")"
        [ "$cur" = "$target" ] && continue
        case "$cur" in
            "${MNT_BASE}"/*) stale=1 ;;
            *) say "$link 已經是指向別處的連結,不動它"; continue ;;
        esac
    elif [ -e "$link" ]; then
        say "$link 已存在,不動它"; continue
    fi
    if [ "$kind" = "shared" ]; then
        make_link || say "無法建立連結 $link"
        continue
    fi
    if [ -z "$nas_ok" ]; then
        if [ -n "$nas" ] && timeout 2 bash -c "</dev/tcp/${nas}/2049" 2>/dev/null; then nas_ok=1; else nas_ok=0; fi
    fi
    [ "$nas_ok" = 1 ] || { say "連不到 NAS ${nas},下次登入再建立 $link"; continue; }
    # NAS side only as the user: root is squashed there and cannot see it
    if as_user test -e "$target"; then
        owner="$(as_user stat -c %u "$target" 2>/dev/null)"
        [ "$owner" = "$uid" ] || { say "$target 的擁有者是 $owner,不是 $uid,不建立連結"; continue; }
    else
        as_user mkdir "$target" 2>/dev/null \
            || { say "無法建立 $target(若是 NAS 的 homes:用 init-nas-home.sh 或登入一次 NAS 網頁,NAS 會建立)"; continue; }
        # the NAS applies its inherited ACL and ignores mkdir -m: set it after
        as_user chmod 700 "$target" || say "無法把 $target 設成 700"
    fi
    make_link || say "無法建立連結 $link"
done < <(grep -v '^#' "$CONF")
exit 0
EOF
    chmod 755 "$HOOK"
}

# After pam_mkhomedir (priority 0), so the home exists on the first login.
# timeout: a NAS that does not answer must not block the login.
write_pam() {
    log "啟用 PAM 登入設定(pam_exec)"
    cat > "$PAM_PROFILE" <<EOF
Name: NAS folders in home (install-nas-folders.sh)
Default: no
Priority: -10
Session-Type: Additional
Session-Interactive-Only: yes
Session:
	optional	pam_exec.so quiet /usr/bin/timeout 20 ${HOOK}
EOF
    DEBIAN_FRONTEND=noninteractive pam-auth-update --enable nas-folders
    grep -q "$HOOK" /etc/pam.d/common-session || die "pam-auth-update 沒有加進 /etc/pam.d/common-session"
}

confirm() {
    local i
    echo
    echo "================ 摘要 ================"
    echo " 目標機器 :$1"
    echo " NAS      :${NAS_HOST}(NFS 4.1)"
    for i in "${!P_FOLDER[@]}"; do
        if [ "${P_KIND[$i]}" = "personal" ]; then
            printf ' 每人一個 :NAS %s/<使用者>  ->  ~/%s\n' "${P_FOLDER[$i]}" "${P_REL[$i]}"
        else
            printf ' 大家共用 :NAS %s  ->  ~/%s\n' "${P_FOLDER[$i]}" "${P_REL[$i]}"
        fi
    done
    echo " 會修改   :/etc/fstab、${CONF}、${HOOK}、PAM(common-session)"
    echo " 會安裝   :nfs-common"
    echo "======================================"
    [ "$ASSUME_YES" -eq 1 ] && return
    local a; read -rp "確定套用?[y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || die "已中止,沒有修改任何東西"
}

# conflict_help LINES: explain why and how to fix
conflict_help() {
    echo "這台機器的本機帳號和 NAS 的本機帳號編號重疊(NFS 只看編號,不看名稱):" >&2
    echo "$1" | sed 's/^/    /' >&2
    echo "修正(帳號要先登出,以 <帳號> 代入):" >&2
    echo "    sudo usermod -u ${LOCAL_UID_SAFE} <帳號>     # uid 改到 ${LOCAL_UID_SAFE} 以上,家目錄檔案會一起改" >&2
    echo "    sudo gpasswd -d <帳號> users          # 移出群組 100" >&2
    echo "    或直接用 fix-local-uid.sh 一次處理(也會處理主要群組是 100/0 的帳號)" >&2
}

install_tool() {
    parse_opts "$@"
    command -v apt-get >/dev/null || die "只支援 Debian/Ubuntu(apt)"
    command -v setpriv >/dev/null || die "找不到 setpriv(util-linux)"
    local conf_lines; conf_lines="$(bash -c "$CONFLICT_SH")"
    [ -z "$conf_lines" ] || { conflict_help "$conf_lines"; die "先修正本機帳號再執行"; }
    ask_settings
    timeout 5 bash -c "</dev/tcp/${NAS_HOST}/${NFS_PORT}" 2>/dev/null \
        || die "$(hostname) 連不到 ${NAS_HOST}:${NFS_PORT}(NFS)"
    merge_conf
    [ "$FROM_DEPLOY" -eq 1 ] || confirm "$(hostname)"

    log "安裝 nfs-common"
    apt_q update
    apt_q install nfs-common

    write_conf
    write_fstab
    write_hook
    write_pam
    test_mounts || die "掛載有問題,登入設定已裝好,修好 NAS 端後重新登入即可"
    log "$(hostname) 完成。LDAP 使用者下次登入時會自動建立資料夾與連結。"
}

# --- deploy from YOUR PC (password SSH, no keys needed) ---------------------
deploy_cleanup() {
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
    ssh-keygen -lF "${T_SHOW[$i]##*@}" 2>/dev/null | grep -v '^#' | sed 's/^/    host key: /' >&2 || true
    r_ssh "$i" 'command -v apt-get && command -v pam-auth-update' >/dev/null 2>&1 \
        || { REASON="不是 Debian/Ubuntu(沒有 apt-get 或 pam-auth-update)"; return 1; }
    if [ "$(r_ssh "$i" 'id -u' 2>/dev/null)" = "0" ]; then
        T_ROOT[i]=1
    elif ! r_ssh_in "$i" "sudo -S -p '' -v" < "${WORK}/pw.$i" >/dev/null 2>&1; then
        REASON="${T_SHOW[$i]%@*} 無法使用 sudo(密碼錯誤或沒有 sudo 權限)"; return 1
    fi
    r_ssh "$i" "timeout 5 bash -c '</dev/tcp/${NAS_HOST}/${NFS_PORT}'" >/dev/null 2>&1 \
        || { REASON="這台連不到 ${NAS_HOST}:${NFS_PORT}(NFS)"; return 1; }
    local c; c="$(r_ssh "$i" "$CONFLICT_SH" 2>/dev/null || true)"
    if [ -n "$c" ]; then conflict_help "$c"; REASON="本機帳號編號和 NAS 重疊:$(echo "$c" | tr '\n' ' ')"; return 1; fi
    r_ssh "$i" 'grep -q "^[^#]*sss" /etc/nsswitch.conf' >/dev/null 2>&1 \
        || warn "${T_SHOW[$i]} 看起來還沒設 LDAP 登入(nsswitch 沒有 sss),之後再跑 install-sssd-ldap.sh 也可以"
    return 0
}

run_on() {
    local i="$1" rdir cmd rc=0 p
    rdir="$(r_ssh "$i" 'umask 077; mktemp -d /tmp/nas-folders.XXXXXX')" || return 1
    r_scp "$i" "$rdir" "$SELF" || { r_ssh "$i" "rm -rf '$rdir'" || true; return 1; }
    cmd="bash $(printf '%q' "$rdir/$(basename "$SELF")") install --from-deploy --yes"
    cmd+=" --nas $(printf '%q' "$NAS_HOST")"
    for p in "${!P_FOLDER[@]}"; do cmd+=" --${P_KIND[$p]} $(printf '%q' "${P_FOLDER[$p]}:${P_REL[$p]}")"; done
    if [ "${T_ROOT[$i]}" -eq 1 ]; then
        r_ssh "$i" "$cmd" || rc=$?
    else
        r_ssh_in "$i" "sudo -S -p '' $cmd" < "${WORK}/pw.$i" || rc=$?
    fi
    r_ssh "$i" "rm -rf '$rdir'" || warn "${T_SHOW[$i]}:無法刪除 $rdir"
    return "$rc"
}

deploy_tool() {
    parse_opts "$@"
    [ "$FROM_DEPLOY" -eq 0 ] || die "--from-deploy 是內部用參數"
    [ -t 0 ] || die "需要互動式終端機"
    command -v ssh >/dev/null && command -v scp >/dev/null || die "找不到 ssh 或 scp"
    check_ssh_version

    WORK="$(mktemp -d /tmp/nas-folders-deploy.XXXXXX)"; chmod 700 "$WORK"
    trap deploy_cleanup EXIT
    printf '#!/bin/sh\nexec cat "$PW_FILE"\n' > "${WORK}/askpass"
    chmod 700 "${WORK}/askpass"

    ask_settings
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
    echo "(機器上已經設定過的資料夾會保留)"
    confirm "${names[*]}"

    for i in "${ok[@]}"; do
        echo; log "========== ${T_SHOW[$i]} =========="
        if run_on "$i"; then results+=("完成    ${T_SHOW[$i]}"); else results+=("失敗    ${T_SHOW[$i]}"); fi
    done
    echo; log "結果"
    for i in "${results[@]}"; do echo "  $i"; done
    for i in "${bad[@]}";     do echo "  跳過    $i"; done
    echo "用 LDAP 使用者重新登入目標機器後,檢查:ls -l ~/<家目錄內路徑>"
}

# --- check (on this machine) -------------------------------------------------
check_tool() {
    local u="${1:-}" kind f r home
    echo "--- $CONF";   cat "$CONF" 2>/dev/null || echo "(沒有)"
    echo "--- fstab";   awk -v b="$FSTAB_BEGIN" -v e="$FSTAB_END" '$0==b{p=1} p; $0==e{p=0}' "$FSTAB"
    echo "--- 掛載";    findmnt -t nfs4,autofs -o TARGET,SOURCE,FSTYPE | grep -F "$MNT_BASE" || echo "(沒有)"
    echo "--- PAM";     grep -F "$HOOK" /etc/pam.d/common-session || echo "(沒有啟用)"
    [ -n "$u" ] || return 0
    home="$(getent passwd "$u" | cut -d: -f6)" || { echo "--- 找不到使用者 $u"; return 0; }
    while read -r kind f r; do
        case "$kind" in personal|shared) ;; *) continue ;; esac
        echo "--- $u:~/$r($kind)"; ls -ld "$home/$r" 2>&1 || true
    done < <(grep -v '^#' "$CONF" 2>/dev/null)
    echo "--- 登入記錄"; journalctl -t nas-folders -n 10 --no-pager 2>/dev/null || true
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "==> 需要 root 權限,用 sudo 重新執行..."
        exec sudo bash "$SELF" "$@"
    fi
}

main() {
    local cmd="${1:-}"; [ $# -gt 0 ] && shift
    case "$cmd" in
        -h|--help|help) usage 0 ;;
        ""|deploy)      deploy_tool "$@" ;;
        --*)            deploy_tool "$cmd" "$@" ;;
        install)        require_root install "$@"; install_tool "$@" ;;
        check)          require_root check "$@";   check_tool "$@" ;;
        remove)         die "移除請用 remove-nas-folders.sh" ;;
        *)              usage ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

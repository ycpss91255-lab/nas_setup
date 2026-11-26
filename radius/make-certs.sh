#!/usr/bin/env bash
# 產生 Wi-Fi 驗證用的憑證(自己的 CA + 伺服器憑證)。在你的電腦執行，openssl 在 docker 裡跑。
#
#   bash make-certs.sh --out <資料夾> [--name <伺服器名稱>] [--renew]
#
# 產生:
#   ca.key      CA 私鑰：只留在你的電腦(之後換發伺服器憑證要用),不要上傳
#   ca.pem      CA 憑證：上傳到 NAS,也給手機/電腦安裝或信任
#   server.key  伺服器私鑰：上傳到 NAS
#   server.pem  伺服器憑證：上傳到 NAS
#
# --renew:沿用現有 CA,只換發伺服器憑證(手機/電腦不用重新設定)。
set -euo pipefail

# ── 預設值(留空 = 沒給參數時詢問)──
CFG_OUT=""
CFG_NAME="radius.wifi.lan"   # 手機設定「網域」時填這個
CFG_CA_DAYS=3650             # CA 10 年
CFG_SERVER_DAYS=825          # 伺服器憑證：Apple 上限 825 天
IMAGE="freeradius/freeradius-server:3.2.7"

OUT="$CFG_OUT"; NAME="$CFG_NAME"; RENEW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --renew) RENEW=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "不認得的參數:$1" >&2; exit 1 ;;
    esac
done
[ -n "$OUT" ] || read -rp "憑證要放在哪個資料夾:" OUT
[ -n "$OUT" ] || { echo "沒有資料夾" >&2; exit 1; }

mkdir -p "$OUT"; chmod 700 "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [ "$RENEW" = 1 ]; then
    [ -s "$OUT/ca.key" ] && [ -s "$OUT/ca.pem" ] || { echo "--renew 需要 $OUT 裡已有 ca.key、ca.pem" >&2; exit 1; }
else
    for f in ca.key ca.pem server.key server.pem; do
        [ -e "$OUT/$f" ] && { echo "$OUT/$f 已存在。要換發伺服器憑證請加 --renew;要全部重做請先自己移走舊檔" >&2; exit 1; }
    done
fi

docker run --rm -u "$(id -u):$(id -g)" -v "$OUT:/out" --entrypoint sh \
    -e NAME="$NAME" -e CA_DAYS="$CFG_CA_DAYS" -e SERVER_DAYS="$CFG_SERVER_DAYS" -e RENEW="$RENEW" \
    "$IMAGE" -c '
set -eu
cd /out
umask 077
if [ "$RENEW" != 1 ]; then
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days "$CA_DAYS" \
        -keyout ca.key -out ca.pem -subj "/CN=Wi-Fi RADIUS CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
fi
openssl req -newkey rsa:3072 -sha256 -nodes -keyout server.key -out server.csr \
    -subj "/CN=$NAME" 2>/dev/null
printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n" "$NAME" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -days "$SERVER_DAYS" -sha256 -extfile server.ext -out server.pem 2>/dev/null
rm -f server.csr server.ext ca.srl
chmod 600 ca.key server.key; chmod 644 ca.pem server.pem
openssl verify -CAfile ca.pem server.pem
echo "伺服器憑證到期:$(openssl x509 -in server.pem -noout -enddate | cut -d= -f2)"
echo "CA 到期:        $(openssl x509 -in ca.pem -noout -enddate | cut -d= -f2)"
'
echo "完成:$OUT"
echo "上傳到 NAS:ca.pem、server.pem、server.key(ca.key 不要上傳)"

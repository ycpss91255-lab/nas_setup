#!/bin/sh
# 容器啟動時執行：把這個資料夾的設定放進 FreeRADIUS,再啟動。
# 官方映像檔本身不修改，換版本或重建容器都會重新套用。
set -eu
C=/opt/wifi
R=/etc/freeradius

for v in LDAP_HOST LDAP_BASE_DN LDAP_BIND_USER LDAP_BIND_PW WIFI_GROUP CLIENT_IP RADIUS_SECRET; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { echo "缺少環境變數 $v" >&2; exit 1; }
done
for f in ca.pem server.pem server.key; do
    [ -s "$C/certs/$f" ] || { echo "缺少憑證 certs/$f" >&2; exit 1; }
done

# 只留需要的：預設站台、EAP、範例用戶端全部換掉
rm -f "$R"/sites-enabled/* "$R"/mods-enabled/eap
cp "$C"/sites/default "$C"/sites/inner-tunnel "$R"/sites-enabled/
cp "$C"/mods/ldap "$C"/mods/eap "$R"/mods-enabled/
cp "$C"/policy/wifi "$R"/policy.d/wifi
cp "$C"/clients.conf "$R"/clients.conf

mkdir -p "$R"/certs/wifi
cp "$C"/certs/ca.pem "$C"/certs/server.pem "$C"/certs/server.key "$R"/certs/wifi/
chown -R root:freerad "$R"/certs/wifi
chmod 750 "$R"/certs/wifi
chmod 640 "$R"/certs/wifi/*

# 記錄每次登入成功/失敗(只有帳號，不含密碼)
sed -i 's/^\(\s*auth\s*=\s*\)no/\1yes/' "$R"/radiusd.conf

exec freeradius -f -l stdout "$@"

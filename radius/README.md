# radius:Wi-Fi 用自己的 LDAP 帳號登入

每個人連 Wi-Fi 時輸入自己的 LDAP 帳號密碼(WPA2-Enterprise),不再共用一組 Wi-Fi 密碼。

- 帳號從 LDAP 刪掉、或移出 `wifi-users` 群組，就連不上了。
- 驗證由 NAS 上的 FreeRADIUS 容器處理，它去問 NAS 的 LDAP。

> **狀態**:原型。帳號密碼與群組檢查已在 docker 測過(PAP);手機透過路由器的 EAP-TTLS 連線尚未實測。

```
手機/電腦 ──Wi-Fi──> 路由器 ──RADIUS(UDP 1812)──> NAS:FreeRADIUS 容器 ──LDAPS──> NAS:LDAP
```

## 為什麼不用 NAS 內建的 RADIUS

NAS 內建的 RADIUS 伺服器只認 NAS 本機帳號和它自己的 RADIUS 帳號，**不認 LDAP 帳號**(實測拒絕)。網頁上也沒有改成 LDAP 的選項。

內建的 RADIUS 伺服器**必須保持關閉**,不然會跟容器搶 1812 埠。

## 限制

- 登入方式只有 **EAP-TTLS + PAP**。
  - PEAP(很多裝置的預設)需要 NT 密碼雜湊,NAS 的 LDAP 不提供，所以不能用。
  - 密碼在加密通道(TLS)裡傳送。
- 路由器(ASUS)只有**主要網路**能用 Enterprise。訪客網路和 AiMesh 模式不能用。
- NAS 關機或容器停掉時，新裝置連不上 Wi-Fi。所以建議保留一個用一般密碼(Personal)的網路當備用。

## 1. 準備(在你的電腦)

### 憑證

```sh
bash make-certs.sh --out ~/wifi-radius-certs
```

- 產生自己的 CA 和伺服器憑證。手機會用 CA 確認連到的是真的伺服器。
- `ca.key` 只留在你的電腦，不要上傳。換發伺服器憑證要用它，請另外備份。
- **伺服器憑證 825 天後到期**,到期後所有人都連不上。到期前換發:
  ```sh
  bash make-certs.sh --out ~/wifi-radius-certs --renew
  ```
  再把新的 `server.pem`、`server.key` 上傳，然後重新啟動容器。CA 沒換，手機和電腦不用重新設定。

### LDAP 群組

NAS 網頁 → LDAP 伺服器 → 群組 → 建立 `wifi-users`,把要用 Wi-Fi 的人加進去。

## 2. NAS 端(網頁)

1. **確認內建 RADIUS 關閉**:控制台 → 應用服務 → RADIUS 伺服器 →「啟用 RADIUS 伺服器」不勾。
2. **上傳設定**:File Station → `Container` → 建立資料夾 `wifi-radius`。
   - 把 [`conf/`](conf/) **裡面的東西**上傳進去(`start.sh`、`clients.conf`、`mods/`、`sites/`、`policy/`)。
   - 在 `wifi-radius` 裡建立 `certs`,上傳 `ca.pem`、`server.pem`、`server.key`。
3. **建立容器**:Container Station → 應用程式 → 建立，名稱 `wifi-radius`,貼上 [`compose.yaml`](compose.yaml) 的內容，然後改這些值:
   - `LDAP_BASE_DN`:LDAP 的 base DN。
   - `LDAP_BIND_PW`:`scan_group` 的密碼。
   - `CLIENT_IP`:路由器的 IP。
   - `RADIUS_SECRET`:自己產生一組長的隨機字串，例如 `openssl rand -base64 24`,路由器要填一樣的。
4. **確認啟動**:容器的紀錄最後一行是 `Ready to process requests`。
   - 少填值或少憑證時，容器會停下，紀錄寫「缺少環境變數 …」或「缺少憑證 …」。

## 3. 路由器(ASUS)

無線網路 → 一般設定 → 選一個頻段:

| 欄位 | 值 |
|---|---|
| 驗證方式 | WPA2-Enterprise(或 WPA2/WPA3-Enterprise) |
| RADIUS 伺服器 IP | NAS 的 IP |
| 埠 | 1812 |
| 連線密碼 | 跟 `RADIUS_SECRET` 一樣 |

- 建議先改一個頻段，測好再改其他頻段。
- 改的頻段上已經連著的裝置會斷線，要用帳號密碼重連。

## 4. 手機/電腦連線

共同設定:

| 項目 | 值 |
|---|---|
| EAP 方法 | **TTLS** |
| 第二階段(內部)驗證 | **PAP** |
| 身分 | 自己的 LDAP 帳號 |
| 匿名身分 | 留空 |
| CA 憑證 | 安裝 `ca.pem`(或連線時選「信任」) |
| 網域 | `radius.wifi.lan`(`make-certs.sh --name` 設的名稱) |

- **Android**:先在「設定 → 安全性 → 加密與憑證 → 安裝憑證 → Wi-Fi 憑證」安裝 `ca.pem`,再照上表填。
- **Windows / macOS / iOS / Linux**:選 TTLS、PAP,第一次連線會顯示伺服器憑證，確認是這張 CA 簽的再信任。

## 日常管理

- **新增人**:LDAP 網頁把他加進 `wifi-users`。
- **停用人**:移出 `wifi-users` 或刪除 LDAP 帳號。已經連著的裝置下次重新連線時才會被擋。
- **看登入紀錄**:Container Station → `wifi-radius` → 紀錄。
  - 成功：`Login OK: [帳號]`。
  - 失敗:`Login incorrect` / `Invalid user`(不存在或不在群組)。
  - 紀錄不含密碼。
- **改設定**:在 File Station 改 `wifi-radius` 裡的檔案，然後重新啟動容器。

## 還原(不用了)

1. 路由器：驗證方式改回 WPA2/WPA3-Personal,填回原本的 Wi-Fi 密碼。
2. Container Station:停止並刪除 `wifi-radius` 應用程式。
3. File Station:刪除 `Container/wifi-radius`。
4. LDAP 群組 `wifi-users` 可以留著，也可以刪掉。

## 檔案說明

| 檔案 | 用途 |
|---|---|
| `compose.yaml` | Container Station 用的容器設定 |
| `make-certs.sh` | 產生 / 換發憑證(openssl 在 docker 裡跑) |
| `conf/start.sh` | 容器啟動時把設定放進 FreeRADIUS,打開登入紀錄，再啟動 |
| `conf/mods/ldap` | 連 LDAP:查使用者和群組，用使用者自己的密碼驗證 |
| `conf/mods/eap` | 只開 EAP-TTLS |
| `conf/policy/wifi` | 檢查：有密碼、帳號存在、在 `wifi-users` |
| `conf/sites/default`、`inner-tunnel` | 接路由器的請求、TTLS 通道內的驗證 |
| `conf/clients.conf` | 只接受路由器(`CLIENT_IP`) |

官方映像檔不做任何修改，換版本只要改 `compose.yaml` 的 `image`。

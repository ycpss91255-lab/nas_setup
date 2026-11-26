# 節點 LDAP 與 NAS 資料夾:操作流程

## 大綱

1. [init:建立環境、新增節點](#1-init建立環境新增節點)
   - [1-A. NAS 第一次設定](#1-a-nas-第一次設定整套只做一次全部在-nas-網頁)
   - [1-B. 新增節點](#1-b-新增節點每台做一次)
2. [add_user:新增使用者](#2-add_user新增使用者)
3. [del_user:刪除使用者](#3-del_user刪除使用者)
4. [remove:移除節點(或重裝)](#4-remove移除節點或重裝)
5. [補充：單獨調整本機帳號 uid](#補充單獨調整本機帳號-uid)
6. [附錄](#附錄)
   - [架構](#架構)
   - [改名](#改名)
   - [備份](#備份)
   - [NAS 重開機或斷線](#nas-重開機或斷線)
   - [疑難排解](#疑難排解在節點上執行)

每支腳本的細節看 `README.md`,或用 `--help`。

- 腳本都在**你自己的電腦**上執行，透過 SSH 設定目標機器。
- 密碼在執行時輸入，不會存下來。
- 常用的值(NAS IP、網域、機器等)可以填在每支腳本最上面的「預設值」區塊。優先順序：命令列參數 → 預設值 → 都沒有才問。

---

## 1. init:建立環境、新增節點

### 1-A. NAS 第一次設定(整套只做一次，全部在 NAS 網頁)

1. **LDAP 伺服器**:控制台 → 應用服務 → LDAP 伺服器
   - 勾「啟動」,填「完整網域名稱」(例如 `example.com`)和 admin 密碼，然後套用。
   - 網域名稱會寫進所有帳號，之後要改只能重建。
   - **不要按「初始化 LDAP 資料庫」**,會刪掉所有帳號。
2. **群組**:LDAP 伺服器 → 群組，建立:
   - `cluster-admins`:可登入節點，可 sudo
   - `cluster-users`:可登入節點，不能 sudo
3. **查詢帳號**:LDAP 伺服器 → 使用者，建立 `scan_group`。
   - **不要加入任何群組**:它的密碼會存在每台節點上。
4. **讓 LDAP 帳號能用 NAS 網頁**:控制台 → 權限 → 網域安全認證 → LDAP 驗證 → 本機 NAS 上的 LDAP 伺服器。
   - LDAP 驗證選項選「僅限本機使用者」(SMB 只給本機帳號)。
5. **使用者家目錄**:控制台 → 權限 → 使用者 → 進階設定 → 使用者家目錄，啟用。
6. **NFS**:控制台 → 網路與檔案服務 → NFS 服務，啟用 v4、v4.1。
7. **`homes`**:控制台 → 權限 → 共用資料夾 → `homes`
   - 屬性:勾「目前僅允許管理者群組存取資源回收筒」。需要重啟檔案服務。
   - NAS 管理員自己的家目錄：拿掉群組 `everyone` 那一條。
8. **`share`**:建立共用資料夾 `share`,放在 HDD 鏡像的儲存池，開快照。
   - 通訊協定權限:administrators 讀寫、Domain Users 讀寫、guest 禁止。
   - 獨立權限 → Windows 特殊權限：刪掉預設的 Everyone。它在畫面上方清單看不到，但權限是完整讀寫。
9. **隱藏快照資料夾**:儲存與快照總管 → 快照 → 全域設定，關閉「各共用資料夾中的快照資料夾」。
10. **備份**(排程見[附錄](#備份)):
    - LDAP 伺服器 → 備份/還原
    - 系統 → 備份/還原

### 1-B. 新增節點(每台做一次)

1. **NAS 網頁**:`homes`、`share` 各自的「編輯權限 → NFS 主機存取」加上新節點的 IP。
   - 設定:`sys`、讀寫、secure、Squash 僅根使用者。
   - 之後改成整個節點網段的話，這步就不用每台做。
2. **節點本身**:Ubuntu / Debian,能用密碼 SSH 登入，有一個能 sudo 的本機管理員。
3. **你的電腦**:
   ```sh
   bash install-all.sh --nas <NAS_IP> --domain <LDAP_DOMAIN> \
        --host <LOCAL_ADMIN>@<HOST_IP> --ldap-admin <LDAP_USER> \
        --allow-groups cluster-admins,cluster-users --sudo-groups cluster-admins -y
   ```
   - 開頭一次問完密碼，依序是 `scan_group`、每台的本機管理員、`--ldap-admin` 的帳號。之後全部自動。
   - `--ldap-admin`:在節點上能 sudo 的 LDAP 帳號，不一定要是 NAS 管理員。
   - 不加 `-y` 的話，每一步會先顯示摘要再問。
   - 多台機器:`--host a@IP1,a@IP2`。
   - 中途失敗，修好後加 `--from 2` 或 `--from 3` 接著跑。

`install-all.sh` 依序做三步:

| 步驟 | 腳本 | 登入帳號 | 做什麼 |
|---|---|---|---|
| 1 | `install-sssd-ldap.sh` | 本機管理員 | LDAP 登入、可登入群組、sudo 群組 |
| 2 | `fix-local-uid.sh` | 能 sudo 的 LDAP 帳號 | 本機帳號改號，之後新增的本機帳號從 5000 起(見[補充](#補充單獨調整本機帳號-uid)) |
| 3 | `install-nas-folders.sh` | 同上 | `~/nas-home`、`~/nas-share` |

---

## 2. add_user:新增使用者

1. **NAS 網頁**:LDAP 伺服器 → 使用者 → 建立。設定初始密碼，加入群組:
   - 一般使用者:`cluster-users`
   - 要 sudo 的:`cluster-admins`
2. **你的電腦**:用初始密碼讓 NAS 建好家目錄(多個帳號用 `a,b,c`):
   ```sh
   bash init-nas-home.sh --nas <NAS_IP> --user <帳號>
   ```
   沒跑這步的話，要等他第一次登入 NAS 網頁後，節點上才會有 `~/nas-home`。
3. **告訴使用者**:
   - 用 LDAP 帳號和密碼 SSH 登入任何節點。
   - 改密碼：登入 NAS 網頁 → 右上角帳號 → 登入與安全性 → 密碼。改完節點上馬上生效。節點上的 `passwd` 不能改。
   - 第一次登入 NAS 網頁會先出現 QNAP 使用條款，同意後才能進入。
   - SSH 公鑰每人自己放到各節點的 `~/.ssh/authorized_keys`。

改群組(例如給 sudo):在 NAS 網頁改，使用者下次登入節點就生效。

---

## 3. del_user:刪除使用者

1. **NAS 網頁**:LDAP 伺服器 → 使用者 → 刪除。從這一刻起，節點都不讓他登入。
2. **NAS 網頁 File Station**(用 NAS 管理員):刪掉 `homes/<帳號>` 和 `homes/@Recycle/<帳號>`。
   - 刪帳號不會自動刪這兩個。要保留資料就先搬走。
3. **你的電腦**:清掉節點上留下的家目錄、程式、cron、快取:
   ```sh
   bash cleanup-ldap-user.sh --user <帳號> --nas <NAS_IP> --domain <LDAP_DOMAIN> \
        --host <SSH_USER>@<HOST_IP>,...
   ```
   - 帳號在 NAS 上還沒刪的話，腳本會停止。
   - 「沒有找到 <帳號> 留下的東西」= 他沒登入過那台，或已經清過。

---

## 4. remove:移除節點(或重裝)

用節點的本機管理員登入，依序執行:

```sh
bash remove-nas-folders.sh --host <LOCAL_ADMIN>@<HOST_IP>
```

```sh
bash remove-sssd-ldap.sh --host <LOCAL_ADMIN>@<HOST_IP>
```

- NAS 上的資料不會動，節點 `/home` 底下的家目錄也保留。
- 不再使用這台的話，最後到 NAS 的 NFS 主機存取拿掉這台的 IP。
- 要重裝：移除後照 [1-B](#1-b-新增節點每台做一次) 再跑一次。

---

## 補充：單獨調整本機帳號 uid

`install-all.sh` 第 2 步已經做過，之後新增的本機帳號也會自動從 5000 起。新增帳號時自己指定了 1000–4999 的編號，才需要單獨跑。

原因:NFS 只看編號。NAS 本機帳號從 uid 1000 起、群組 100 是 everyone,和 Ubuntu 本機帳號重疊，不改就會被 NAS 當成別人。

在你的電腦執行:
```sh
bash fix-local-uid.sh --host <LDAP_USER>@<HOST_IP>
```

- 登入帳號要能 sudo,而且不能是要改號的那個帳號。
- uid 1000–4999 改到 5000 起，並移出群組 100。帳號名稱、密碼、sudo 不變。
- 同時設定之後新增的本機帳號(`adduser`、`useradd`)從 5000 起、不加入群組 100。
- 被改號的帳號會被強制登出，改完重新登入即可。

---

## 附錄

### 架構

| 東西 | 在哪裡 | 說明 |
|---|---|---|
| 帳號、群組 | NAS「LDAP 伺服器」 | 所有節點共用同一套帳號 |
| `~/nas-home` | NAS `homes/<帳號>` | 每人一個，只有本人能用;等於 NAS 網頁上的 `home` |
| `~/nas-share` | NAS `share` | 所有 LDAP 帳號共用 |
| 節點上的設定 | sssd、`/etc/fstab`、PAM | 由腳本安裝，NFS 4.1 自動掛載到 `/mnt/nas/` |

| 帳號 | 節點登入 | `~/nas-home` | `~/nas-share` | NAS 網頁 |
|---|---|---|---|---|
| LDAP 帳號(可登入群組) | ✓ | 自己的 | ✓ | `home`、`share` |
| 節點本機帳號、root | ✓(只限該台) | — | ✗ | — |
| NAS 管理員 | — | — | — | 全部 |

### 改名

- **節點上的路徑**:再跑一次 `install-nas-folders.sh`,給新的對應(例如 `--personal homes:<新名稱>`)。舊連結在使用者下次登入時自動處理。
- **NAS 上的共用資料夾**:改名會**清掉 NFS 主機存取**,要重設一次，再對每台節點跑 `install-nas-folders.sh`。

### 備份

| 備份 | 排程 | 位置 |
|---|---|---|
| LDAP 資料庫 | 每星期六 00:00,覆寫 `LDAP_Backup.exp` | NAS 上插著的 USB 隨身碟，`nas-backup/` |
| NAS 系統設定 | 每星期六 01:00,檔名帶日期 | 同上 |

- 設定位置:LDAP 伺服器 → 備份/還原;控制台 → 系統 → 備份/還原。
- USB 要一直插著，拔掉的那週備份會失敗。
- NAS 壞掉時，把 USB 插到任何電腦就能拿到備份檔。

### NAS 重開機或斷線

- 節點上讀寫 `~/nas-home`、`~/nas-share` 的程式會停住，NAS 回來後自動繼續，資料不會壞。
- 本機帳號照常登入;LDAP 帳號多等幾秒，用離線快取登入(曾經登入過的人才行)。

### 疑難排解(在節點上執行)

**登入後沒有 `~/nas-home`**:看記錄。多半是 NAS 上還沒有家目錄，跑 `init-nas-home.sh`。
```sh
sudo journalctl -t nas-folders -n 20
```

**`~/nas-home` 打不開**:先確認 NAS 的 NFS 主機存取有這台的 IP,再看掛載:
```sh
findmnt /mnt/nas/homes
```

**LDAP 帳號登不進節點**:先確認帳號在可登入群組，再看:
```sh
sudo bash install-sssd-ldap.sh check <帳號>
```

**節點整體狀態**:
```sh
sudo bash install-nas-folders.sh check <帳號>
```

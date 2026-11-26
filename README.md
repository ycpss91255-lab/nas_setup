# nas_setup

NAS 相關的設定流程與腳本。以 QNAP(QuTS hero)為主，搭配 Debian / Ubuntu 節點。

- 腳本都在**你自己的電腦**上執行，透過 SSH 設定目標機器。
- 密碼在執行時輸入，不會存下來。
- NAS 的設定只能在 NAS 網頁上手動做，所以寫成文件，不寫成腳本。

## 內容

| 目錄 | 用途 |
|---|---|
| [`ldap/`](ldap/) | NAS 內建 LDAP 給節點登入、節點家目錄裡的 NAS 資料夾(NFS) |
| [`syslog/`](syslog/) | 節點重要的系統紀錄(登入、sudo、警告以上)集中送到 NAS,並設定時區 |
| [`security/`](security/) | NAS 安全設定：外部連線(Link)、登入保護、密碼原則、病毒防護 |
| [`radius/`](radius/) | Wi-Fi 用自己的 LDAP 帳號登入(NAS 上的 FreeRADIUS 容器) |

之後會加入 VPN 等其他設定。

## NAS 第一次設定(整套只做一次，在 NAS 網頁)

| 項目 | 詳細步驟 |
|---|---|
| LDAP 伺服器、群組、查詢帳號、使用者家目錄、NFS、`homes`、`share`、備份 | [ldap/WORKFLOW.md 1-A](ldap/WORKFLOW.md#1-a-nas-第一次設定整套只做一次全部在-nas-網頁) |
| `syslog` 共用資料夾、Syslog 伺服器(只開 TCP)、寄信通知 | [syslog/README.md「NAS 端」](syslog/README.md#nas-端網頁只做一次) |

## 新增節點(完整流程)

1. **NAS 網頁**:`homes`、`share` 的「編輯權限 → NFS 主機存取」加上新節點的 IP。
   - 設定:`sys`、讀寫、secure、Squash 僅根使用者。
   - 改成整個節點網段(例如 `192.168.1.0/24`)的話，這步只要做一次。
2. **節點本身**:Ubuntu / Debian,能用密碼 SSH 登入，有一個能 sudo 的本機帳號。
3. **你的電腦**:一條指令做完全部:
   ```sh
   bash ldap/install-all.sh --nas <NAS_IP> --domain <LDAP_DOMAIN> \
        --host <LOCAL_ADMIN>@<HOST_IP> --ldap-admin <LDAP_USER> \
        --allow-groups cluster-admins,cluster-users --sudo-groups cluster-admins -y
   ```
   - 開頭一次問完密碼:`scan_group`、每台的本機帳號、`--ldap-admin` 的帳號。之後全部自動。
   - 多台機器:`--host a@IP1,a@IP2`。
   - 中途失敗，修好後加 `--from 2`、`--from 3` 或 `--from 4` 接著跑。
4. **確認**:用 LDAP 帳號登入新節點，家目錄裡有 `nas-home`、`nas-share`;NAS 的 Syslog 檢視器看得到這台的紀錄。

`install-all.sh` 依序做四步:

| 步驟 | 腳本 | 做什麼 |
|---|---|---|
| 1 | `ldap/install-sssd-ldap.sh` | LDAP 登入、可登入群組、sudo 群組 |
| 2 | `ldap/fix-local-uid.sh` | 本機帳號改號，之後新增的本機帳號從 5000 起 |
| 3 | `ldap/install-nas-folders.sh` | `~/nas-home`、`~/nas-share` |
| 4 | `syslog/install-syslog.sh` | 重要紀錄送到 NAS、時區設成 Asia/Taipei(`--no-syslog` 跳過,`--timezone` 改時區) |

常用的值(NAS IP、網域、機器等)可以填在每支腳本最上面的「預設值」區塊，之後就不用每次輸入。

## 其他操作

- LDAP 帳號的新增、刪除，節點移除：[ldap/WORKFLOW.md](ldap/WORKFLOW.md)
- LDAP 腳本細節：[ldap/README.md](ldap/README.md)
- syslog 細節、移除、看紀錄：[syslog/README.md](syslog/README.md)
- NAS 安全設定：[security/README.md](security/README.md)
- Wi-Fi 帳號登入：[radius/README.md](radius/README.md)

## 授權

[Apache-2.0](LICENSE)

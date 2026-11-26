# install-sssd-ldap

> 日常操作流程(新增節點、新增/刪除使用者、備份等)看 [WORKFLOW.md](WORKFLOW.md)。

讓 Debian/Ubuntu 機器(CI runner 主機、叢集節點等)用 **NAS 內建 LDAP** 的帳號登入(sssd)。

## 用法:在你自己的電腦上執行,不帶參數

```sh
bash install-sssd-ldap.sh
```

依序問你(**按 y 之前任何目標機器都不會被修改**):

1. **NAS** `[SCAN_USER@]IP`(SCAN_USER 可省略;IP 可用 ssh 設定名稱),再輸入 **LDAP 網域**(NAS「LDAP 伺服器」頁的「完整網域名稱」)。沒有預設值。
2. **查詢用的 LDAP 帳號**(不是登入目標機器的帳號):預設 `scan_group`,再輸入密碼。登入失敗(帳號不存在或密碼錯)可以重輸,最多 3 次。
3. **勾選可登入的群組**(複選),再勾選其中哪些可以 sudo。
4. **目標機器** `[SSH_USER@]IP`(SSH_USER 可省略;IP 可用 ssh 設定名稱),再輸入密碼;可以接著加第二台、第三台(共用同一組群組選擇)。
5. 逐台檢查:密碼 SSH 能登入、sudo 可用、**目標機器自己連得到 NAS:636**。不通的列為 SKIP,不會被修改。
6. 顯示摘要,輸入 `y` 後全自動:複製腳本到目標機器的私人暫存目錄、用 sudo 安裝設定、刪除暫存目錄。

你的電腦需要:`ldap-utils`(`sudo apt install ldap-utils`)、OpenSSH ≥ 8.4。不需要 root,**目標機器不需要 SSH 金鑰**。

### 密碼怎麼處理

- 所有密碼都是當下輸入,不寫進設定、不出現在命令列(`ps` 看不到)。
- SSH 透過 askpass 輔助程式從 600 暫存檔讀密碼;每台目標機器只建立一條連線、只認證一次,後續動作都共用。
- sudo 密碼用 `sudo -S` 從 stdin 給。
- 你電腦上的暫存目錄在結束時刪除(含中途失敗)。
- 第一次連某台目標機器會自動接受它的 host key 並印出指紋(`accept-new`)。

## 帳號:`scan_group`

查群組的帳號**同時是 sssd 平常查使用者用的 bind 帳號**,密碼會存在每台目標機器的 `/etc/sssd/sssd.conf`(600,只有 root 讀得到)。NAS 的 LDAP 不允許匿名查詢,所以需要這個帳號。

因為密碼會放在每台機器上,腳本會**拒絕**:

- `admin`
- 任何屬於群組的帳號(`Domain Users` 除外)

這樣就算某台目標機器被拿到 root,外流的密碼也只能讀使用者清單,登不進任何機器。

## 執行前必須先做

1. **在 NAS 建 `scan_group`**(LDAP 伺服器 → 使用者 → 新增),**不要勾任何群組**。
2. **目標機器自己要連得到 NAS:636**,而且之後每次有人登入都要連。
3. 目標機器的 sshd 要允許密碼登入(腳本不改 sshd)。腳本本身就是用密碼 SSH 登入目標機器,不允許的話檢查階段就會失敗並跳過。
4. 目標機器**不要有和 LDAP 使用者同名的本機帳號**(本機帳號優先,LDAP 的會被蓋掉)。腳本檢查階段會列出可登入群組成員中,哪些在目標機器有同名本機帳號(只警告,不跳過)。

## 群組建議

| 機器類型 | 可登入 | sudo |
|---|---|---|
| runner 機器 | `cluster-admins` | `cluster-admins` |
| 一般叢集節點 | `cluster-admins`, `cluster-users` | `cluster-admins` |
| GPU 機器 | `cluster-admins`, `gpu-users` | `cluster-admins` |
| K3s master | `cluster-admins` | `cluster-admins` |

`Domain Users`(所有人都在裡面)和名稱有空格的群組不會列出。

## 帶參數(跳過對應的問題,**密碼一律當下輸入,沒有密碼參數**)

```sh
bash install-sssd-ldap.sh --nas <SCAN_USER>@<NAS_IP> --domain <LDAP_DOMAIN> \
     --host <SSH_USER>@<HOST_IP>,<SSH_HOST_ALIAS> \
     --allow-groups cluster-admins --sudo-groups cluster-admins
```

| 參數 | 說明 |
|---|---|
| `--nas [SCAN_USER@]IP` | NAS 位址與查詢用的 LDAP 帳號。IP 可用 `~/.ssh/config` 的名稱(只取 `HostName`,**不取 ssh 的 `User`**,因為那是 NAS 本機帳號,不是 LDAP 帳號)。沒寫 SCAN_USER 會問,預設 `scan_group` |
| `--domain DOMAIN` | LDAP 網域(NAS「LDAP 伺服器」頁的「完整網域名稱」),base DN 由此推出 |
| `--host [SSH_USER@]IP` | 目標機器,可重複或用逗號分隔。IP 可用 `~/.ssh/config` 的名稱;沒寫 SSH_USER 時用 ssh 設定的 `User`,再沒有就是你的使用者名稱 |
| `--allow-groups LIST` | 可登入群組,跳過選單 |
| `--sudo-groups LIST` | sudo 群組(`""` = 不給),跳過選單 |

NAS 位址與網域**沒有寫死在腳本裡**,沒給參數就會詢問。

## 其他用法(在目標機器上直接執行)

```sh
bash install-sssd-ldap.sh install       # 同樣的問題,只裝這一台
bash install-sssd-ldap.sh check <使用者> # 唯讀檢查
```

## 移除

```sh
bash remove-sssd-ldap.sh --host <SSH_USER>@<HOST_IP>   # 在你的電腦執行,流程同安裝
sudo bash remove-sssd-ldap.sh here                      # 或在目標機器上直接執行
```

停用 sssd、還原 nsswitch、拿掉 sudo 設定、刪除 `sssd.conf`(含查詢帳號密碼)與 sssd 快取(含離線登入用的密碼雜湊)。套件與家目錄保留。

## 清除已刪除的 LDAP 使用者

NAS 上刪掉使用者後,目標機器上還會留著他的家目錄等東西:

```sh
bash cleanup-ldap-user.sh --user <LDAP 使用者> --host <SSH_USER>@<HOST_IP>
```

會先用查詢帳號確認這個使用者在 NAS 上已經刪除(還在就停止),再逐台列出要清的內容,重新輸入名稱確認後才刪。清除範圍同 `userdel -r`:執行中的程式、`/home/<使用者>`、mail spool、cron / at 排程、systemd linger、sssd 快取;其他地方屬於他的檔案不動。

## 腳本在目標機器上做了什麼

- 安裝 `sssd sssd-ldap sssd-tools libnss-sss libpam-sss ldap-utils`
- 寫 `/etc/sssd/sssd.conf`:`ldaps://NAS:636`、`ldap_schema = rfc2307`、`ou=people`/`ou=group`、`access_provider = simple` + `simple_allow_groups`、`default_shell = /bin/bash`、`min_id = 1000000`、`chpass_provider = none`
- `nsswitch.conf` 的 passwd/group/shadow 加 `sss`(先備份)
- `pam-auth-update --enable mkhomedir`(第一次登入自動建 `/home/<user>`)
- `/etc/sudoers.d/90-ldap-groups`(`visudo` 檢查過才寫入)
- 狀態與備份路徑記在 `/var/lib/install-sssd-ldap/state`,`remove-sssd-ldap.sh` 依此還原

## 已知限制

| 項目 | 說明 |
|---|---|
| 憑證不驗證 | NAS 憑證是自簽、沒有 SAN 時 `demand` 會失敗。預設 `allow`:**有加密,但不驗證對方身分** |
| host key | 第一次連線自動接受(`accept-new`),同網段可接受;之後 key 變了會拒絕 |
| 改密碼 | `chpass_provider = none`(節點上 `passwd` 不能改)。使用者自己到 NAS 網頁「登入與安全性 → 密碼」改，或管理員在 LDAP 伺服器頁改;節點登入馬上用新密碼 |
| SSH 公鑰 | NAS 的 LDAP schema 沒有 `ldapPublicKey`,公鑰放各機 `~/.ssh/authorized_keys` |
| sudo | NAS 的 LDAP schema 沒有 `sudoRole`,sudo 只能用各機 `sudoers.d` |
| 離線登入 | `cache_credentials = true`,NAS 斷線時曾登入過的人仍可登入;不要的話加 `--no-cache-credentials` |

---

# install-nas-folders

LDAP 使用者登入後,家目錄裡直接有 NAS 上的資料夾(NFS 4.1 即時存取,不是同步)。先跑過 `install-sssd-ldap.sh`,每台機器跑一次。

```sh
bash install-nas-folders.sh --nas <NAS_IP> --personal homes:nas-home --shared share:nas-share \
     --host <SSH_USER>@<HOST_IP>
```

| 參數 | 使用者看到的 | NAS 上 |
|---|---|---|
| `--personal homes:nas-home` | `~/nas-home`(只有本人能用,等於 NAS 網頁上的 home) | `homes/<使用者>`,使用者第一次登入 NAS 網頁時由 NAS 建立 |
| `--shared share:nas-share` | `~/nas-share`(大家共用) | `share` 本身,權限由 NAS 決定 |

兩種都可以重複指定,家目錄內路徑可以多層(例如 `work/nas`)。

`--personal <NAS 資料夾>:<家目錄內路徑>`:NAS 的 `homes` 掛在 `/mnt/nas/homes`(第一次存取時自動掛載)。LDAP 使用者(經由 sssd 取得、不在 `/etc/passwd` 的帳號,不看 UID 範圍)每次登入時:

- NAS 上沒有 `homes/<使用者>` 就試著用**該使用者的身分**建立(建立後設 700;root 在 NAS 端被 squash,不能代建)。NAS 的 `homes` 不讓一般使用者在最上層建立,所以實際上要等使用者先登入 NAS 網頁一次
- 建立連結 `~/nas-home -> /mnt/nas/homes/<使用者>`;已有同名檔案或資料夾就不動
- 資料夾擁有者不是本人時不建連結(記錄在 `journalctl -t nas-folders`)
- 已經建好連結的人登入時不碰 NAS;NAS 連不上時跳過(2 秒),下次登入再建,不會擋住登入

**用 NAS 的 `homes`(網頁上的 home 就等於 `~/nas-home`)**:`--personal homes:nas-home`。NAS 只在帳號第一次登入 NAS 時建立 `homes/<使用者>`(節點沒有權限代建),所以建好新帳號後要跑一次 `init-nas-home.sh`(或請他登入一次 NAS 網頁),節點的 `~/nas-home` 才會出現;在那之前登入節點,`journalctl -t nas-folders` 會有提示。

**撞號檢查**:NFS 只看編號。NAS 本機帳號用 uid 1000 起,群組 100 在 NAS 是 everyone、在 Ubuntu 是 users。安裝前若節點有 uid 1000–4999 的本機帳號,或群組 100 有成員,腳本會停止並提示:

```sh
sudo usermod -u 5000 <帳號>     # 帳號先登出;家目錄檔案會一起改
sudo gpasswd -d <帳號> users
```

**改對應**:再執行一次並給新的對應即可,同一個家目錄內路徑以新的為準;原本由腳本建立、指向 `/mnt/nas/` 下別處的連結,使用者下次登入時自動改指;不再使用的掛載會自動停用移除。

`--shared` 只在登入時建立連結 `~/nas-share -> /mnt/nas/share`,不用碰 NAS,NAS 斷線時也照樣建立。

再執行一次可以加新的資料夾(原本的保留)或換 NAS 位址;NAS 只改允許的 IP 時不用重跑。

## NAS 端要先做(網頁)

1. 建共用資料夾(`--personal` 用 NAS 內建的 `homes`,要先在控制台啟用家目錄;`--shared` 例如 `share`)
2. NFS 主機存取:開放這些機器,`sys`、讀寫、Squash 僅根使用者
3. `homes` 的屬性勾「目前僅允許管理者群組存取資源回收筒」(套用時檔案服務會短暫重啟),不然 `@Recycle` 經 NFS 所有人可讀寫
4. NAS 本機帳號的家目錄(例如 `homes/<管理員>`)拿掉群組 `everyone`(編號 100)那條;它可以穿過去進到 `.Qsync`,而 `.Qsync` 預設所有人可讀寫。`homes` 最上層的 ACL 網頁不能改,所以節點上 `ls /mnt/nas/homes` 會看到大家的名稱(進不去)
5. `--shared` 的資料夾:只給 `Domain Users`(所有 LDAP 使用者)讀寫,**刪掉預設的 Everyone**(獨立權限 → Windows 特殊權限;上方清單看不到它,預設是完整讀寫)

## 目標機器上做了什麼

- 安裝 `nfs-common`
- `/etc/fstab` 加一段 `# BEGIN nas-folders` … `# END nas-folders`(`nfs4 vers=4.1,hard,_netdev,nofail,x-systemd.automount`)
- `/etc/nas-folders.conf`:對應設定
- `/usr/local/sbin/nas-folders-login` + `/usr/share/pam-configs/nas-folders`(`pam_exec`,排在 mkhomedir 之後)

```sh
bash install-nas-folders.sh check <使用者>   # 在目標機器上唯讀檢查
```

## 移除

```sh
bash remove-nas-folders.sh --host <SSH_USER>@<HOST_IP>
sudo bash remove-nas-folders.sh here
```

停用 PAM 設定、卸載並移除 fstab 段落、刪除家目錄裡指向 `/mnt/nas/` 的連結。**NAS 上的資料不動**,`nfs-common` 保留。

---

# fix-local-uid

NFS(sec=sys)只看編號。NAS 本機帳號用 uid 1000 起,群組 100 是 everyone;Ubuntu 第一個帳號也是 uid 1000,而且會加入群組 100(users)。不改的話,節點的本機帳號經 NFS 會被 NAS 當成 NAS 上的本機帳號(例如管理員)。這支把撞號的本機帳號改號,`install-nas-folders.sh` 遇到撞號會停下來並提示用它。

```sh
bash fix-local-uid.sh --host <LDAP_USER>@<HOST_IP>   # 在你的電腦執行
sudo bash fix-local-uid.sh here                        # 或在目標機器上直接執行
bash fix-local-uid.sh check                            # 唯讀,只列出撞號的帳號
```

- 對象:`/etc/passwd` 裡 uid 1000–4999 的帳號,改成 5000 起沒用過的編號(`--uid` 可改起點);群組 100 的成員移出該群組;主要群組(`id -g`)是 100 或 0 的帳號,改成自己的同名群組(沒有就建立,家目錄裡舊群組的檔案一起改)
- 每個帳號:強制登出、`usermod -u`(家目錄一起改)、本地可寫磁碟上屬於舊編號的檔案改擁有者、linger 保留;改不了的檔案只警告
- 之後新增的本機帳號也從 5000 起、不加入群組 100:`/etc/login.defs` 的 `UID_MIN`、`GID_MIN`(`useradd` 用),`/etc/adduser.conf` 的 `FIRST_UID`、`FIRST_GID`、`USERS_GID=-1`(`adduser` 用,兩個都要改)。原檔第一次修改前備份成 `<檔名>.bak-fix-local-uid`;已經設好或設得更大就不動
- **登入用的帳號不能是要改號的帳號**(例如不能用本機管理員改它自己),請用另一個有 sudo 的帳號,例如有 sudo 的 LDAP 帳號

## 新節點的順序

先在 NAS 網頁把新節點的 IP 加進 `homes`、`share` 的 NFS 主機存取,然後一次跑完:

```sh
bash install-all.sh --nas <NAS_IP> --domain <LDAP_DOMAIN> \
     --host <LOCAL_ADMIN>@<HOST_IP> --ldap-admin <LDAP_USER>
```

`install-all.sh` 依序執行下面三支(也可以分開跑)。密碼在開頭一次問完(查詢帳號 `scan_group`、每台的本機管理員、`--ldap-admin` 的 LDAP 帳號),放在 700 暫存資料夾給三支共用,結束時刪除;`-y` 讓所有確認自動回答 y;中途失敗修好後用 `--from N` 從第 N 步續跑:

1. `install-sssd-ldap.sh`:用本機管理員登入(這時還沒有 LDAP)
2. `fix-local-uid.sh`:用有 sudo 的 LDAP 帳號登入(不能用要改號的帳號改自己)
3. `install-nas-folders.sh`:用同一個 LDAP 帳號登入,預設 `--personal homes:nas-home --shared share:nas-share`

---

# init-nas-home

新建的 LDAP 帳號,NAS 要等它第一次登入 NAS 才會建 `homes/<帳號>`。這支用該帳號的初始密碼透過 NAS 網頁的登入 API 登入一次、確認家目錄、再登出,不改任何 NAS 設定,也不碰節點:

```sh
bash init-nas-home.sh --nas <NAS_IP> --user <帳號>     # 可重複或用逗號 a,b,c
```

密碼執行時輸入。「控制台 → 使用者 → 進階設定 → 使用者家目錄」必須啟用(重新套用這個設定不會替 LDAP 帳號建家目錄,實測過)。

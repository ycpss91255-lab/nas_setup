# syslog:節點紀錄集中到 NAS

節點把重要的系統紀錄即時送到 NAS 的 Syslog 伺服器，節點壞掉或被動過時，紀錄還在 NAS 上。

送出的紀錄:

| 類別 | 內容 | 等級 |
|---|---|---|
| auth、authpriv | SSH 登入、sudo、su | 全部 |
| kern | 系統核心 | 全部 |
| 其他程式 | — | warning 以上 |

- 用 TCP 傳送。
- NAS 連不上時，先暫存在節點的 `/var/spool/rsyslog`(最多 200 MB),連回來後自動補送。
- 同時把節點時區設成 `Asia/Taipei`(`--timezone` 可改,`none` = 不改),紀錄時間才會一致。

## NAS 端(網頁，只做一次)

1. **共用資料夾**:建立 `syslog`。
   - 放在 HDD 鏡像的儲存池，精簡配置，設配額上限(例如 20 GB)。
   - 權限只給管理員。
   - 屬性：不開資源回收筒、隱藏網路磁碟。
   - 獨立權限 → Windows 特殊權限：刪掉預設的 Everyone(它在畫面上方清單看不到，但權限是完整讀寫)。
2. **Syslog 伺服器**:控制台 → 應用服務 → Syslog 伺服器。
   - 啟用。
   - 只開 TCP(埠 514),關掉 UDP。
   - 記錄檔放在 `syslog / messages`。

3. **寄信通知**(選用):同一頁「電子郵件通知」→ 啟用，嚴重性選 **Err**。節點有 Err 以上的紀錄(硬碟讀寫錯誤、服務啟動失敗等)就寄信。
   - NAS 不是收到就馬上寄，會定期批次寄出。
   - NAS 的 Syslog 伺服器重新啟動時，節點會記一筆「remote server closed connection」(Err),所以每次改 Syslog 設定都會收到一封信，屬正常。

紀錄檔到 50 MB 會改名成 `messages_日期` 另存，**舊檔不會自動刪除**。資料夾的配額滿了就要手動清掉舊檔。

## 節點端

在你的電腦執行:

```sh
bash install-syslog.sh --nas <NAS_IP> --host <SSH_USER>@<HOST_IP>
```

- 登入的帳號要能 sudo。
- 多台機器:`--host a@IP1,a@IP2`。
- 跑完會送出一則測試紀錄，可以到 NAS 的 Syslog 檢視器確認。

在節點上檢查狀態:

```sh
bash install-syslog.sh check
```

移除(停止送紀錄;rsyslog 和 NAS 上已收到的紀錄都保留):

```sh
bash remove-syslog.sh --host <SSH_USER>@<HOST_IP>
```

## 腳本做了什麼

- 沒有 rsyslog 就先安裝。
- 只寫一個檔案:`/etc/rsyslog.d/90-nas-syslog.conf`。移除時也只刪這個檔和暫存佇列。
- 寫入後先用 `rsyslogd -N1` 檢查。檢查沒過就還原，不會把節點本身的紀錄弄壞。
- 重跑時設定沒變就不會修改。

## 看紀錄

- **NAS 網頁**:Syslog 伺服器 → Syslog 檢視器。
- **SSH 到 NAS**:`/share/<磁碟區>/syslog/messages`,用 `grep 主機名稱` 篩選某台節點。

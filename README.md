# nas_setup

NAS 相關的設定流程與腳本。以 QNAP(QuTS hero)為主，搭配 Debian / Ubuntu 節點。

## 內容

| 目錄 | 用途 |
|---|---|
| [`ldap/`](ldap/) | NAS 內建 LDAP 給節點登入、節點家目錄裡的 NAS 資料夾(NFS) |
| [`syslog/`](syslog/) | 節點重要的系統紀錄(登入、sudo、警告以上)集中送到 NAS |

之後會加入 VPN 等其他設定。

## syslog

- 說明與用法:[syslog/README.md](syslog/README.md)

## ldap

- 操作流程：[ldap/WORKFLOW.md](ldap/WORKFLOW.md)(init、add_user、del_user、remove)
- 腳本說明：[ldap/README.md](ldap/README.md)

腳本都在自己的電腦上執行，透過 SSH 設定目標機器;密碼在執行時輸入，不會存下來。

## 授權

[Apache-2.0](LICENSE)

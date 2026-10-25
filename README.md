# rdp-firefox

用 Windows 內建的「遠端桌面連線」（RDP）登入，畫面上就是一個全螢幕的 Firefox。映像檔以 Alpine Linux 為基底，設計給 Kubernetes 上多人同時使用：每個人都有自己獨立的桌面，互不影響。

![登入後的 Firefox](docs/images/03-firefox.png)

## 簡述

- **用戶端免安裝**：Windows 內建的遠端桌面連線即可，不需要 VNC 或任何外掛
- **多人互不影響**：同一個帳號可多人同時登入，每條連線都有自己的桌面、Firefox、下載目錄與終端機（預設上限 4 個桌面）
- **中文**：在 Windows 用自己的輸入法打好，複製後在 Firefox 按 `Ctrl+V` 貼上
- **Web 終端機**：在 Firefox 開 `http://localhost:2200`（bash）或 `http://localhost:2210`（SSH），只能從桌面內開啟
- **安全**：密碼於啟動時設定、不寫進映像檔；每個容器自己產生 TLS 憑證；xrdp 降權執行；斷線的桌面 2 分鐘後自動回收

本 branch：**v3.2**（不含 session 分享）。`k8s-firefox-rdp.yaml` 預設使用 `ghcr.io/braveantony/rdp-firefox:3.2`。需要分享桌面功能請用 [`main`](https://github.com/braveantony/rdp-firefox)（`:3.4-share`）。

## 快速開始

### Kubernetes

```bash
kubectl create namespace web-workspace
kubectl -n web-workspace create secret generic firefox-rdp-auth --from-literal=password='bigred'
kubectl apply -f https://raw.githubusercontent.com/braveantony/rdp-firefox/release/3.2/k8s-firefox-rdp.yaml
kubectl -n web-workspace rollout status deploy/firefox-rdp
```

用遠端桌面連線到 `<節點 IP>:30389`，帳號 `bigred`、密碼為上面 Secret 設定的值。

- 節點需要能連到 `ghcr.io` 下載映像檔（約 800 MB）。無法上網的叢集，請在主機上 `podman pull` 後匯入各節點，方法見 [build-image.md](build-image.md) 附錄 A-1。
- 讓區網的 Windows 直接用主機 IP 連線（不用記 NodePort），見 [build-image.md](build-image.md) 附錄 A-4。

### 單機（podman 或 docker）

```bash
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/rdp-firefox:3.2
```

用遠端桌面連線到 `<主機 IP>:13389`。

## 怎麼用

### 1. 登入

按 `Win+R` 輸入 `mstsc` 開啟遠端桌面連線，連到上面的位址。出現憑證警告時按「是」（每個容器使用自己產生的憑證）。接著會看到 xrdp 登入畫面：Session 保持 `Xorg`，輸入帳號密碼後按 OK。

![xrdp 登入畫面](docs/images/01-login.png)

### 2. 使用 Firefox

登入後畫面上只有全螢幕的 Firefox。關掉它會在 1 秒內自動重開；解析度跟著遠端桌面視窗大小。中文請在 Windows 打好後複製，再到 Firefox 按 `Ctrl+V`。下載檔案時會詢問儲存位置。

> 每條連線都是獨立的新桌面：斷線後無法接回，原本的分頁與下載的檔案會在 2 分鐘後清除。

### 3. Web 終端機

在 Firefox 網址列輸入 `localhost:2200` 就是 bash 終端機（身分 `bigred`），`localhost:2210` 則直接 SSH 到 `SSH_TARGET`（預設 `tkadm.taroko`）。每個分頁都是獨立的終端機，關掉即清除。

![localhost:2200 終端機](docs/images/04-terminal.png)

> 截圖取自 v3.4-share，v3.2 的登入、Firefox 與終端機畫面相同。

## 文件

- [build-image.md](build-image.md)：從零建置 v3.2 映像檔，並部署到 Kubernetes（tk8s）的完整步驟，可由上到下複製貼上執行

## 環境變數

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `RDP_PASSWORD` | （必填） | 登入密碼；Kubernetes 上由 Secret `firefox-rdp-auth` 提供 |
| `RDP_USER` | `bigred` | 登入帳號（UID 1000），不可為 `root` 或 `xrdp` |
| `MAX_SESSIONS` | `4` | 同時桌面數上限 |
| `SSH_TARGET` | `tkadm.taroko` | `localhost:2210` 終端機的 SSH 目標 |

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `Dockerfile` | 映像檔定義（基底 `alpine:3.22`） |
| `rootfs/` | 複製進映像檔 `/` 的設定檔與腳本 |
| `k8s-firefox-rdp.yaml` | Kubernetes Deployment 與 NodePort Service（30389），預設使用 ghcr 映像檔 |
| `docs/images/` | README 截圖 |

## 授權

[MIT License](LICENSE)

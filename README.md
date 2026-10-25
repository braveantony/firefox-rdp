# rdp-firefox

用 Windows 遠端桌面（RDP）登入，就是一個全螢幕 Firefox。支援多人同時使用：每人各有獨立桌面，也能分享給別人觀看或共同操作。

## 簡述

- **用戶端免安裝**：Windows 內建的遠端桌面連線即可，不需要 VNC 或任何外掛
- **多人互不影響**：同一個帳號可多人同時登入，每條連線都有自己的桌面、Firefox、下載目錄與終端機（預設上限 4 個桌面）
- **中文**：在 Windows 用自己的輸入法打好，複製後在 Firefox 按 `Ctrl+V` 貼上
- **Web 終端機**：在 Firefox 開 `http://localhost:2200`（bash）或 `http://localhost:2210`（SSH），只能從桌面內開啟
- **Session 分享**（`:3.4-share`）：登入後顯示操作 PIN 與唯讀 PIN，別人輸入 PIN 即可加入你的桌面
- **安全**：密碼於啟動時設定、不寫進映像檔；每個 container 自己產生 TLS 憑證；xrdp 降權執行；斷線的桌面 2 分鐘後自動回收

## 快速開始

### Kubernetes

```bash
kubectl create namespace web-workspace
kubectl -n web-workspace create secret generic firefox-rdp-auth --from-literal=password='bigred'
kubectl apply -f https://raw.githubusercontent.com/braveantony/rdp-firefox/main/k8s-firefox-rdp.yaml
kubectl -n web-workspace rollout status deploy/firefox-rdp
```

用遠端桌面連線到 `<節點 IP>:30389`，帳號 `bigred`、密碼為上面 Secret 設定的值。

- 節點需要能連到 `ghcr.io` 下載映像檔（約 1 GB）。無法上網的叢集，請在主機上 `podman pull` 後匯入各節點，方法見 [build-image-v3.4.md](build-image-v3.4.md) 附錄 A-1。
- 不需要分享功能時，把 YAML 的 `image:` 改成 `ghcr.io/braveantony/rdp-firefox:3.2`。
- 讓區網的 Windows 直接用主機 IP 連線（不用記 NodePort），見 [build-image-v3.4.md](build-image-v3.4.md) 附錄 A-4。

### 單機（podman 或 docker）

```bash
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/rdp-firefox:3.4-share
```

用遠端桌面連線到 `<主機 IP>:13389`。

## 怎麼用

### 1. 登入

按 `Win+R` 輸入 `mstsc` 開啟遠端桌面連線，連到上面的位址。出現憑證警告時按「是」（每個 container 使用自己產生的憑證）。接著會看到 xrdp 登入畫面：Session 保持 `Xorg`，輸入帳號密碼後按 OK。

![xrdp 登入畫面](docs/images/01-login.png)

### 2. 使用 Firefox

登入後畫面上只有全螢幕的 Firefox。關掉它會在 1 秒內自動重開；解析度跟著遠端桌面視窗大小。中文請在 Windows 打好後複製，再到 Firefox 按 `Ctrl+V`。下載檔案時會詢問儲存位置。

![全螢幕的 Firefox](docs/images/03-firefox.png)

> 每條連線都是獨立的新桌面：斷線後無法接回，原本的分頁與下載的檔案會在 2 分鐘後清除。

### 3. Web 終端機

在 Firefox 網址列輸入 `localhost:2200` 就是 bash 終端機（身分 `bigred`），`localhost:2210` 則直接 SSH 到 `SSH_TARGET`（預設 `tkadm.taroko`）。每個分頁都是獨立的終端機，關掉即清除。

![localhost:2200 終端機](docs/images/04-terminal.png)

### 4. 分享你的桌面（`:3.4-share`）

登入約 2 秒後，畫面中央會出現這個桌面的**編號**、**操作 PIN**（可以操作）與**唯讀 PIN**（只能看）。把要給的 PIN 告訴對方即可。視窗關掉後按 `Ctrl+Alt+S` 可再叫出；**開始分享前請先關掉這個視窗**，以免加入者看到操作 PIN。

![分享 PIN 視窗](docs/images/02-share-popup.png)

### 5. 加入別人的桌面

1. 一樣用遠端桌面連線到同一個位址，出現 xrdp 登入畫面。
2. **Session** 改選 `join<編號>`（例如 `join10`），可用滑鼠選或按 `↓` 鍵。

   ![Session 選 join10](docs/images/05-join-select.png)

3. 表單只剩 **password** 一欄，填入對方給的 PIN，按 OK。

   ![填入 PIN](docs/images/06-join-pin.png)

4. 加入後就看到對方的畫面：用唯讀 PIN 時所有輸入都無效，用操作 PIN 時可以一起操作（滑鼠鍵盤與對方共用）。

   ![加入後看到對方的畫面](docs/images/07-joined-view.png)

> 不要在 username 填 `join10\bigred` 之類的名稱：Session 仍是 `Xorg` 時會被當成帳號而登入失敗。

## 版本比較

| | v3.2 | v3.4-share |
| --- | --- | --- |
| 映像檔 | `ghcr.io/braveantony/rdp-firefox:3.2` | `ghcr.io/braveantony/rdp-firefox:3.4-share` |
| 多人同帳號同時登入、各自獨立桌面 | ✅ | ✅ |
| localhost:2200／2210 Web 終端機 | ✅ | ✅ |
| 分享自己的桌面（操作 PIN／唯讀 PIN） | — | ✅ |
| 映像檔大小 | 約 790 MB | 約 1.04 GB |
| 原始碼 | branch [`release/3.2`](../../tree/release/3.2) | branch [`release/3.4-share`](../../tree/release/3.4-share)（= `main`） |

本 branch 的 Dockerfile 用建置參數 `SESSION_SHARE` 區分是否加入分享功能：`SESSION_SHARE=1` 建出 `:3.4-share`；`SESSION_SHARE=0`（預設）建出不含分享功能的 `:3.4`，功能與 v3.2 相同，沒有另外發布映像檔。各版本的差異說明見 [Releases](../../releases)。

## 文件

- [user-guide.md](user-guide.md)：使用手冊（連線登入、Firefox 與中文、終端機、多人使用、分享與加入桌面、常見問題）
- [build-image-v3.4.md](build-image-v3.4.md)：從零建置 `:3.4` 與 `:3.4-share`，並部署到 Kubernetes（tk8s）的完整步驟
- [build-image.md](build-image.md)：v3.2（只有多人獨立 session）的建置步驟

## 環境變數

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `RDP_PASSWORD` | （必填） | 登入密碼；Kubernetes 上由 Secret `firefox-rdp-auth` 提供 |
| `RDP_USER` | `bigred` | 登入帳號（UID 1000），不可為 `root` 或 `xrdp` |
| `MAX_SESSIONS` | `4` | 同時桌面數上限；加入別人桌面的連線不佔名額 |
| `SSH_TARGET` | `tkadm.taroko` | `localhost:2210` 終端機的 SSH 目標 |

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `Dockerfile` | 映像檔定義（基底 `alpine:3.22`；`SESSION_SHARE=1` 時加裝 session 分享） |
| `rootfs/` | 兩個 tag 都會複製進映像檔 `/` 的設定檔與腳本 |
| `rootfs-share/` | 只有 `:3.4-share` 會套用的分享功能檔案 |
| `k8s-firefox-rdp.yaml` | Kubernetes Deployment 與 NodePort Service（30389），預設使用 ghcr 映像檔 |
| `docs/images/` | README 截圖 |

## 授權

[MIT License](LICENSE)

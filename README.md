# rdp-firefox

用 Windows 遠端桌面（RDP）登入，就是一個全螢幕 Firefox。支援多人同時使用：每人各有獨立桌面，也能分享給別人觀看或共同操作。

## 簡述

- **零安裝、即連即用**：Windows 內建遠端桌面一鍵連線，免裝任何用戶端或外掛，登入即是全螢幕 Firefox
- **多人並行、彼此隔離**：多個帳號、甚至同一帳號都能多人同時登入，每條連線各自擁有專屬的桌面、瀏覽器、下載目錄與終端機，互不干擾
- **一行指令完成部署**：`curl | bash` 即裝即用；帳號清單收進 Secret，以 Kustomize 宣告式管理，改名單就自動滾動更新
- **中文輸入無縫接軌**：沿用 Windows 本機輸入法，透過剪貼簿直接貼入 Firefox
- **瀏覽器即終端機**：在 Firefox 開啟 `localhost:2200`（bash）或 `localhost:2210`（SSH），維運操作一站完成，且僅限桌面內存取
- **即時協作、權限分明**（`-share` 版）：一組 PIN 即可邀請他人加入你的桌面，唯讀觀摩或共同操作由你決定
- **叢集內的 Web 驗證站**：Firefox 身處 Kubernetes 叢集之中，以 `http://<service>.<namespace>` 即可驗證叢集內的 Web 應用，免裝 MetalLB 或 kube-vip，也無需對外暴露服務

## 快速開始

### Kubernetes

```bash
curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-firefox/main/install.sh | bash
```

腳本用目前的 kubeconfig 部署到 namespace `web-workspace`，完成後印出連線位址。用遠端桌面連線到 `<節點 IP>:30389`，帳號 `bigred`、密碼 `bigred`。

- 要多個帳號或改密碼，請改用下方的 [進階：多個帳號（Kustomize）](#進階多個帳號kustomize)。
- 節點需要能連到 `ghcr.io` 下載映像檔（約 1 GB）。
- 讓區網的 Windows 直接用主機 IP 連線（不用記 NodePort），見 [build-image-v3.4.md](docs/build-image-v3.4.md) 附錄 A-4。
- 移除：`kubectl delete namespace web-workspace`

### 單機（podman 或 docker）

```bash
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/rdp-firefox:3.5-share
```

用遠端桌面連線到 `<主機 IP>:13389`，帳號密碼同為 `bigred`。

## 怎麼用

### 1. 登入

按 `Win+R` 輸入 `mstsc` 開啟遠端桌面連線，連到上面的位址。出現憑證警告時按「是」（每個 container 使用自己產生的憑證）。接著會看到 xrdp 登入畫面：Session 保持 `Xorg`，輸入帳號密碼後按 OK。

![xrdp 登入畫面](docs/images/01-login.png)

### 2. 使用 Firefox

登入後畫面上只有全螢幕的 Firefox。關掉它會在 1 秒內自動重開；解析度跟著遠端桌面視窗大小。中文請在 Windows 打好後複製，再到 Firefox 按 `Ctrl+V`。下載檔案時會詢問儲存位置。

![全螢幕的 Firefox](docs/images/03-firefox.png)

> 每條連線都是獨立的新桌面：斷線後無法接回，原本的分頁與下載的檔案會在 2 分鐘後清除。

### 3. Web 終端機

在 Firefox 網址列輸入 `localhost:2200` 就是 bash 終端機，`localhost:2210` 則直接 SSH 到 `SSH_TARGET`（預設 `tkadm.taroko`）。每個分頁都是獨立的終端機，關掉即清除。

只設定一個帳號時，`localhost:2200` 直接以該帳號開啟 bash；設定多個帳號時，會先出現 `login:` 提示，輸入自己的帳號密碼後才進入 bash，避免以別人的身分操作。

![localhost:2200 終端機](docs/images/04-terminal.png)

### 4. 分享你的桌面（`-share` 版）

登入約 2 秒後，畫面中央會出現這個桌面的**編號**、**操作 PIN**（可以操作）與**唯讀 PIN**（只能看）。把要給的 PIN 告訴對方即可。視窗關掉後按 `Ctrl+Alt+S` 可再叫出；**開始分享前請先關掉這個視窗**，以免加入者看到操作 PIN。

![分享 PIN 視窗](docs/images/02-share-popup.png)

### 5. 加入別人的桌面

1. 一樣用遠端桌面連線到同一個位址，出現 xrdp 登入畫面。
2. **Session** 改選 `join<編號>`（例如 `join10`），可用滑鼠選或按 `↓` 鍵。

   ![Session 選 join10](docs/images/05-join-select.png)

3. 表單只剩 **password** 一欄，填入對方給的 PIN，按 OK。

   ![填入 PIN](docs/images/06-join-pin.png)

4. 加入後就看到對方的畫面：用唯讀 PIN 時所有輸入都無效，用操作 PIN 時可以一起操作（滑鼠鍵盤與對方共用）。分享不限帳號：任何人只要拿到 PIN 都能加入。

   ![加入後看到對方的畫面](docs/images/07-joined-view.png)

> 不要在 username 填 `join10\bigred` 之類的名稱：Session 仍是 `Xorg` 時會被當成帳號而登入失敗。

## 進階：多個帳號（Kustomize）

帳號清單寫在 `users.txt`，由 Kustomize 的 `secretGenerator` 產生 Secret，掛載到 container 的 `/etc/firefox-rdp/users`。

```bash
git clone https://github.com/braveantony/rdp-firefox.git
cd rdp-firefox
vi manifests/multi-user/users.txt
kubectl apply -k manifests/multi-user
kubectl -n web-workspace rollout status deploy/firefox-rdp
```

`users.txt` 一行一個 `帳號:密碼`，`#` 開頭為註解：

```text
alice:Alice-pw
bob:Bob-pw
```

- 帳號規則：小寫英文字母或 `_` 開頭，可用小寫英數字、`_`、`-`，最長 32 字元，不可為 `root`、`xrdp`、`webterm`；密碼不可空白，可以包含冒號。不符規則時 pod 會啟動失敗，原因寫在 `kubectl logs` 裡。
- 修改 `users.txt` 後再 `kubectl apply -k manifests/multi-user` 即可：Secret 名稱帶內容雜湊（`firefox-rdp-users-<雜湊>`），名單有變就會自動重建 pod。
- 每個帳號各有自己的桌面與家目錄；設定多個帳號時，`localhost:2200` 會先要求登入。
- 已用快速開始安裝過也沒關係，直接 apply 即會改用新的名單；之後不要再執行 `install.sh`，否則會換回只有 bigred/bigred。
- 要換映像檔（例如無法上網的叢集改用私有 registry，或改用不含分享功能的 `:3.2`），在 `manifests/multi-user/kustomization.yaml` 的 `images:` 設定 `newName`／`newTag`。
- `users.txt` 含明文密碼，請勿提交到公開的 repo；可改用 SOPS、Sealed Secrets 等工具管理。
- 單機使用時，把帳號檔案掛載進去即可：`-v ./users.txt:/etc/firefox-rdp/users:ro,Z`（取代 `RDP_USER`／`RDP_PASSWORD`）。

## 版本比較

| | v3.2 | v3.4-share | v3.5-share |
| --- | --- | --- | --- |
| 映像檔 | `ghcr.io/braveantony/rdp-firefox:3.2` | `ghcr.io/braveantony/rdp-firefox:3.4-share` | `ghcr.io/braveantony/rdp-firefox:3.5-share` |
| 同一帳號多人同時登入、各自獨立桌面 | ✅ | ✅ | ✅ |
| localhost:2200／2210 Web 終端機 | ✅ | ✅ | ✅ |
| 分享自己的桌面（操作 PIN／唯讀 PIN） | — | ✅ | ✅ |
| 多個帳號（Secret 帳號檔案） | — | — | ✅ |
| `curl \| bash` 安裝、Kustomize 部署 | — | — | ✅ |
| 映像檔大小 | 約 790 MB | 約 1.04 GB | 約 1.04 GB |
| 原始碼 | branch [`release/3.2`](../../tree/release/3.2) | branch [`release/3.4-share`](../../tree/release/3.4-share) | branch [`release/3.5-share`](../../tree/release/3.5-share)（= `main`） |

`images/rdp-firefox/Dockerfile` 用建置參數 `SESSION_SHARE` 區分是否加入分享功能：`SESSION_SHARE=1` 建出 `-share` 版；`SESSION_SHARE=0`（預設）建出不含分享功能的版本，沒有另外發布映像檔。各版本的差異說明見 [Releases](../../releases)。

## 文件

- [user-guide.md](docs/user-guide.md)：使用手冊（連線登入、Firefox 與中文、終端機、多人使用、分享與加入桌面、常見問題）
- [build-image-v3.4.md](docs/build-image-v3.4.md)：從零建置 `:3.4` 與 `:3.4-share`，並部署到 Kubernetes（tk8s）的完整步驟
- [build-image.md](docs/build-image.md)：v3.2（只有多人獨立 session）的建置步驟

## 環境變數

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `USERS_FILE` | `/etc/firefox-rdp/users` | 帳號檔案，一行一個 `帳號:密碼`；Kubernetes 上由 Secret `firefox-rdp-users-*` 掛載。檔案存在時忽略下面兩個變數 |
| `RDP_USER` | `bigred` | 沒有帳號檔案時的登入帳號（UID 1000） |
| `RDP_PASSWORD` | — | 沒有帳號檔案時的登入密碼（此時必填） |
| `MAX_SESSIONS` | `4` | 同時桌面數上限；加入別人桌面的連線不佔名額 |
| `SSH_TARGET` | `tkadm.taroko` | `localhost:2210` 終端機的 SSH 目標 |

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `VERSION` | 目前版本 |
| `images/rdp-firefox/Dockerfile` | 映像檔定義（基底 `alpine:3.22`；`SESSION_SHARE=1` 時加裝 session 分享） |
| `images/rdp-firefox/rootfs/` | 所有版本都會複製進映像檔 `/` 的設定檔與腳本 |
| `images/rdp-firefox/rootfs-share/` | 只有 `-share` 版會套用的分享功能檔案 |
| `install.sh` | 快速開始的 `curl \| bash` 安裝腳本（帳號 bigred/bigred） |
| `manifests/base/` | Kustomize base：Namespace、Deployment、NodePort Service（30389） |
| `manifests/multi-user/` | 多帳號 overlay：`users.txt` 帳號清單產生 Secret |
| `docs/` | 使用手冊、建置文件與 README 截圖（`docs/images/`） |
| `test/e2e/` | 在臨時 kind 叢集上的端到端驗證腳本 |

## 授權

[MIT License](LICENSE)

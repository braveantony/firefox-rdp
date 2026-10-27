# rdp-firefox 系統運作架構

適用映像檔：`ghcr.io/braveantony/rdp-firefox:3.7-share`

![rdp-firefox 系統運作架構](architecture/rdp-firefox-architecture.png)

圖中的編號、顏色與下文對應。架構圖的原始檔與重製方式見 [architecture/README.md](architecture/README.md)。

## 連線路徑（粗藍線）

1. 使用者在 Windows 用「遠端桌面連線」（`mstsc`），或在 Mac 用 Windows App，以 **RDP** 連到叢集任一節點的 **NodePort `30389`**（Kubernetes 在每個節點上開放的固定埠號）。
2. NodePort 屬於 namespace（Kubernetes 用來分組資源的名稱空間）`web-workspace` 的 **Service `firefox-rdp`**，它把 30389 轉到 Pod 的 **3389** 埠。你連的節點不一定是 Pod 所在的節點，Kubernetes 會自動轉送過去。
3. 連線進入 **rdp-firefox Pod**。登入後，使用者看到的就是全螢幕的 Firefox 瀏覽器。

## Pod 內部

Pod 只有**一個 container `desktop`**，也就是圖中的虛線框。框內的方塊代表這個 container 裡的 **process**（執行中的程式）或 **session**（由一組 process 組成的桌面工作階段，即 ②），分成兩批啟動：

- **container 啟動時**：由 `tini`（container 裡第一個啟動的小程式，負責啟動和回收其他程式）執行 `/opt/desktop/entrypoint.sh`，啟動 ①、④、⑤。
- **使用者登入時**：由 xrdp-sesman 執行 `/etc/xrdp/startwm.sh`，啟動 ② 和 ③。

xrdp、xrdp-sesman 或任一個 ttyd 結束時，container 就會停止，由 Kubernetes 重啟；Firefox 被關掉時則會在桌面裡自動重開，不影響 container。

| # | process | 職責 |
| --- | --- | --- |
| ① | **xrdp** `:3389`／**xrdp-sesman** | RDP 入口。xrdp 接收連線並顯示登入畫面；在登入畫面的 **Session** 欄選 **Xorg** 時，由 xrdp-sesman 用 PAM（Linux 的帳號密碼驗證機制）驗證帳號，再開一個新桌面（②）。選 **join10～19**（`-share` 版）時，xrdp 改以 VNC 連到 ③，PIN 由 ③ 驗證 |
| ② | **Xorg session × N** | 每次以 Xorg 登入就開一個 session（一個獨立的桌面，有自己的 Xorg 畫面伺服器），同一帳號登入兩次也是兩個桌面；join 分享連線則加入既有桌面，不另開 session。上限為 `MAX_SESSIONS`（預設 4）。桌面裡跑 openbox（視窗管理程式）、fcitx5 新酷音（注音輸入）與**全螢幕 Firefox**。斷線後無法接回，桌面連同分頁、下載的檔案會在 2 分鐘後清除 |
| ③ | **x0vncserver × N** `127.0.0.1:59xx` | 用 VNC（另一種遠端桌面協定）把桌面分享出去（`-share` 版）。每個桌面各一個，埠號是 59 加上桌面編號，例如桌面 10 用 5910。其他人在登入畫面選 `join<編號>`（編號就是分享者畫面上顯示的桌面編號）：輸入操作 PIN 可共同操作，輸入唯讀 PIN 只能觀看 |
| ④ | **ttyd** `:2200` | Web 終端機（bash）。只設定一個帳號時直接進入該帳號，家目錄是暫時的，關掉分頁就刪除；設定多個帳號時先要求登入，使用該帳號的家目錄，檔案會保留 |
| ⑤ | **ttyd** `:2210` | Web 終端機（SSH 到 tkadm）。只設定一個帳號時以同名帳號登入；設定多個帳號時先詢問要用 SSH 目標上的哪個帳號 |

## 其他連線

- **綠線（HTTP／SSH）**
  - 在 Firefox 開啟 `http://localhost:2200` 或 `http://localhost:2210`，分別連到 ④ 或 ⑤。
  - ttyd 只監聽 loopback（127.0.0.1，只有 Pod 裡面連得到），Pod 以外都連不到；`-O` 會檢查連向 ttyd 的 WebSocket（Web 終端機用來即時收發資料的連線）來源，拒絕來自其他網站網頁的連線。
  - ⑤ 以 SSH 連到 namespace `taroko` 的**叢集管理 Pod tkadm**（`tkadm.taroko:22100`），在那裡用 kubectl 管理叢集。tkadm 需另外部署，本 repo 不提供。
  - `SSH_TARGET` 預設為 `tkadm.taroko`；映像檔內建 `/etc/ssh/ssh_config.d/tkadm.conf`，連 tkadm 時會自動使用 22100 埠，不必另外指定埠號。
- **紫線（PIN 分享）**：① 收到 join 連線後轉給 ③，③ 驗證 PIN，再把 ② 的畫面傳給加入者。
- **金線（帳號）**
  - Secret（Kubernetes 存放密碼等敏感資料的物件）`firefox-rdp-users-<雜湊>` 以唯讀方式掛載到 `/etc/firefox-rdp/users`，每行一個 `帳號:密碼`。
  - container 啟動時，`entrypoint.sh` 依這個檔案建立登入帳號（UID，也就是 Linux 帳號的數字編號，從 1000 起），① 的 xrdp-sesman 用這些帳號驗證登入。

## 安全邊界

- 叢集外只有 NodePort `30389`（RDP）一個入口。
- ttyd（2200、2210）與 VNC（59xx）都只監聽 Pod 內的 loopback。
- 接收 RDP 連線的 xrdp 以無權限的 `xrdp` 帳號執行；xrdp-sesman 需要驗證帳號、切換成登入者，仍以 root 執行；Xorg、Firefox 以登入者的身分執行。
- tkadm 的 kubeconfig 留在叢集內，不必流出到用戶端。

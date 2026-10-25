# rdp-firefox

Alpine Linux 容器：用 Windows「遠端桌面連線」（RDP）登入後，畫面上只有一個全螢幕的 Firefox。設計給 Kubernetes 上多人同時使用，也能把自己的桌面分享給別人看或一起操作。

本 branch：**v3.4-share**（`k8s-firefox-rdp.yaml` 預設使用 `:3.4-share`）

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

## 功能

- xrdp 0.10 + xorgxrdp：每條 RDP 連線都有自己獨立的 Xorg 桌面，解析度跟著用戶端視窗
- 多人可用同一個帳號同時登入，各自的 Firefox、HOME、終端機互不影響（sesman `Policy=Separate`），同時最多 4 個桌面（`MAX_SESSIONS`）
- 中文：RDP 剪貼簿為 UTF-8，在 Windows 打好中文複製後貼進 Firefox
- Web 終端機：在 Pod 內的 Firefox 開 `http://localhost:2200`（bash）、`http://localhost:2210`（SSH），只綁 127.0.0.1
- 密碼於啟動時由環境變數設定；每個容器自己產生 TLS 憑證與 RSA 金鑰；xrdp 降權執行
- **Session 分享（`:3.4-share`）**：登入後顯示這個桌面的編號、操作 PIN、唯讀 PIN；其他人在 xrdp 登入畫面的 Session 選 `join<編號>`，password 填 PIN 即可加入

## 快速試用

```bash
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/rdp-firefox:3.4-share
```

用遠端桌面連線到 `<主機 IP>:13389`，在 xrdp 登入畫面 Session 保持 `Xorg`，輸入帳密登入。

## 文件

- [user-guide.md](user-guide.md)：使用手冊（連線登入、Firefox 與中文、終端機、多人使用、分享與加入桌面、常見問題）
- [build-image-v3.4.md](build-image-v3.4.md)：從零建置 `:3.4` 與 `:3.4-share`，並部署到 Kubernetes（tk8s）的完整步驟
- [build-image.md](build-image.md)：v3.2（只有多人獨立 session）的建置步驟

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `Dockerfile` | 映像檔定義（基底 `alpine:3.22`；`SESSION_SHARE=1` 時加裝 session 分享） |
| `rootfs/` | 兩個 tag 都會複製進映像檔 `/` 的設定檔與腳本 |
| `rootfs-share/` | 只有 `:3.4-share` 會套用的分享功能檔案 |
| `k8s-firefox-rdp.yaml` | Kubernetes Deployment 與 NodePort Service（30389） |

## 授權

[MIT License](LICENSE)

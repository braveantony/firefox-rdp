# firefox-rdp

Alpine Linux 容器：用 Windows「遠端桌面連線」（RDP）登入後，畫面上只有一個全螢幕的 Firefox。設計給 Kubernetes 上多人同時使用。

本 branch：**v3.4**（`k8s-firefox-rdp.yaml` 預設使用不含分享功能的 `:3.4`）

## 版本與映像檔

同一份原始碼用建置參數 `SESSION_SHARE` 建出兩個 tag：

| 映像檔 | 功能 |
| --- | --- |
| `ghcr.io/braveantony/firefox-rdp:3.4` | 多人用同一個帳號同時登入，每條連線一個獨立桌面（與 3.2 相同） |
| `ghcr.io/braveantony/firefox-rdp:3.4-share` | 同上，再加上 session 分享：其他人可用操作 PIN 或唯讀 PIN 加入某人的桌面 |

```bash
podman build -t alpine-firefox-rdp:3.4 .
podman build --build-arg SESSION_SHARE=1 -t alpine-firefox-rdp:3.4-share .
```

## 功能

- xrdp 0.10 + xorgxrdp：每條 RDP 連線都有自己獨立的 Xorg 桌面，解析度跟著用戶端視窗
- 多人可用同一個帳號同時登入，各自的 Firefox、HOME、終端機互不影響（sesman `Policy=Separate`）
- 中文：RDP 剪貼簿為 UTF-8，在 Windows 打好中文複製後貼進 Firefox
- Web 終端機：在 Pod 內的 Firefox 開 `http://localhost:2200`（bash）、`http://localhost:2210`（SSH），只綁 127.0.0.1
- 密碼於啟動時由環境變數設定；每個容器自己產生 TLS 憑證與 RSA 金鑰；xrdp 降權執行
- `:3.4-share` 另有：每個 session 以 x0vncserver 在 127.0.0.1 分享畫面，登入時顯示操作 PIN／唯讀 PIN，其他人在 xrdp 登入畫面選 Session `join<編號>` 並輸入 PIN 加入

## 快速試用

```bash
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/firefox-rdp:3.4
```

用遠端桌面連線到 `<主機 IP>:13389`，在 xrdp 登入畫面 Session 保持 `Xorg`，輸入帳密登入。

## 文件

- [build-image-v3.4.md](build-image-v3.4.md)：從零建置 `:3.4` 與 `:3.4-share`，並部署到 Kubernetes（tk8s）的完整步驟，含 session 分享的使用方式
- [build-image.md](build-image.md)：v3.2（只有多人獨立 session）的建置步驟

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `Dockerfile` | 映像檔定義（基底 `alpine:3.22`；`SESSION_SHARE=1` 時加裝 session 分享） |
| `rootfs/` | 兩個 tag 都會複製進映像檔 `/` 的設定檔與腳本 |
| `rootfs-share/` | 只有 `:3.4-share` 會套用的分享功能檔案 |
| `k8s-firefox-rdp.yaml` | Kubernetes Deployment 與 NodePort Service（30389） |

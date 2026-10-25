# firefox-rdp

Alpine Linux 容器：用 Windows「遠端桌面連線」（RDP）登入後，畫面上只有一個全螢幕的 Firefox。設計給 Kubernetes 上多人同時使用。

本 branch：**v3.2**

## 功能

- xrdp 0.10 + xorgxrdp：每條 RDP 連線都有自己獨立的 Xorg 桌面，解析度跟著用戶端視窗
- 多人可用同一個帳號同時登入，各自的 Firefox、HOME、終端機互不影響（sesman `Policy=Separate`）
- 中文：RDP 剪貼簿為 UTF-8，在 Windows 打好中文複製後貼進 Firefox
- Web 終端機：在 Pod 內的 Firefox 開 `http://localhost:2200`（bash）、`http://localhost:2210`（SSH），只綁 127.0.0.1
- 密碼於啟動時由環境變數設定；每個容器自己產生 TLS 憑證與 RSA 金鑰；xrdp 降權執行

## 映像檔

```bash
podman pull ghcr.io/braveantony/firefox-rdp:3.2
podman run -d --name firefox-rdp -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/firefox-rdp:3.2
```

用遠端桌面連線到 `<主機 IP>:13389`，在 xrdp 登入畫面 Session 保持 `Xorg`，輸入帳密登入。

## 文件

- [build-image.md](build-image.md)：從零建置 v3.2 映像檔，並部署到 Kubernetes（tk8s）的完整步驟，可由上到下複製貼上執行

## 檔案

| 路徑 | 說明 |
| --- | --- |
| `Dockerfile` | 映像檔定義（基底 `alpine:3.22`） |
| `rootfs/` | 複製進映像檔 `/` 的設定檔與腳本 |
| `k8s-firefox-rdp.yaml` | Kubernetes Deployment 與 NodePort Service（30389） |

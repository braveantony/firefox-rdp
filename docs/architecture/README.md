# rdp-firefox 架構圖

架構的文字說明見 [../architecture.md](../architecture.md)。這個目錄放的是架構圖本身與產圖腳本。

- `rdp-firefox-architecture.png`：1960 × 1740 PNG。
- `rdp-firefox-architecture.svg`：可編輯的 SVG，文字使用繁體中文。
- `render.py`：產生上述兩個檔案的原始碼；只需要 Python 3 標準函式庫、系統的 libfreetype 與中文字型。

重製方式：

```sh
python3 docs/architecture/render.py /path/to/wqy-zenhei.ttc
```

PNG 使用 WenQuanYi Zen Hei（文泉驛正黑）字型，檢視時不需要另外安裝字型。腳本會逐字檢查字型裡有沒有這個字（glyph，字形）。SVG 在檢視端需要安裝文泉驛正黑或 Noto Sans CJK TC。

核對來源：`README.md`、`manifests/base/{deployment,service,kustomization}.yaml`、`manifests/multi-user/kustomization.yaml`、`images/rdp-firefox/Dockerfile`、`rootfs/opt/desktop/entrypoint.sh`、`rootfs/etc/xrdp/startwm.sh`、`rootfs/etc/ssh/ssh_config.d/tkadm.conf` 與 `rootfs-share/opt/desktop/session-share.sh`（rootfs 路徑相對於 `images/rdp-firefox`）。

## 圖面說明

- 圖中的 Pod 由 Deployment `firefox-rdp` 管理，實際的 Pod 名稱會加上隨機後綴。
- Service 屬於 `web-workspace`。圖中的連線表示 NodePort 的轉送關係，Service 並不是一個獨立執行的代理程式。
- `web-workspace` 與 `taroko` 兩個 namespace 各畫成一個完整的矩形。`tkadm.taroko` 是預設的 SSH 目標，本 repo 不提供 tkadm 的部署清單。
- Secret 名稱由 overlay 加上內容雜湊。
- 粗藍線是從用戶端經 RDP 進入 Firefox 桌面的主路徑。Firefox 方塊畫在 Xorg session 裡，表示 Firefox 在該桌面內全螢幕執行。從 Firefox 出發的綠線，表示在 Firefox 裡開啟 `http://localhost:2200`／`2210` 的 Web 終端機。
- Pod 內只有一個 `desktop` container（虛線框），映像檔為 `ghcr.io/braveantony/rdp-firefox:3.7-share`。標有 `process` 的方塊都是 process（或一組 process），不是額外的 container。
  - ①、④、⑤ 由 tini 與 `/opt/desktop/entrypoint.sh` 在 container 啟動時開啟。
  - ②、③ 在使用者登入時，由 xrdp-sesman 透過 `startwm.sh` 開啟。
- process 以 ①～⑤ 編號，每個方塊的標題下方都有一行職責。
  - ② 的「每條連線一個獨立桌面」指一般 Xorg 登入。
  - join 分享連線沿紫線，經 ③ 共用既有的桌面。
  - ②、③ 都標有「× N」，表示每個桌面各一組。
- ④ 與 ⑤ 是兩個 ttyd process，都只監聽 loopback。Firefox 分別透過 HTTP 連到 :2200（bash）與 :2210（SSH）；只有 :2210 的 SSH 終端機會連到 tkadm:22100。

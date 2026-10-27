# rdp-firefox 系統運作架構

- `rdp-firefox-architecture.png`：1960 × 1740 PNG。
- `rdp-firefox-architecture.svg`：可編輯的 SVG，文字使用繁體中文。
- `render.py`：產生上述兩個檔案的原始碼；僅需 Python 3 標準函式庫、系統 libfreetype 與中文字型。

重製方式：

```sh
python3 docs/architecture/render.py /path/to/wqy-zenhei.ttc
```

PNG 使用 WenQuanYi Zen Hei（文泉驛正黑），不依賴檢視端安裝字型。腳本會逐字檢查 glyph 是否存在；SVG 在檢視端需安裝文泉驛正黑或 Noto Sans CJK TC。

核對來源：`README.md`、`manifests/base/{deployment,service,kustomization}.yaml`、`manifests/multi-user/kustomization.yaml`、`images/rdp-firefox/Dockerfile`、`rootfs/opt/desktop/entrypoint.sh`、`rootfs/etc/xrdp/startwm.sh`、`rootfs/etc/ssh/ssh_config.d/tkadm.conf` 與 `rootfs-share/opt/desktop/session-share.sh`（rootfs 路徑相對於 images/rdp-firefox）。

圖中 Pod 是 Deployment `firefox-rdp` 管理的 rdp-firefox 工作負載，實際 Pod 名稱含動態後綴。Service 屬於 `web-workspace`，圖中連線表示 NodePort 轉送關係，不代表獨立的實體代理程式。`web-workspace` 與 `taroko` 分別以完整矩形表示。`tkadm.taroko` 是預設 SSH 目標；本 repo 不提供 tkadm 的部署清單。Secret 名稱由 overlay 加上內容雜湊。一般 Xorg 登入建立獨立 session，join 連線則共享既有 session。

粗藍線表示從 Client 經 RDP 進入 Firefox 桌面的主路徑；Xorg session 內以瀏覽器視窗呈現全螢幕 Firefox。從 Firefox 出發的綠線表示開啟 `http://localhost:2200 / 2210` 網頁終端機。

Pod 內只有一個 `desktop` container（虛線框），映像檔為 `ghcr.io/braveantony/rdp-firefox:3.7-share`。內部標有 `process` 的方塊均為程序或 session 程序群組，不是額外的 container。啟動入口為 tini 與 `/opt/desktop/entrypoint.sh`；桌面與分享程序由 session 啟動腳本啟動。

程序以 ①～⑤ 編號，每個方塊標題下方都有一行職責；Xorg 的獨立桌面說明指一般 Xorg 登入，join 分享連線沿紫線共用既有畫面。

④ 與 ⑤ 分別是 entrypoint.sh 啟動的兩個 ttyd process，均僅監聽 loopback。Firefox 分別透過 HTTP 連到 :2200（bash）與 :2210（SSH），只有 :2210 的 SSH 終端機連到 tkadm:22100。

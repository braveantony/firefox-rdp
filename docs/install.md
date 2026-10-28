# 安裝 rdp-firefox

本文件說明如何把 rdp-firefox 部署到 Kubernetes 叢集。登入後的使用方式見 [README 的「怎麼用」](../README.md#怎麼用) 與[使用手冊](user-guide.md)。

## 先決條件

### Kubernetes 叢集

- kubectl（內建 Kustomize，一種組合 YAML 設定的工具，`kubectl apply -k` 就是用它）、curl、bash
- kubeconfig（kubectl 連線叢集用的設定檔，通常在 `~/.kube/config`），且有權限建立 Namespace、Deployment、Service、Secret
- 節點能連到 `ghcr.io` 下載映像檔（約 1 GB）；無法上網的叢集請改用私有 registry（存放映像檔的伺服器，需先把映像檔推進去，見[更換映像檔](#更換映像檔)）
- 資源：Pod 需求 1 CPU／2 GiB，上限 4 CPU／4 GiB
- NodePort `30389` 未被占用，且用戶端連得到節點的 TCP 30389 埠（防火牆要放行）
- `localhost:2210` 預設連到 namespace `taroko` 的叢集管理 Pod tkadm（裡面已備好 kubectl 與 kubeconfig）。tkadm 需另外部署，本 repo 不提供；沒有 tkadm 時 2210 無法使用，可用環境變數 `SSH_TARGET` 改連其他主機（見 [README 的「環境變數」](../README.md#環境變數)）

### 遠端桌面用戶端

- **Windows**：內建的「遠端桌面連線」（`mstsc`）
- **macOS**：Mac App Store 的 Windows App；新增 PC 時 Credentials 選 **Ask when required**，才會出現 xrdp 登入畫面

## 快速開始（一個帳號）

在已安裝 kubectl、curl、bash，且連得到目標叢集的電腦上執行（可先用 `kubectl config current-context` 確認目前選用的是哪個叢集）：

```bash
curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-firefox/main/install.sh | bash
```

腳本用目前的 kubeconfig 部署到 namespace `web-workspace`（Kubernetes 裡用來分組資源的名稱空間），等 Pod 啟動完成（第一次要下載約 1 GB），最後印出每個節點的連線位址。用遠端桌面連線到 `<節點 IP>:30389`，帳號 `bigred`、密碼 `bigred`。

節點 IP 也可以用 `kubectl get nodes -o wide` 的 INTERNAL-IP 欄查看，連任一節點都可以；雲端叢集要用用戶端連得到的 IP。

- 需要多個帳號或修改密碼：改用下方的[多個帳號（Kustomize）](#多個帳號kustomize)
- 要讓區網的 Windows 直接用主機 IP 連線（不用記 NodePort）：見 [build-image-v3.4.md](build-image-v3.4.md) 附錄 A-4

## 多個帳號（Kustomize）

帳號清單寫在 `users.txt`，由 Kustomize 的 `secretGenerator` 產生 Secret（Kubernetes 存放密碼等敏感資料的物件），掛載到 container 的 `/etc/firefox-rdp/users`。

```bash
git clone https://github.com/braveantony/rdp-firefox.git
cd rdp-firefox
vi manifests/multi-user/users.txt   # 用你熟悉的文字編輯器修改帳號清單，這裡以 vi 為例
kubectl apply -k manifests/multi-user
kubectl -n web-workspace rollout status deploy/firefox-rdp   # 等待 Pod 啟動完成（第一次要下載約 1 GB）
```

`users.txt` 一行一個 `帳號:密碼`，`#` 開頭為註解：

```text
alice:Alice-pw
bob:Bob-pw
```

- 帳號規則：小寫英文字母或 `_` 開頭，可用小寫英數字、`_`、`-`，最長 32 字元，不可為 `root`、`xrdp`、`webterm`；密碼不可空白，可以包含冒號。不符規則時 Pod 會啟動失敗，原因可用 `kubectl -n web-workspace logs deploy/firefox-rdp` 查看。
- 修改 `users.txt` 後再 `kubectl apply -k manifests/multi-user` 即可：Secret 名稱帶內容雜湊（`firefox-rdp-users-<雜湊>`），名單有變就會自動重建 Pod。所有桌面都在同一個 Pod 裡，重建時所有使用中的連線都會中斷。
- 每個帳號各有自己的桌面與家目錄；設定多個帳號時，`localhost:2200` 會先要求登入，`localhost:2210` 會先詢問 SSH 目標上的帳號。
- 已用快速開始安裝過也沒關係，直接 apply 即會改用新的名單；之後不要再執行 `install.sh`，否則帳號會還原成只有 bigred/bigred 一組。
- `users.txt` 含明文密碼，請勿提交到公開的 repo；可改用 SOPS、Sealed Secrets 等工具管理。

## 更換映像檔

要換映像檔（例如無法上網的叢集改用私有 registry，或改用不含分享功能的 `:3.2`），在 `manifests/multi-user/kustomization.yaml` 取消 `images:` 區塊的註解，並設定 `newName`／`newTag`，再 `kubectl apply -k manifests/multi-user`。各版本的差異見 [README 的「版本比較」](../README.md#版本比較)。

## 升級

- 用快速開始安裝的：再執行一次上面的 `curl … | bash`。
- 用 Kustomize 部署的：`git pull` 取得新版後，再 `kubectl apply -k manifests/multi-user`。

升級會重建 Pod（Deployment 的更新策略是 `Recreate`，舊 Pod 停掉後才會建立新 Pod），所有使用中的連線都會中斷。

## 移除

```bash
kubectl delete namespace web-workspace
```

這會刪除 namespace `web-workspace` 裡的所有資源，包含帳號 Secret。

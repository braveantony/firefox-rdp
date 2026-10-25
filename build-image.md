# Alpine Firefox RDP Pod 映像檔建置手冊（v3.2）

本文件從零做出 `localhost/alpine-firefox-rdp:3.2`。**由上到下依序複製每個指令區塊貼到終端機執行**，就能得到 v3.2 映像檔。每個區塊開頭都會 `cd ~/firefox-rdp`，中途換終端機也能接著貼。

> 包含 session 分享功能的完整版本（v3.4，`:3.4` 與 `:3.4-share` 兩個 tag）請見 [build-image-v3.4.md](https://github.com/braveantony/rdp-firefox/blob/main/build-image-v3.4.md)。

## 這個映像檔做什麼

使用者用 Windows「遠端桌面連線」（RDP）登入，畫面上只有一個全螢幕、無邊框的 Firefox。

| 功能 | 做法 |
| --- | --- |
| RDP 伺服器 | xrdp 0.10 + xorgxrdp：每個 RDP 連線由 sesman 起一個獨立的 Xorg，解析度跟著用戶端視窗 |
| 多人同時使用 | sesman `Policy=Separate`：同一個帳號的每條連線各有自己的桌面、Firefox profile、HOME，互不影響 |
| 中文 | RDP 剪貼簿為 UTF-8：在 Windows 用輸入法打好，複製後在 Firefox 按 `Ctrl+V` |
| Web 終端機 | 在 Pod 內的 Firefox 開 `http://localhost:2200`（bash）、`http://localhost:2210`（myssh）；只綁 127.0.0.1 |
| 安全 | 密碼由環境變數在啟動時設定（不寫進映像檔）；每個容器自己產生 TLS 憑證與 RSA 金鑰；xrdp 監聽程式降權為 `xrdp` 使用者；Xorg、Firefox、終端機都以登入帳號執行 |

## 前置需求

| 項目 | 需求 |
| --- | --- |
| 建置工具 | podman（docker 亦可，把指令中的 `podman` 換成 `docker`） |
| 網路 | 建置時要能連到 `dl-cdn.alpinelinux.org` 下載 Alpine 3.22 套件 |
| 磁碟 | 至少 3 GB 可用空間（映像檔約 790 MB，建置過程需要更多） |
| CPU 架構 | x86_64（本文件以此實測） |

先確認 podman 可用、磁碟空間足夠：

```bash
podman --version
df -h ~
```

> **注意**：如果建置的這台主機同時跑著 K8s 節點（例如 tk8s 的節點容器共用主機磁碟），磁碟使用率超過 85% 時 kubelet 會開始刪除節點上沒在用的映像檔，超過 95% 會驅逐 Pod。建置前請確認建置後仍低於 85%。

## Step 1：建立專案目錄

```bash
mkdir -p ~/firefox-rdp/rootfs/etc/profile.d \
         ~/firefox-rdp/rootfs/etc/skel/.config/openbox \
         ~/firefox-rdp/rootfs/etc/xrdp \
         ~/firefox-rdp/rootfs/opt/desktop \
         ~/firefox-rdp/rootfs/usr/bin \
         ~/firefox-rdp/rootfs/usr/lib/firefox/distribution
cd ~/firefox-rdp
```

完成 Step 2、3 後的結構：

```text
firefox-rdp/
├── Dockerfile
└── rootfs/                                  # 整個目錄會 COPY 到映像檔的 /
    ├── etc/profile.d/nano-nocolor.sh
    ├── etc/skel/.config/openbox/rc.xml
    ├── etc/xrdp/startwm.sh
    ├── opt/desktop/entrypoint.sh
    ├── opt/desktop/term.sh
    ├── usr/bin/myssh
    ├── usr/lib/firefox/distribution/distribution.ini
    └── usr/lib/firefox/distribution/policies.json
```

## Step 2：建立設定檔與腳本

### 2-1 容器入口腳本 entrypoint.sh

由 tini 以 root 啟動（xrdp-sesman 需要 root 才能做 PAM 驗證並切換成登入帳號）。依序：建立登入帳號並設定密碼、產生本容器專用的 TLS 憑證與 RSA 金鑰、啟動 sesman 與 xrdp、啟動兩個只綁 127.0.0.1 的 ttyd。任何一個服務結束就讓容器退出，交給 K8s 重啟。

```bash
cd ~/firefox-rdp
cat > rootfs/opt/desktop/entrypoint.sh <<'EOF'
#!/bin/bash
# Started by tini as root: xrdp-sesman needs root for PAM and to switch to the login user.
# The xrdp listener itself drops to the xrdp user (runtime_user in xrdp.ini).
set -eu
RDP_USER="${RDP_USER:-bigred}"
MAX_SESSIONS="${MAX_SESSIONS:-4}"
SSH_TARGET="${SSH_TARGET:-tkadm.taroko}"
: "${RDP_PASSWORD:?RDP_PASSWORD must be set (from a Secret)}"

case "$RDP_USER" in
  root|xrdp) echo "[entrypoint] RDP_USER must not be $RDP_USER" >&2; exit 1 ;;
esac
if ! echo "$RDP_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "[entrypoint] invalid RDP_USER: $RDP_USER" >&2
  exit 1
fi

# Login user with a fixed UID; home is populated from /etc/skel (openbox config)
id "$RDP_USER" >/dev/null 2>&1 || adduser -D -u 1000 -s /bin/bash "$RDP_USER"
echo "${RDP_USER}:${RDP_PASSWORD}" | chpasswd
unset RDP_PASSWORD

# Per-pod TLS certificate and RDP RSA keys (the Dockerfile removes the ones
# apk generated at build time); readable by the unprivileged xrdp listener
cd /etc/xrdp
if [ ! -s key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)" \
    -keyout key.pem -out cert.pem 2>/dev/null
fi
[ -s rsakeys.ini ] || xrdp-keygen xrdp rsakeys.ini >/dev/null
chown root:xrdp key.pem cert.pem rsakeys.ini
chmod 640 key.pem cert.pem rsakeys.ini
cd /

rm -rf /run/xrdp/*.pid /tmp/.X*-lock /tmp/.X11-unix/X* /tmp/sess /tmp/term.*

# Per-session homes live under /tmp/sess (see startwm.sh)
install -d -m 700 -o "$RDP_USER" -g "$RDP_USER" /tmp/sess
case "$MAX_SESSIONS" in
  ''|*[!0-9]*) echo "[entrypoint] invalid MAX_SESSIONS: $MAX_SESSIONS" >&2; exit 1 ;;
esac
sed -i "s/^MaxSessions=.*/MaxSessions=${MAX_SESSIONS}/" /etc/xrdp/sesman.ini

xrdp-sesman --nodaemon &
xrdp --nodaemon &

# Web terminals: loopback only, run as RDP_USER, one process per browser tab.
# -O rejects WebSocket connections from other origins (web pages in Firefox).
uid=$(id -u "$RDP_USER")
gid=$(id -g "$RDP_USER")
ttyd -W -O -i lo -u "$uid" -g "$gid" -p 2200 -t fontSize=14 -t scrollback=10000 \
  /opt/desktop/term.sh bash -l &
ttyd -W -O -i lo -u "$uid" -g "$gid" -p 2210 -t fontSize=14 -t scrollback=10000 \
  -t 'theme={"foreground":"#ffffff","background":"#000000"}' \
  /opt/desktop/term.sh /usr/bin/myssh "$SSH_TARGET" &

# Any daemon exiting stops the container so K8s restarts it
wait -n
echo "[entrypoint] a service exited, stopping container" >&2
exit 1
EOF
```

### 2-2 RDP session 啟動腳本 startwm.sh

每條 RDP 連線登入後，sesman 以登入帳號執行這個腳本。它為這個 session 建立獨立的 HOME（`/tmp/sess/<display 編號>`）、XDG runtime 與 D-Bus，再啟動 openbox 與 Firefox；Firefox 被關掉會自動重開。session 結束時刪除整個目錄。

```bash
cd ~/firefox-rdp
cat > rootfs/etc/xrdp/startwm.sh <<'EOF'
#!/bin/bash
# Run by xrdp-sesman as RDP_USER for every RDP connection. sesman uses
# Policy=Separate, so each connection has its own display; this script gives
# it its own HOME, runtime dir and D-Bus so concurrent users of the same
# account never share a Firefox profile. Everything is removed on exit.
set -u
export LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8 TZ=Asia/Taipei
export NO_AT_BRIDGE=1 GDK_BACKEND=x11 MOZ_ENABLE_WAYLAND=0

# sesman sets DISPLAY=:N.0; the socket is /tmp/.X11-unix/XN
dnum=${DISPLAY#*:}
dnum=${dnum%%.*}

# sesman wrote this display's cookie to the real home; keep using it
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

S="/tmp/sess/$dnum"
rm -rf "$S"
mkdir -p -m 700 "$S/home" "$S/run"
cp -R /etc/skel/. "$S/home"/
export HOME="$S/home" XDG_RUNTIME_DIR="$S/run"
cd "$HOME"

eval "$(dbus-launch --sh-syntax)"

cleanup() {
  kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  pkill -TERM -P $$ 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

openbox &

# Reopen Firefox if the user closes it, until this session's X server is gone
while [ -S "/tmp/.X11-unix/X${dnum}" ]; do
  firefox --new-instance about:blank &
  wait $!
  sleep 1
done
EOF
```

### 2-3 Web 終端機包裝腳本 term.sh

ttyd 每開一個瀏覽器分頁就執行一次：給這個終端機一個用完即刪的暫存 HOME，不同使用者的終端機不會共用檔案或歷史紀錄。

```bash
cd ~/firefox-rdp
cat > rootfs/opt/desktop/term.sh <<'EOF'
#!/bin/bash
# Spawned by ttyd (as RDP_USER) per browser connection: run the command with
# a throwaway HOME so terminals of different RDP users never share state
set -u
H=$(mktemp -d /tmp/term.XXXXXX)
trap 'rm -rf "$H"' EXIT
cp -R /etc/skel/. "$H"/
export HOME="$H" USER="$(id -un)" LOGNAME="$(id -un)"
cd "$H"
"$@"
EOF
```

### 2-4 SSH 包裝腳本 myssh

2210 終端機執行 `myssh <SSH_TARGET>`。如果你已有自己的 `myssh`，直接覆蓋此檔即可。

```bash
cd ~/firefox-rdp
cat > rootfs/usr/bin/myssh <<'EOF'
#!/bin/bash
# 用法：myssh <user@host 或 ~/.ssh/config 中的 Host 名稱>
exec ssh -o StrictHostKeyChecking=accept-new "$@"
EOF
```

### 2-5 Openbox 設定：所有視窗最大化、無邊框

放在 `/etc/skel`，建立帳號與每個 session 時都會複製一份。刻意不定義快捷鍵與右鍵選單，使用者無法從桌面叫出其他程式。

```bash
cd ~/firefox-rdp
cat > rootfs/etc/skel/.config/openbox/rc.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <maximized>true</maximized>
      <decor>no</decor>
    </application>
  </applications>
</openbox_config>
EOF
```

### 2-6 Firefox 偏好設定：下載時詢問儲存位置

```bash
cd ~/firefox-rdp
cat > rootfs/usr/lib/firefox/distribution/distribution.ini <<'EOF'
[Global]
id=k8s-web-firefox
version=1.0
about=Firefox for K8s Web Workspace

[Preferences]
browser.download.useDownloadDir=false
EOF
```

### 2-7 Firefox 企業原則：關閉遙測、首次啟動頁、自動更新

```bash
cd ~/firefox-rdp
cat > rootfs/usr/lib/firefox/distribution/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisableAppUpdate": true,
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NewTabPage": false,
    "Homepage": { "URL": "about:blank", "StartPage": "homepage" }
  }
}
EOF
```

### 2-8 nano 預設關閉顏色

```bash
cd ~/firefox-rdp
cat > rootfs/etc/profile.d/nano-nocolor.sh <<'EOF'
alias nano='nano -Y none'
EOF
```

## Step 3：撰寫 Dockerfile

重點：

- 基底固定 `alpine:3.22`，不用 `latest`。
- 刪除 apk 在建置時產生的 `cert.pem`、`key.pem`、`rsakeys.ini`，否則所有容器會共用同一把寫死在映像檔裡的私鑰；改由 entrypoint 在每個容器啟動時產生。
- 用 `sed` 修改套件預設的 `xrdp.ini` 與 `sesman.ini`：只保留 Xorg session、xrdp 降權為 `xrdp` 使用者、關閉磁碟與音效轉送、每條連線獨立 session、斷線 120 秒後回收。

```bash
cd ~/firefox-rdp
cat > Dockerfile <<'EOF'
FROM alpine:3.22

# xrdp + xorgxrdp: every RDP login gets its own Xorg (xrdpdev driver), no VNC
RUN apk add --no-cache \
      xrdp xorgxrdp xorg-server xinit \
      openbox firefox \
      dbus dbus-x11 \
      font-wqy-zenhei font-dejavu fontconfig \
      xkeyboard-config \
      ttyd bash nano openssh-client openssl \
      tini tzdata musl-locales \
 && fc-cache -f \
 && dbus-uuidgen > /etc/machine-id \
 && mkdir -p -m 1777 /tmp/.X11-unix \
 && rm -f /usr/share/dbus-1/services/org.a11y.Bus.service \
 && rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem /etc/xrdp/rsakeys.ini

ENV LANG=zh_TW.UTF-8 \
    LC_ALL=zh_TW.UTF-8 \
    TZ=Asia/Taipei

# The RDP login user (RDP_USER, UID 1000) is created at startup from /etc/skel.
# xrdp is the unprivileged user the xrdp listener drops to.
RUN addgroup -S xrdp && adduser -S -D -H -G xrdp xrdp

COPY rootfs/ /

# xrdp.ini: keep only the Xorg session type, drop to the xrdp user,
#           disable drive and sound redirection (no FUSE / PulseAudio in the pod)
# sesman.ini: socket group matches runtime_group; every connection gets its own
#             session (Policy=Separate, so concurrent users never share a desktop);
#             sessions cannot be rejoined, so kill them 2 minutes after a disconnect
RUN sed -i '/^\[Xvnc\]/,$d' /etc/xrdp/xrdp.ini \
 && sed -i -e 's/^#runtime_user=xrdp/runtime_user=xrdp/' \
           -e 's/^#runtime_group=xrdp/runtime_group=xrdp/' \
           -e 's/^rdpdr=true/rdpdr=false/' \
           -e 's/^rdpsnd=true/rdpsnd=false/' /etc/xrdp/xrdp.ini \
 && sed -i -e 's/^#SessionSockdirGroup=xrdp/SessionSockdirGroup=xrdp/' \
           -e 's/^AllowRootLogin=true/AllowRootLogin=false/' \
           -e 's/^KillDisconnected=false/KillDisconnected=true/' \
           -e 's/^DisconnectedTimeLimit=0/DisconnectedTimeLimit=120/' \
           -e 's/^Policy=Default/Policy=Separate/' /etc/xrdp/sesman.ini \
 && chmod +x /etc/xrdp/startwm.sh /opt/desktop/*.sh /usr/bin/myssh

# 3389 = RDP; the web terminals (2200 bash, 2210 SSH) listen on loopback only
EXPOSE 3389

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/desktop/entrypoint.sh"]
EOF
```

## Step 4：設定執行權限並確認檔案

```bash
cd ~/firefox-rdp
chmod +x rootfs/opt/desktop/*.sh rootfs/etc/xrdp/startwm.sh rootfs/usr/bin/myssh
find . -type f | sort
```

應列出 9 個檔案：`./Dockerfile` 與 `./rootfs/` 底下 8 個檔案。

## Step 5：建置映像檔

```bash
cd ~/firefox-rdp
podman build -t alpine-firefox-rdp:3.2 .
podman images localhost/alpine-firefox-rdp
```

podman 會自動加上 `localhost/` 前綴，完整名稱是 `localhost/alpine-firefox-rdp:3.2`，大小約 790 MB（Alpine 套件庫會更新，大小可能略有差異）。第一次建置要下載約 200 個套件，需要數分鐘。

確認映像檔內的 xrdp 設定已正確修改（不會啟動服務）：

```bash
podman run --rm --entrypoint sh localhost/alpine-firefox-rdp:3.2 -c '
  grep -n "^\[" /etc/xrdp/xrdp.ini
  grep -E "^(runtime_user|runtime_group|rdpdr|rdpsnd)=" /etc/xrdp/xrdp.ini
  grep -E "^(Policy|AllowRootLogin|KillDisconnected|DisconnectedTimeLimit|SessionSockdirGroup)=" /etc/xrdp/sesman.ini
  ls /etc/xrdp/*.pem /etc/xrdp/rsakeys.ini 2>&1'
```

預期：xrdp.ini 只剩 `[Globals]`、`[Logging]`、`[LoggingPerLogger]`、`[Channels]`、`[Xorg]` 五個區段；`runtime_user=xrdp`、`rdpdr=false`、`rdpsnd=false`；`Policy=Separate`、`AllowRootLogin=false`、`KillDisconnected=true`、`DisconnectedTimeLimit=120`；而且**沒有** `.pem` 與 `rsakeys.ini`（顯示 No such file or directory）。這兩行錯誤訊息是預期結果，代表映像檔裡沒有寫死金鑰；也因為最後一個指令找不到檔案，這個區塊的結束碼是 1，不是建置失敗。

## Step 6：在本機驗證

用 13389 埠在本機跑一個測試容器，帳密為 `bigred` / `bigred`：

```bash
podman run -d --name rdp-test -p 13389:3389 --shm-size 1g \
  -e RDP_USER=bigred -e RDP_PASSWORD=bigred \
  localhost/alpine-firefox-rdp:3.2
sleep 5
podman logs rdp-test
podman exec rdp-test sh -c 'netstat -tln; ps -o user,args | grep -E "xrdp|sesman|ttyd" | grep -v grep'
```

預期：

- log 出現 `chpasswd: password for 'bigred' changed`。
- `netstat` 有 `:::3389`、`127.0.0.1:2200`、`127.0.0.1:2210`。
- `xrdp-sesman` 以 root 執行、`xrdp` 以 xrdp 執行、兩個 `ttyd` 以 bigred 執行。

接著用 Windows「遠端桌面連線」連到 `<這台主機的 IP>:13389`。出現 xrdp 登入畫面時，Session 保持 `Xorg`，username `bigred`、password `bigred`，登入後應看到全螢幕的 Firefox 空白分頁。在網址列輸入 `localhost:2200` 應出現 bash 終端機，`whoami` 顯示 `bigred`。

驗證完刪除測試容器：

```bash
podman rm -f rdp-test
```

映像檔建置完成。

---

## 附錄 A：部署到 tk8s

以下是 tk8s 上的部署方式。tk8s 的節點是 podman 容器，節點內只有 `crictl`，所以用主機上的 root podman 直接把映像檔載入每個 worker 的 CRI-O 儲存區。

### A-1 載入映像檔到每個 worker

先確認磁碟（見前置需求的注意事項），再**一次只存一個映像檔**載入。`podman save` 一次存多個映像檔時若沒加 `-m`，封存檔裡只有第一個映像檔，卻會把所有 tag 都套上去。

```bash
df -h /
podman save -o /tmp/alpine-firefox-rdp-3.2.tar localhost/alpine-firefox-rdp:3.2
for n in tk8s-worker-1 tk8s-worker-2; do
  sudo podman \
    --root /var/lib/containers/storage/volumes/$n-var/_data/lib/containers/storage \
    --runroot /run/ffw-load-$n --storage-driver overlay \
    load -i /tmp/alpine-firefox-rdp-3.2.tar
  sudo podman exec $n crictl images | grep alpine-firefox-rdp
done
rm -f /tmp/alpine-firefox-rdp-3.2.tar
podman images --format '{{.ID}} {{.Repository}}:{{.Tag}}' localhost/alpine-firefox-rdp
```

每個 worker 顯示的 IMAGE ID 前 12 碼應與最後一行本機的 ID 相同。

### A-2 建立登入密碼的 Secret

```bash
kubectl get ns web-workspace >/dev/null 2>&1 || kubectl create namespace web-workspace
kubectl -n web-workspace create secret generic firefox-rdp-auth \
  --from-literal=password='bigred' --dry-run=client -o yaml | kubectl apply -f -
```

### A-3 部署 YAML

```bash
cd ~/firefox-rdp
cat > k8s-firefox-rdp.yaml <<'EOF'
# Create the login password first (not stored in this file):
#   kubectl -n web-workspace create secret generic firefox-rdp-auth --from-literal=password='<密碼>'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: firefox-rdp
  namespace: web-workspace
spec:
  replicas: 1
  strategy:
    type: Recreate          # all RDP sessions live inside this one pod
  selector:
    matchLabels:
      app: firefox-rdp
  template:
    metadata:
      labels:
        app: firefox-rdp
    spec:
      affinity:
        nodeAffinity:         # tk8s 的 control-plane 沒有 taint，排除它
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
      containers:
      - name: desktop
        image: localhost/alpine-firefox-rdp:3.2
        imagePullPolicy: IfNotPresent
        # Runs as root: xrdp-sesman needs PAM and setuid to the login user (RDP_USER).
        # Xorg, openbox and Firefox run as RDP_USER; the xrdp listener drops to user xrdp.
        securityContext:
          allowPrivilegeEscalation: false
        env:
        - name: RDP_USER
          value: "bigred"
        - name: MAX_SESSIONS        # 同時連線上限；每個 session 約 0.5 CPU、0.5–1 GiB
          value: "4"
        - name: SSH_TARGET          # 2210 終端機的 myssh 目標
          value: "tkadm.taroko"
        - name: RDP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: firefox-rdp-auth
              key: password
        ports:
        - name: rdp
          containerPort: 3389
        readinessProbe:
          tcpSocket:
            port: rdp
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          tcpSocket:
            port: rdp
          initialDelaySeconds: 15
          periodSeconds: 20
        resources:
          requests:           # 依 MAX_SESSIONS=4 估算
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "4"
            memory: "4Gi"
        volumeMounts:
        - name: dshm
          mountPath: /dev/shm
      volumes:
      - name: dshm             # 容器預設 /dev/shm 只有 64MiB，Firefox 分頁容易崩潰
        emptyDir:
          medium: Memory
          sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: firefox-rdp
  namespace: web-workspace
spec:
  type: NodePort
  selector:
    app: firefox-rdp
  ports:
  - name: rdp
    port: 3389
    targetPort: rdp
    nodePort: 30389
EOF
```

```bash
cd ~/firefox-rdp
kubectl apply -f k8s-firefox-rdp.yaml
kubectl -n web-workspace rollout status deploy/firefox-rdp
kubectl -n web-workspace exec deploy/firefox-rdp -- netstat -tln
```

### A-4 讓區網的 Windows 連得到（主機轉發）

tk8s 節點在主機內部網段，Windows 連不到 NodePort。在主機上用一個 socat 容器把主機的 3389 轉到節點的 30389：

```bash
podman run -d --name rdp-forward --restart=always --network host \
  docker.io/alpine/socat:1.8.0.3 TCP-LISTEN:3389,fork,reuseaddr TCP:172.22.0.2:30389
```

Windows「遠端桌面連線」填主機的 IP（例如 `192.168.11.64`）。出現 xrdp 登入畫面時，Session 保持 `Xorg`，帳號 `bigred`、密碼 `bigred`。

主機重開機後要讓轉發容器自動恢復，需執行一次：

```bash
sudo loginctl enable-linger $USER
systemctl --user enable podman-restart.service
```

## 附錄 B：環境變數

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `RDP_PASSWORD` | （必填） | 登入密碼；K8s 上由 Secret `firefox-rdp-auth` 提供 |
| `RDP_USER` | `bigred` | 登入帳號，固定 UID 1000；不可為 `root` 或 `xrdp` |
| `MAX_SESSIONS` | `4` | 同時連線上限；第 5 條連線會看到「Max session limit reached」 |
| `SSH_TARGET` | `tkadm.taroko` | 2210 終端機 `myssh` 的連線目標 |

## 附錄 C：已知行為與建置時踩過的坑

| 現象 | 原因與處理 |
| --- | --- |
| 斷線後重連，看到的是全新的 Firefox | `Policy=Separate` 的設計：同一帳號多人同時使用時才不會互相接管畫面。斷線的 session 120 秒後回收。若需要斷線後接回，要改成每人一個帳號 |
| 登入後立刻斷線，sesman log 寫 `Window manager ... exited quickly` | sesman 設定的是 `DISPLAY=:10.0`，X socket 是 `/tmp/.X11-unix/X10`；startwm.sh 已去掉 `.0` 再判斷 |
| 連線在 MCS 階段失敗，xrdp log 寫 `Cannot read ... key.pem: Permission denied` | xrdp 降權後讀不到 root 專屬的金鑰；entrypoint 會把憑證與金鑰設為 `root:xrdp` 640 |
| 終端機一開就出現 `cp: can't preserve ownership` | 以一般使用者 `cp -a` 複製 root 擁有的 `/etc/skel`；已改用 `cp -R` |
| 第 5 個使用者登不進去 | 達到 `MAX_SESSIONS`，調高此值並同步調高 YAML 的 resources（4 個閒置 session 約 1.7 GB 記憶體） |
| xrdp log 每 5 秒出現一組 `CR-TPDU (Connection Request) failed` | K8s readinessProbe／livenessProbe 的 TCP 檢查，連上就斷，無害 |
| 節點上的映像檔不見、Pod 起不來 | 主機磁碟超過 85% 觸發 kubelet image GC；`localhost/` 映像檔無法重新拉取，要用附錄 A-1 重新載入 |

> 本文件已於 2026-10-25 實測：把 Step 1–6 的指令區塊原樣抽出，在全新的 HOME 與空的 podman 儲存區（無任何快取）中依序執行。Step 1–4 產生的 9 個檔案與附錄 A-3 的 YAML，和 v3.2 映像檔內的檔案逐字相同；Step 5 從零建出的映像檔，其自訂檔案、xrdp／sesman 設定、帳號、主要套件版本與映像檔設定都和 tk8s 先前部署的 v3.2 相同，設定檢查結果與文件所述一致；Step 6 的容器檢查符合預期，並在 xrdp 登入畫面以 bigred/bigred 登入、在 Firefox 開 localhost:2200 得到 bigred 的終端機。v3.2 先前已在 tk8s 上實測兩人同時連線互不影響、斷線 120 秒後回收、第 5 個連線被拒。尚未從實體 Windows 電腦實測。

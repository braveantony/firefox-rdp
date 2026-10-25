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

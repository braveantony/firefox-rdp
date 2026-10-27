FROM alpine:3.22

# xrdp + xorgxrdp: every RDP login gets its own Xorg (xrdpdev driver), no VNC
RUN apk add --no-cache \
      xrdp xorgxrdp xorg-server xinit \
      openbox firefox \
      dbus dbus-x11 \
      font-wqy-zenhei font-dejavu fontconfig \
      xkeyboard-config \
      fcitx5 fcitx5-chewing fcitx5-gtk3 \
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

# The RDP login accounts (UID 1000, 1001, ...) are created at startup from
# /etc/firefox-rdp/users or RDP_USER/RDP_PASSWORD, with homes from /etc/skel.
# xrdp is the unprivileged user the xrdp listener drops to.
RUN addgroup -S xrdp && adduser -S -D -H -G xrdp xrdp

COPY rootfs/ /
# Session-sharing files; only installed when built with SESSION_SHARE=1 (below)
COPY rootfs-share/ /usr/share/firefox-rdp/share/

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
 && chmod +x /etc/xrdp/startwm.sh /opt/desktop/*.sh /usr/bin/myssh \
 && chmod 644 /etc/ssh/ssh_config.d/tkadm.conf

# SESSION_SHARE=1 builds the :<version>-share tag. Each session is then shared
# over VNC on 127.0.0.1:59<display> (x0vncserver) with a control PIN and a
# view-only PIN; xrdp sections join10..join19 connect to it, so a viewer picks
# "join<display>" as the Session on the xrdp login screen and enters a PIN as
# the password. Kept as the last layer so both tags share every layer above.
ARG SESSION_SHARE=0
RUN if [ "$SESSION_SHARE" = 1 ]; then \
      apk add --no-cache tigervnc yad \
 &&   cp -R /usr/share/firefox-rdp/share/. / \
 &&   chmod +x /opt/desktop/share-info.sh \
 &&   for n in $(seq 10 19); do \
        printf '\n[join%s]\nname=join%s\nlib=libvnc.so\nip=127.0.0.1\nport=59%s\nusername=na\npassword=ask\n' \
          "$n" "$n" "$n" >> /etc/xrdp/xrdp.ini; \
      done; \
    fi

# 3389 = RDP; the web terminals (2200 bash, 2210 SSH) listen on loopback only
EXPOSE 3389

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/desktop/entrypoint.sh"]

#!/bin/sh
set -e

case "${SSHD_PROFILE:-modern}" in
    modern) cp /etc/ssh/sshd_config.d/modern.conf /etc/ssh/sshd_config ;;
    legacy) cp /etc/ssh/sshd_config.d/legacy.conf /etc/ssh/sshd_config ;;
    *) echo "unknown SSHD_PROFILE: $SSHD_PROFILE" >&2; exit 1 ;;
esac

ssh-keygen -A
mkdir -p /run/sshd

# -D 前台运行，-e 日志打到 stderr 供 docker logs 收集
exec /usr/sbin/sshd -D -e "$@"

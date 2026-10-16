#!/bin/sh
set -e

mkdir -p /run/sshd /var/run/sshd

# -D 前台运行，-e 日志打到 stderr 供 docker logs 收集。
# 2205 的 DEBUG 日志是 AlgorithmMatrix 的观测面之一（服务器侧实际下发了什么），
# 别把它丢进容器里没人看的 syslog。
exec /usr/sbin/sshd -D -e "$@"

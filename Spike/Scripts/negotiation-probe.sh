#!/bin/bash
# M1'-1 出口标准用：五台服务器的"协商事实"。
#
# 两条腿，各管一件事：
#   A. 服务器侧实际配置（sshd -T）—— 它**能**给什么。这是权威值，
#      不受客户端默认值影响，libssh2 的矩阵（#24）拿它当对照面。
#   B. 客户端侧实际协商（系统 ssh，两趟）—— 一次用客户端默认，一次放开老算法。
#      两趟之差就是"客户端默认值挡住了哪些格子"，这个必须和"服务器不支持"分开记。
#
# 注意 macOS 的系统 ssh（本机 10.3）已经把 ssh-dss 整个编译掉了：
#   -oHostKeyAlgorithms=+ssh-dss → "Bad key types"，直接报错退出。
#   所以 2205 的 ssh-dss 这一格本机测不了，脚本跳过并在结果里写明"未测"，
#   要测得换一台还有 DSA 的客户端（容器里的 9.7 可以）。
#
# 用法：Spike/Scripts/negotiation-probe.sh [--out DIR]
set -uo pipefail

HOST="${SPIKE_AGENT_HOST:-127.0.0.1}"
OUT="${SPIKE_PROBE_OUT:-/tmp/ferry-negotiation}"
rm -rf "$OUT"; mkdir -p "$OUT"

# 端口  容器名  用途
SERVERS="2201 ferry-sftp-atmoz-1
2202 ferry-sftp-modern-1
2203 ferry-sftp-legacy-1
2204 ferry-sftp-oldalgo-1
2205 ferry-sftp-oldos-1"

# 放开老算法：只加 +（保留客户端默认优先级），不整值替换，
# 否则测到的是"我们强行喂的算法"而不是"客户端愿意接受时会选什么"。
LEGACY=(-oHostKeyAlgorithms=+ssh-rsa
        -oPubkeyAcceptedAlgorithms=+ssh-rsa
        -oKexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
        -oCiphers=+aes128-cbc,aes256-cbc,3des-cbc
        -oMACs=+hmac-sha1,hmac-sha1-96,hmac-md5)

negotiate() {   # $1=端口 $2=日志 $3…=ssh 选项
    local port=$1 log=$2; shift 2
    ssh -vv -p "$port" -oBatchMode=yes -oConnectTimeout=10 \
        -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
        "$@" tester@"$HOST" true >"$log" 2>&1
}

pick() { grep -E "$1" "$2" 2>/dev/null | head -1 | sed -E 's/^debug1: //; s/^[0-9]+:  *//' | tr -d '\r'; }
field() { sed -nE "s/^debug1: $1: //p" "$2" 2>/dev/null | head -1 | tr -d '\r'; }
# kex 谈成但主机密钥/算法被客户端默认值挡掉时，"kex: algorithm" 仍会印出已达成的一致，
# 而 cipher 那行根本不会出现在 kex 失败之前 —— 空值就是"没走到这一步"。
report_fields() {
    local log=$1 f v
    for f in 'kex: algorithm' 'kex: host key algorithm' 'kex: server->client cipher'; do
        v=$(field "$f" "$log"); echo "  ${f}：${v:-（未协商到）}"
    done
}

total_fail=0
while read -r port container; do
    [ -n "${port:-}" ] || continue
    echo "════════════════════════════════════════ $port（$container）"

    if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
        echo "  容器没在运行 —— 这一台未测"
        total_fail=$((total_fail + 1)); continue
    fi

    echo "── A. 服务器能给的（sshd -T，注意它的输出是'关键字 值'不是 key=value）"
    docker exec -u root "$container" sh -c '/usr/sbin/sshd -T 2>/dev/null' \
        | grep -iE '^(kexalgorithms|ciphers|macs|hostkeyalgorithms|pubkeyacceptedalgorithms|challengeresponseauthentication|kbdinteractiveauthentication|passwordauthentication|usepam) ' \
        | sed 's/^/  /' > "$OUT/$port-server.conf"
    if [ -s "$OUT/$port-server.conf" ]; then cat "$OUT/$port-server.conf"; else echo "  （sshd -T 无输出）"; fi
    # 6.x 的 sshd 没有 HostKeyAlgorithms 这个服务端关键字，主机密钥只能看实际存在的密钥文件
    if ! grep -q '^  hostkeyalgorithms' "$OUT/$port-server.conf"; then
        echo "  hostkey(从密钥文件推)：$(docker exec -u root "$container" sh -c \
            'for k in /etc/ssh/ssh_host_*_key.pub; do cut -d" " -f1 "$k"; done' | tr '\n' ' ')"
    fi
    echo "  容器内 ssh -V：$(docker exec "$container" ssh -V 2>&1)"

    echo "── B1. 客户端默认能连到什么"
    negotiate "$port" "$OUT/$port-default.log"
    soft=$(pick 'remote software version' "$OUT/$port-default.log")
    echo "  banner：${soft#*remote software version }"
    report_fields "$OUT/$port-default.log"
    blocked=$(pick 'Unable to negotiate' "$OUT/$port-default.log")
    [ -n "$blocked" ] && echo "  被客户端默认值挡住：${blocked#Unable to negotiate with 127.0.0.1 port ${port}: }"
    echo "  认证方法：$(pick 'Permission denied' "$OUT/$port-default.log" | sed 's/.*denied //')"

    echo "── B2. 放开老算法后"
    negotiate "$port" "$OUT/$port-legacy.log" "${LEGACY[@]}"
    report_fields "$OUT/$port-legacy.log"
    blocked=$(pick 'Unable to negotiate' "$OUT/$port-legacy.log")
    if [ -n "$blocked" ]; then
        echo "  放开后仍谈不成：${blocked#Unable to negotiate with 127.0.0.1 port ${port}: }"
        total_fail=$((total_fail + 1))
    else
        echo "  认证方法：$(pick 'Permission denied' "$OUT/$port-legacy.log" | sed 's/.*denied //')（到认证阶段即算 kex 通过）"
    fi
done <<EOF
$SERVERS
EOF

echo
echo "完整日志：$OUT（每台三份：-server.conf / -default.log / -legacy.log）"
echo "汇总：$total_fail 台谈不成 kex"
[ "$total_fail" -eq 0 ]

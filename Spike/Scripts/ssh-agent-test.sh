#!/bin/bash
# M1'-4 用：一个只在本次调用内存活的 ssh-agent。
#
# 为什么不复用本机 agent（ADR-0000 §9 N4）：
#   用户的 SSH_AUTH_SOCK 指向登录会话里的 agent，里面挂的是真实工作密钥。
#   往里 add 测试密钥 = 改用户环境；反过来"只要 agent 可用就用它的全部 key"
#   = 测量被本机密钥列表左右，"agent 认证成功"这条根本没被隔离出来。
#   所以这里固定：临时 HOME + 临时 socket + 只加载自己生成的密钥。
#   绝不 launchctl setenv，绝不把 SSH_AUTH_SOCK 写回调用方之外。
#
# 用法：
#   Spike/Scripts/ssh-agent-test.sh                # 自检：起 agent、装密钥、逐台走 agent 认证
#   Spike/Scripts/ssh-agent-test.sh -- cmd arg…    # 在同一 agent 环境下跑任意命令，退出即回收
#
# 环境变量：
#   SPIKE_AGENT_KEY_BITS   临时 RSA 位数（默认 2048；2204 只认 ssh-rsa，必须有 RSA）
#   SPIKE_AGENT_PORTS      探测端口（默认 "2201 2202 2203 2204 2205"）
#   SPIKE_AGENT_HOST       默认 127.0.0.1
set -eu

HOST="${SPIKE_AGENT_HOST:-127.0.0.1}"
PORTS="${SPIKE_AGENT_PORTS:-2201 2202 2203 2204 2205}"
BITS="${SPIKE_AGENT_KEY_BITS:-2048}"
CONTAINERS="ferry-sftp-atmoz-1 ferry-sftp-modern-1 ferry-sftp-legacy-1 ferry-sftp-oldalgo-1 ferry-sftp-oldos-1"

# 进来时外面是什么，只在报告里出现一次；脚本全程不读也不写它。
OUTER_SOCK="${SSH_AUTH_SOCK:-（未设置）}"

# docker CLI 靠 HOME 找它的 context 和 socket（本机在 ~/.docker/run/docker.sock）。
# 下面把 HOME 换成临时目录后，docker 会退化成 unix:///var/run/docker.sock 并报"守护进程没在跑"
# —— 看着像容器全挂了，其实是我们自己把 CLI 的配置目录弄丢了。所以先把地址固化进 DOCKER_HOST。
DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)}"
export DOCKER_HOST

if [ "${1:-}" = "--" ]; then
    shift
    RUN_CMD=("$@")
else
    RUN_CMD=()
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ferry-agent.XXXXXX")
chmod 700 "$WORK"
cleanup() {
    [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null
    rm -rf "$WORK"
    true
}
trap cleanup EXIT INT TERM
mkdir -p "$WORK/.ssh"
chmod 700 "$WORK/.ssh"

echo "== 1. 临时环境与测试密钥（这一步还在真实 HOME 下，docker 要用它）"
echo "  临时目录      ：$WORK"
echo "  DOCKER_HOST   ：${DOCKER_HOST:-（默认）}"
echo "  外部 agent    ：$OUTER_SOCK（本脚本不读不写）"

ssh-keygen -q -t rsa     -b "$BITS" -f "$WORK/.ssh/id_rsa"  -N '' -C ferry-agent-test
ssh-keygen -q -t ed25519        -f "$WORK/.ssh/id_ed25519" -N '' -C ferry-agent-test
echo "  测试密钥      ：rsa $BITS + ed25519，都不带口令（带口令的没法非交互 add）"

echo "== 2. 公钥装进在跑的容器"
install_keys() {   # $1=容器名
    docker exec -i -u root "$1" sh -c '
        mkdir -p /home/tester/.ssh
        touch /home/tester/.ssh/authorized_keys
        while read -r line; do
            [ -n "$line" ] || continue
            grep -qxF "$line" /home/tester/.ssh/authorized_keys || echo "$line" >> /home/tester/.ssh/authorized_keys
        done
        # 用数字 uid:gid：atmoz 的运行期建用户把组名叫 group_1001，`chown tester:tester` 在它上面直接失败。
        # 另外 2201 实测：root 所有的 /home/tester/.ssh 通不过公钥认证，改成 tester 自己所有就过了。
        U=$(id -u tester 2>/dev/null || echo tester)
        G=$(id -g tester 2>/dev/null || echo "$U")
        chown -R "$U:$G" /home/tester/.ssh
        chmod 700 /home/tester/.ssh
        chmod 600 /home/tester/.ssh/authorized_keys
        echo "        属主 $(stat -c "%U:%G(%u:%g) mode=%a" /home/tester/.ssh)"
    '
}
for c in $CONTAINERS; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || { echo "  跳过 $c（没在运行）"; continue; }
    cat "$WORK/.ssh/id_rsa.pub" "$WORK/.ssh/id_ed25519.pub" | install_keys "$c"
    echo "  $c：2 条公钥就位（幂等，重复跑不累加）"
done

# HOME 换掉之后 ssh 找不到用户真实的 ~/.ssh/config 和 known_hosts ——
# 前者会悄悄改认证行为，后者会把这次的 TOFU 结果写进用户那份文件。两个都是污染。
export HOME="$WORK"
unset SSH_AUTH_SOCK

echo "== 3. 起 agent（socket 落在临时目录，路径可复现）"
SOCK="$WORK/agent.sock"
eval "$(ssh-agent -s -a "$SOCK")"
[ "${SSH_AUTH_SOCK:-}" = "$SOCK" ] || { echo "  ✗ agent 没用我们的 socket：${SSH_AUTH_SOCK:-无}"; exit 1; }
echo "  HOME          ：$HOME"
echo "  SSH_AUTH_SOCK ：$SSH_AUTH_SOCK"
echo "  SSH_AGENT_PID ：$SSH_AGENT_PID（进程在吗：$(kill -0 "$SSH_AGENT_PID" 2>/dev/null && echo 是 || echo 否)）"

ssh-add "$WORK/.ssh/id_rsa" "$WORK/.ssh/id_ed25519" >/dev/null 2>&1
echo "  ssh-add -l    ："
ssh-add -l | sed 's/^/    /'

if [ ${#RUN_CMD[@]} -gt 0 ]; then
    echo "== 把 agent 交给调用方命令（跳过逐台自检）"
    # 不能用 exec：那会替换掉本 shell，EXIT trap 不触发，agent 和临时目录全留在系统里。
    # 所以要显式退出，并把调用方命令的退出码原样传出去。
    rc=0
    "${RUN_CMD[@]}" || rc=$?
    exit "$rc"
fi

echo "== 4. 只许走 agent 认证，逐台连"
# BatchMode + PasswordAuthentication=no：认证只能从 agent 来，密码路径必须失败。
# 老算法要显式放开 —— macOS 的 OpenSSH 10.3 默认连 ssh-rsa 的 offer 都不发，
# 那是客户端的默认值而不是服务器的属性，别把它当成"服务器不支持"记进矩阵。
LEGACY=(-oHostKeyAlgorithms=+ssh-rsa
        -oPubkeyAcceptedAlgorithms=+ssh-rsa
        -oKexAlgorithms=+diffie-hellman-group14-sha1
        -oCiphers=+aes128-cbc,aes256-cbc
        -oMACs=+hmac-sha1,hmac-sha1-96)
fails=0
for p in $PORTS; do
    rc=0
    out=$(ssh -v -o BatchMode=yes -o PasswordAuthentication=no -o PreferredAuthentications=publickey \
               -o StrictHostKeyChecking=no -o UserKnownHostsFile="$WORK/.ssh/known_hosts" \
               "${LEGACY[@]}" -p "$p" "tester@$HOST" 'echo OK-$(whoami)' 2>&1) || rc=$?
    # 判据是"认证成功"，不是"命令跑通"：atmoz 把 tester 的 shell 设成 /bin/false（SFTP-only 设备的常态），
    # 认证过了但命令必然 rc=1。我们自己的客户端只用 subsystem，不碰 shell —— 这里别把它记成失败。
    authed=$(printf '%s\n' "$out" | grep -oE 'Authenticated to .* using "[a-z-]+"' | head -1)
    fromagent=$(printf '%s\n' "$out" | grep -E 'Server accepts key' | tail -1 | sed -E 's/^debug1: //')
    shell_ran=$(printf '%s\n' "$out" | grep -c '^OK-' || true)   # grep 没命中时退出码 1，set -e 会当场终止脚本
    if [ -n "$authed" ]; then
        echo "  $p：PASS — $authed"
        echo "        key 来源：${fromagent:-（没抓到 Server accepts key 行）}"
        [ "$shell_ran" -gt 0 ] && echo "        远程命令可跑" || echo "        远程命令不可跑（shell 被禁，属正常）"
    else
        echo "  $p：FAIL rc=$rc — $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ')"
        fails=$((fails + 1))
    fi
done

echo "== 5. 反向对照：agent 里只留 ed25519"
# 上面那轮"RSA 成功"还不能证明 2204 的老公钥限制生效 —— 客户端先试的就是 RSA，
# ed25519 根本没轮到。这里把 agent 清成只剩 ed25519，2203 必须还能过、2204 必须拒绝，
# 这一格才有意义：过了说明 PubkeyAcceptedAlgorithms ssh-rsa 只是个注释，没在拦。
ssh-add -D >/dev/null 2>&1
ssh-add "$WORK/.ssh/id_ed25519" >/dev/null 2>&1
echo "  agent 现在只有：$(ssh-add -l)"
ctrl_fail=0
for p in 2203 2204; do
    expect_pass=0; [ "$p" = 2203 ] && expect_pass=1
    rc=0
    out=$(ssh -o BatchMode=yes -o PasswordAuthentication=no -o PreferredAuthentications=publickey \
               -o StrictHostKeyChecking=no -o UserKnownHostsFile="$WORK/.ssh/known_hosts" \
               "${LEGACY[@]}" -p "$p" "tester@$HOST" true 2>&1) || rc=$?
    got=$(printf '%s\n' "$out" | grep -c 'Authenticated to' || true)
    if [ "$expect_pass" -eq 1 ] && [ "$rc" -ne 0 ]; then
        echo "  $p：✗ 预期 ed25519 可用（PubkeyAcceptedAlgorithms 是 +ssh-rsa 追加），却 rc=$rc"
        ctrl_fail=$((ctrl_fail + 1))
    elif [ "$expect_pass" -eq 0 ] && [ "$got" -gt 0 ]; then
        echo "  $p：✗ 预期 ed25519 被拒（只认 ssh-rsa），结果认证过了 —— 那行配置没在拦"
        ctrl_fail=$((ctrl_fail + 1))
    else
        echo "  $p：符合预期（$([ "$expect_pass" -eq 1 ] && echo '可用' || echo '已拒')）"
    fi
done
ssh-add -D >/dev/null 2>&1
ssh-add "$WORK/.ssh/id_rsa" "$WORK/.ssh/id_ed25519" >/dev/null 2>&1

echo "== 6. 回收"
echo "  临时 agent 里的 key（应当只有我们那两把）："
ssh-add -l | sed 's/^/    /'
echo "  外部 agent 仍是：$OUTER_SOCK（未被改动）"
if [ "$fails" -gt 0 ] || [ "$ctrl_fail" -gt 0 ]; then
    echo "汇总：$fails 台经 agent 认证失败，$ctrl_fail 项反向对照不符预期"
    exit 1
fi
echo "汇总：$PORTS 全经临时 agent 认证成功，反向对照 2 项符预期"

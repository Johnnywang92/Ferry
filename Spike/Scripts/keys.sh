#!/bin/bash
# spike #8 用密钥语料：覆盖 Ferry 真会遇到的四种私钥形态。
#   openssh-key-v1 + bcrypt（有口令）—— 新版 ssh-keygen 默认
#   openssh-key-v1 明文            —— 无口令
#   老式 PEM + 口令                —— 用户从旧工具迁过来的
#   ecdsa                          —— 常见第三类
# 生成后把公钥装进 sftp-modern 的 authorized_keys，认证才可能真的成功。
set -eu

DIR="${SPIKE_KEY_DIR:-/tmp/ferry-keys}"
CONTAINER="${SPIKE_CONTAINER:-ferry-sftp-modern-1}"
mkdir -p "$DIR"
chmod 700 "$DIR"

gen() { # 名字 类型 位数 口令 格式
  local name=$1 type=$2 bits=$3 pass=$4 format=${5:-}
  local path="$DIR/$name"
  [ -f "$path" ] && rm -f "$path" "$path.pub"
  local args=(-t "$type" -f "$path" -N "$pass" -q)
  [ -n "$bits" ] && args+=(-b "$bits")
  [ -n "$format" ] && args+=(-m "$format")
  ssh-keygen "${args[@]}"
}

gen ed_bcrypt ed25519 "" "secret123"
gen ed_plain  ed25519 "" ""
gen rsa_new   rsa 3072 "secret123"
gen ecdsa_new ecdsa 256 "secret123"
gen rsa_pem   rsa 2048 "secret123" PEM

echo "生成完成：$DIR"
ls -1 "$DIR"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  cat "$DIR"/*.pub | docker exec -i "$CONTAINER" sh -c \
    'mkdir -p /home/tester/.ssh && cat > /home/tester/.ssh/authorized_keys && chown -R tester:tester /home/tester/.ssh && chmod 700 /home/tester/.ssh && chmod 600 /home/tester/.ssh/authorized_keys'
  echo "已把 $(cat "$DIR"/*.pub | wc -l | tr -d ' ') 条公钥写入 $CONTAINER:/home/tester/.ssh/authorized_keys"
else
  echo "跳过公钥安装：容器 $CONTAINER 不在运行"
fi

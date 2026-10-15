#!/bin/bash
# spike #7：确认候选 API 在"当前链接的这份 libssh2"里到底存不存在。
#
# M0b 起探的是 ThirdParty/build-xcframework.sh 的静态归档，不再是 Homebrew dylib。
# 静态库没有 dyld 懒绑定，符号存在性是二值的，所以判据拆成两条独立事实：
#   声明 = 头文件里有原型（决定这行代码写不写得出来）
#   定义 = 归档里有定义（决定链接会不会炸）
# 两条缺一都是坑：只声明没定义，编译通过、链接报错；只定义没声明，
# Swift 侧压根看不见这个符号（函数式宏就属于这类）。
#
# 真正的链接期验证由 Spike 本身完成——它现在就链的是这个归档，
# 引用了不存在的符号根本构建不出来。本脚本的作用是给出全符号矩阵，
# 而不是只覆盖 spike 恰好写到的那几个。
#
# 用法：
#   ThirdParty/build-xcframework.sh 之后再跑
#   ./Spike/Scripts/api-probe.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XCFW="$REPO/Packages/Backends/Vendor/FerrySSH.xcframework"

# 切片目录名随架构组合变（macos-arm64 / macos-arm64_x86_64），扫出来别写死
SLICE=$(find "$XCFW" -maxdepth 2 -name Headers -type d 2>/dev/null | head -1)
INCLUDE="${LIBSSH2_INCLUDE:-${SLICE%/Headers}}"
ARCHIVE="${LIBSSH2_ARCHIVE:-$(find "$XCFW" -maxdepth 2 -name "FerrySSH.a" 2>/dev/null | head -1)}"

if [[ -z "$INCLUDE" || ! -d "$INCLUDE/Headers" || -z "$ARCHIVE" ]]; then
    echo "找不到产物：$XCFW" >&2
    echo "先跑 ThirdParty/build-xcframework.sh" >&2
    exit 1
fi
INCLUDE="$INCLUDE/Headers"

SYMBOLS=(
  # —— 取消 / 打断
  libssh2_session_set_abort_fn
  libssh2_session_set_timeout
  libssh2_session_set_read_timeout
  libssh2_transport_set_sendsize
  # —— 扩展与重命名
  libssh2_sftp_posix_rename_ex
  libssh2_sftp_rename_ex
  libssh2_sftp_symlink_ex
  libssh2_sftp_fsync
  libssh2_sftp_stat_ex
  libssh2_sftp_statvfs
  # —— 认证与凭据
  libssh2_userauth_publickey_frommemory
  libssh2_userauth_publickey_fromfile_ex
  libssh2_userauth_keyboard_interactive_ex
  libssh2_agent_init
  libssh2_agent_connect
  libssh2_agent_list_identities
  libssh2_agent_userauth
  libssh2_agent_get_identity
  # —— 协商信息 / 主机密钥
  libssh2_crypto_engine
  libssh2_session_methods
  libssh2_session_banner_get
  libssh2_knownhost_addc
  libssh2_knownhost_checkp
  # —— 保活
  libssh2_keepalive_config
  libssh2_keepalive_send
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 归档里的定义符号一次抽完，避免每个符号都 nm 一遍 10MB
nm --extern-only "$ARCHIVE" 2>/dev/null | awk '$2 == "T" || $2 == "D" || $2 == "S" {print $3}' | sort -u > "$work/defined"

declared=0
defined=0
for sym in "${SYMBOLS[@]}"; do
  cat > "$work/$sym.c" <<EOF
#include <libssh2.h>
#include <libssh2_sftp.h>
void *probe(void) { return (void *)&$sym; }
EOF
  if clang -fsyntax-only "$work/$sym.c" -I"$INCLUDE" 2>"$work/cc.err"; then
    d=有
    declared=$((declared + 1))
  else
    d=无
  fi
  if grep -qx "_$sym" "$work/defined"; then
    f=有
    defined=$((defined + 1))
  else
    f=无
  fi
  case "$d/$f" in
    有/有) verdict="可用" ;;
    无/无) verdict="两头都没有" ;;
    有/无) verdict="只有声明，链接会炸" ;;
    无/有) verdict="库里有，头文件没给" ;;
  esac
  printf '%-10s  声明=%s  定义=%s   %s\n' "$sym" "$d" "$f" "$verdict"
done

echo
echo "汇总：声明 $declared/${#SYMBOLS[@]}，定义 $defined/${#SYMBOLS[@]}"
echo "头文件 $INCLUDE"
echo "归档   $ARCHIVE"

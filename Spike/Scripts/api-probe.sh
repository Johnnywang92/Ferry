#!/bin/bash
# spike #7：确认候选 API 在"当前链接的这份 libssh2"里到底存不存在。
#
# 只看头文件不够：函数式宏头文件里有、但 Swift 导不到；符号在 dylib 里也可能被裁掉。
# 这里对每个符号生成一个 `void *p = (void*)&sym;` 的 C 文件，真编译真链接，
# 链接失败即判定"不可用"。用法：
#   SPIKE_HOST=127.0.0.1 ./Spike/Scripts/api-probe.sh
set -u

INCLUDE="${LIBSSH2_INCLUDE:-/opt/homebrew/include}"
LIBDIR="${LIBSSH2_LIBDIR:-/opt/homebrew/lib}"

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

present=0
absent=0
for sym in "${SYMBOLS[@]}"; do
  cat > "$work/$sym.c" <<EOF
#include <libssh2.h>
#include <libssh2_sftp.h>
void *probe(void) { return (void *)&$sym; }
EOF
  if clang -c -o "$work/$sym.o" "$work/$sym.c" -I"$INCLUDE" 2>"$work/cc.err"; then
    if clang -dynamiclib -o "$work/$sym.dylib" "$work/$sym.o" -L"$LIBDIR" -lssh2 2>"$work/ld.err"; then
      echo "可用      $sym"
      present=$((present + 1))
      continue
    fi
    reason="dylib 里没这个符号"
  else
    reason="头文件里没有声明"
  fi
  echo "不可用    $sym   （$reason）"
  absent=$((absent + 1))
done

echo
echo "汇总：可用 $present 个，不可用 $absent 个"
echo "libssh2 头文件 $INCLUDE，库 $LIBDIR"

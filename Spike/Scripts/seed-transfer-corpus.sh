#!/bin/sh
# M1'-6：给五台服务器铺同一套"单文件上下传"语料（docs/spike/M1-06）。
#
# 为什么要 4 MB 的随机文件而不是 /dev/zero：上下传这一轮的验收是**字节级**的，
# 而全零文件对一个漏掉 262144 整块的 bug 完全无感——内容在每个 256 KB 窗口里
# 都长得一样。随机内容 + 服务器侧 `sha256sum` 留下的那份哈希，才是独立于 Swift
# 的参照物：测试先下 `.sha256`、再下正文、本地重算一遍比对，任何一次错位都会露出来。
#
# 为什么还要一个 30001 字节的小文件：libssh2 的 SFTP 包上限是 30000 字节
# （`sftp.h:47,52`），30001 恰好跨两个包，是"一次 write 只回一个包的确认"这条
# 最便宜的证人（实测见 M1-06 §2）。
#
#   Spike/Scripts/seed-transfer-corpus.sh                      # 五台全铺
#   Spike/Scripts/seed-transfer-corpus.sh ferry-sftp-modern-1  # 只铺一台
#
# 语料落在容器内的 /home/tester/spike/xfer；2201 是 chroot，客户端看到的同一路径是
# /spike/xfer（与 seed-listing-corpus.sh 同一套约定，基准必须由服务器给）。
#
# 幂等：随机正文只在缺失或大小不对时重铺，哈希每次都重算。
set -e

CONTAINERS=${*:-"ferry-sftp-atmoz-1 ferry-sftp-modern-1 ferry-sftp-legacy-1 ferry-sftp-oldalgo-1 ferry-sftp-oldos-1"}

BODY=$(cat <<'INSIDE'
set -e
ROOT=/home/tester/spike/xfer
mkdir -p "$ROOT/nowrite"

# 4194304 = 4 MiB = 正好 16 个 256 KB chunk。bs=4096 是老 coreutils 与 busybox 都认的写法。
if [ ! -f "$ROOT/rand4m.bin" ] || [ "$(wc -c < "$ROOT/rand4m.bin")" != 4194304 ]; then
    dd if=/dev/urandom of="$ROOT/rand4m.bin" bs=4096 count=1024 2>/dev/null
fi
# 16 MiB：吞吐那一档要用它，4 MiB 在本地 0.2 ms RTT 下跑不出稳定数。
if [ ! -f "$ROOT/mid16m.bin" ] || [ "$(wc -c < "$ROOT/mid16m.bin")" != 16777216 ]; then
    dd if=/dev/urandom of="$ROOT/mid16m.bin" bs=4096 count=4096 2>/dev/null
fi
head -c 30001 "$ROOT/rand4m.bin" > "$ROOT/odd30001.bin"
head -c 262144 "$ROOT/rand4m.bin" > "$ROOT/one256k.bin"
printf 'hello ferry\n' > "$ROOT/small.txt"
: > "$ROOT/empty.bin"

cd "$ROOT" || exit 1
sha256sum rand4m.bin > rand4m.bin.sha256
sha256sum mid16m.bin > mid16m.bin.sha256
sha256sum odd30001.bin > odd30001.bin.sha256

chmod 644 "$ROOT"/*.bin "$ROOT"/*.txt "$ROOT"/*.sha256 2>/dev/null || true
chmod 755 "$ROOT"
# 555：目录能列、不能建——`createWrite` 在这条路上应当拿 `.permissionDenied`。
chmod 555 "$ROOT/nowrite"
chown -R tester "$ROOT" 2>/dev/null || chown -R 1000 "$ROOT" 2>/dev/null || true

echo "  rand4m=$(wc -c < "$ROOT/rand4m.bin")  mid16m=$(wc -c < "$ROOT/mid16m.bin")  odd=$(wc -c < "$ROOT/odd30001.bin")  sha=$(cut -c1-12 "$ROOT/rand4m.bin.sha256")…"
INSIDE
)

for container in $CONTAINERS; do
    printf '%s\n' "$BODY" | docker exec -i -u root "$container" sh -s
    echo "$container 已铺好"
done

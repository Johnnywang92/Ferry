#!/bin/sh
# 生成 spike 用测试语料，幂等：已存在则跳过。
#   /home/tester/spike/big.bin    64 MB 随机文件 —— 吞吐类 spike
#   /home/tester/spike/small/     1000 × 1 KB   —— 小文件批量往返 spike
# 容器重建后（换镜像、改 cap_add）语料会丢，重跑本脚本即可。
#   docker compose exec -u root sftp-modern /seed-corpus.sh
set -e

SPIKE_DIR=/home/tester/spike
BIG="$SPIKE_DIR/big.bin"
SMALL="$SPIKE_DIR/small"
BIG_SIZE=${BIG_SIZE:-64}
SMALL_COUNT=${SMALL_COUNT:-1000}

mkdir -p "$SMALL"

if [ ! -f "$BIG" ]; then
    dd if=/dev/urandom of="$BIG" bs=1048576 count="$BIG_SIZE" status=none
fi

COUNT=$(find "$SMALL" -name 'f*.bin' | wc -l | tr -d ' ')
if [ "$COUNT" -lt "$SMALL_COUNT" ]; then
    i=$((COUNT + 1))
    while [ "$i" -le "$SMALL_COUNT" ]; do
        head -c 1024 /dev/urandom > "$SMALL/$(printf f%04d.bin "$i")"
        i=$((i + 1))
    done
fi

chown -R tester:tester "$SPIKE_DIR"
chmod 755 "$SPIKE_DIR" "$SMALL"

echo "big.bin: $(wc -c < "$BIG") bytes, small/: $(find "$SMALL" -name 'f*.bin' | wc -l) 个文件"

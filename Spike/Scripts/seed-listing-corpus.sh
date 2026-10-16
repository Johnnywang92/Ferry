#!/bin/sh
# M1'-5：给五台服务器铺同一套"目录列表"语料（docs/spike/M1-05）。
#
# 为什么要脚本而不是各自手工建：这一节的结论全是"同一条清单在五台上的差别"，
# 语料不一样就没有可比性。2204/2205 在 M1-01 里没有铺过 spike 语料（那份文档 §7 记了），
# 这里一次补齐。
#
#   Spike/Scripts/seed-listing-corpus.sh                     # 五台全铺
#   Spike/Scripts/seed-listing-corpus.sh ferry-sftp-modern-1 # 只铺一台
#
# 语料落在容器内的 /home/tester/spike/list（2201 是 chroot，客户端看到的视图根是 /，
# 所以同一个目录在 2201 上的路径是 /spike/list，其余四台是 /home/tester/spike/list）。
#
# 幂等：反复跑只重建链和权限位，1000 个文件那一档先看数量再补。
set -e

CONTAINERS=${*:-"ferry-sftp-atmoz-1 ferry-sftp-modern-1 ferry-sftp-legacy-1 ferry-sftp-oldalgo-1 ferry-sftp-oldos-1"}

BODY=$(cat <<'INSIDE'
set -e
ROOT=/home/tester/spike/list
WANT=1000

mkdir -p "$ROOT/flat" "$ROOT/dir" "$ROOT/links" "$ROOT/maze/dir1" "$ROOT/noperm"
printf 'hello\n' > "$ROOT/dir/file"
: > "$ROOT/dir/sub_placeholder"
mkdir -p "$ROOT/dir/sub"
printf 'x\n' > "$ROOT/maze/dir1/file"

# 1000 个空文件：readdir 的往返数只跟条目数有关，跟内容无关，空文件铺得最快。
HAVE=$(ls "$ROOT/flat" 2>/dev/null | wc -l | tr -d ' ')
i=$HAVE
while [ "$i" -lt "$WANT" ]; do
    : > "$ROOT/flat/$(printf 'e%04d' "$i")"
    i=$((i + 1))
done

# 255 字节名（NAME_MAX）。这条是用来验"`-38` 对名字这一档根本走不到"：
# 缓冲从 1024 起，而文件名最长 255，永远装得下。
LONGNAME=n
while [ ${#LONGNAME} -lt 255 ]; do LONGNAME="${LONGNAME}n"; done
: > "$ROOT/flat/$LONGNAME"

# 非 UTF-8 名字：GBK 的"文本"两字（CE C4 BC FE），补 .txt 也是 ASCII。
# UTF-8 下 CE C4 是残缺序列，正好是 M0b-02 那批"必须按连接字符集才解得开"的名字。
#
# 这里必须用 `%b` 而不是把 `\316` 直接写进格式串：容器里的 printf（busybox ash 与 dash）
# 会把 `\ooo` 当**当前 locale 下的字符**处理，UTF-8 环境里 0xCE 不是合法字符，
# 静默换成 `?`（实测第一轮就铺出 `gbk-?..?.txt`）。`printf %b "\0316"` 才按字节给。
find "$ROOT/flat" -name 'gbk-*' -exec rm -f {} + 2>/dev/null || true
: > "$ROOT/flat/$(printf 'gbk-')$(printf '%b' '\0316\0304\0274\0376')$(printf '.txt')"

# 链的六种形状。l_long 的目标是一条不存在的、1500+ 字节的路径——
# readlink 照原样回，用来撞 `-38` 涨档那条路。
LT=/home/tester/spike/list/flat
while [ ${#LT} -lt 1500 ]; do LT="$LT/e0000"; done
rm -f "$ROOT/links"/* 2>/dev/null || true
ln -s ../dir/file          "$ROOT/links/l_to_file"
ln -s ../dir               "$ROOT/links/l_to_dir"
ln -s ../dir/nowhere       "$ROOT/links/l_broken"
ln -s l_to_file            "$ROOT/links/l_chain"
ln -s "$LT"                "$ROOT/links/l_long"
n=1
while [ "$n" -le 8 ]; do
    ln -s ../maze/dir1/file "$ROOT/links/maze$(printf '%02d' "$n")"
    n=$((n + 1))
done

chmod 000 "$ROOT/noperm"
chown -R tester "$ROOT" 2>/dev/null || chown -R 1000 "$ROOT" 2>/dev/null || true
chmod 755 "$ROOT" "$ROOT/flat" "$ROOT/dir" "$ROOT/links" "$ROOT/maze" "$ROOT/maze/dir1"
chmod 000 "$ROOT/noperm"

echo "  flat=$(ls "$ROOT/flat" | wc -l | tr -d ' ') 条  links=$(ls "$ROOT/links" | wc -l | tr -d ' ') 条  最长名=$(printf '%s' "$LONGNAME" | wc -c | tr -d ' ') 字节  长目标=$(printf '%s' "$LT" | wc -c | tr -d ' ') 字节"
INSIDE
)

for container in $CONTAINERS; do
    printf '%s\n' "$BODY" | docker exec -i -u root "$container" sh -s
    echo "$container 已铺好"
done

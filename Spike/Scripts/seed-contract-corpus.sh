#!/bin/sh
# M1'：给五台服务器铺契约语料（`FerryContracts.ContractCorpus` 约定的形状）。
#
# 为什么要单独一个脚本而不是复用 seed-listing-corpus.sh：契约套件与被测方之间
# 只有一条约定——`ContractCorpus` 里那些路径常量。两边各写一份字面量迟早会漂，
# 而漂了之后契约里的"跳过"就会掩盖真实的语料缺失（"这台后端上没有 GBK 名条目"
# 听起来像合理结论，实际可能是脚本没铺）。所以这个脚本**逐条对着约定铺**，
# 任何一条铺不出来就在非零退出码上体现，而不是留个空目录让契约自己猜。
#
#   Spike/Scripts/seed-contract-corpus.sh                          # 五台全铺
#   Spike/Scripts/seed-contract-corpus.sh ferry-sftp-modern-1      # 只铺一台
#
# 落点是容器内的 /home/tester/spike/contract（2201 是 chroot，客户端看到的视图根
# 是 `/`，所以同一个目录在 2201 上的路径是 /spike/contract，其余四台是
# /home/tester/spike/contract —— 与 M1-05 的 listing 语料同一套处理）。
#
# 幂等：反复跑只重建链与特殊名，普通文件按需补。
set -e

CONTAINERS=${*:-"ferry-sftp-atmoz-1 ferry-sftp-modern-1 ferry-sftp-legacy-1 ferry-sftp-oldalgo-1 ferry-sftp-oldos-1"}

BODY=$(cat <<'INSIDE'
set -e
ROOT=/home/tester/spike/contract

# 对应 ContractCorpus：empty / flat / dir / deep / links / special / degraded / transfer
mkdir -p "$ROOT/empty" "$ROOT/flat" "$ROOT/dir" "$ROOT/deep/a/b/c/d" \
         "$ROOT/links" "$ROOT/special" "$ROOT/degraded" "$ROOT/transfer"

# --- dir/file：契约里断言它 6 字节（"hello\n"） ---
printf 'hello\n' > "$ROOT/dir/file"

# --- deep/a/b/c/d/leaf：512 字节，验深层嵌套末段可达 ---
rm -f "$ROOT/deep/a/b/c/d/leaf"
LONG=$(head -c 512 /dev/zero | tr '\0' 'L')
printf '%s' "$LONG" > "$ROOT/deep/a/b/c/d/leaf"

# --- links/：四条链。相对目标刻意用 ../dir/file，"按链自己所在目录拼"那一格
#     才验得出差别（按根拼会落到 /dir/file 之外的错误位置） ---
ln -sfn ../dir/file "$ROOT/links/rel"
ln -sfn /dir/file   "$ROOT/links/abs"
ln -sfn /nowhere    "$ROOT/links/broken"
ln -sfn /links/loop2 "$ROOT/links/loop"
ln -sfn /links/loop  "$ROOT/links/loop2"

# --- special/：契约里只硬验含 `:` 的那个，另两个是给人看的 ---
rm -f "$ROOT/special/"*
printf 'c' > "$ROOT/special/colon:name"
printf 's' > "$ROOT/special/star*name"
printf 't' > "$ROOT/special/tab	name"

# --- flat/：≥1000 条 + 一个 255 字节名 + GBK 名 + NFC 名 ---
HAVE=$(ls "$ROOT/flat" 2>/dev/null | wc -l | tr -d ' ')
i=$HAVE
while [ "$i" -lt 1000 ]; do
    : > "$ROOT/flat/$(printf 'e%04d' "$i")"
    i=$((i + 1))
done

# 255 字节名（NAME_MAX）。验的是"`-38` 对名字这一档根本走不到"：
# 缓冲从 1024 起，文件名最长 255，永远装得下。
LONGNAME=n
while [ ${#LONGNAME} -lt 255 ]; do LONGNAME="${LONGNAME}n"; done
: > "$ROOT/flat/$LONGNAME"

# GBK 的"文本"两字（CE C4 BC FE）。UTF-8 下 CE C4 是残缺序列，正好是
# "必须按连接字符集才解得开"的那批名字（M0b-02）。
#
# 必须用 `printf %b` 而不是把 \316 直接写进格式串：容器里的 printf（busybox ash
# 与 dash）会把 \ooo 当**当前 locale 下的字符**处理，UTF-8 环境里 0xCE 不是合法
# 字符，静默换成 `?`（实测第一轮就铺出 gbk-?..?.txt）。
find "$ROOT/flat" -name 'gbk-*' -exec rm -f {} + 2>/dev/null || true
printf %b 'gbk-\316\304\274\376.txt' > "$ROOT/flat/$(printf %b 'gbk-\316\304\274\376.txt')"

# NFC 的 é（U+00E9，C3 A9）。NFD 写法（65 CC 81）刻意**不铺**：
# 契约那一格验的是"查 NFD 不许命中 NFC"，两个都铺就验不出差别了。
find "$ROOT/flat" -name 'nfc-*' -exec rm -f {} + 2>/dev/null || true
printf 'p' > "$ROOT/flat/$(printf 'nfc-\303\251')"
printf 'x' > "$ROOT/flat/plain"

# --- degraded/：两条"字段缺失"语料 ---
#   no-mtime  与 no-perm 在**真机上无法真造**（SFTP v3 的 NAME 包会把字段给全），
#   契约里那两格会明说跳过、由内存 fake 兜住。这里照样铺两个普通文件，
#   目的是让"目录存在但条目齐全"这个形态本身也被看一眼。
printf 'm' > "$ROOT/degraded/no-mtime"
printf 'p' > "$ROOT/degraded/no-perm"

# --- transfer/：契约的写操作落点。清掉上一轮的残留，否则"截断"那一格
#     会从一个更长的旧文件开始，验的就不是"从零覆盖"了 ---
rm -f "$ROOT/transfer/"*

# --- 自检：逐条对着 ContractCorpus 验一遍，铺不出来就非零退出 ---
fail() { echo "契约语料自检失败：$1" >&2; exit 1; }
need_dir()  { [ -d "$ROOT/$1" ] || fail "缺目录 $1"; }
need_file() { [ -f "$ROOT/$1" ] || fail "缺文件 $1"; }
need_link() { [ -L "$ROOT/$1" ] || fail "缺软链 $1"; }

need_dir empty flat dir links special degraded transfer
need_dir deep/a/b/c/d
need_file dir/file
need_file deep/a/b/c/d/leaf
need_link links/rel links/abs links/broken links/loop links/loop2
need_file "special/colon:name"
need_file degraded/no-mtime degraded/no-perm

COUNT=$(ls "$ROOT/flat" | wc -l | tr -d ' ')
[ "$COUNT" -ge 1000 ] || fail "flat 只有 $COUNT 条，要求 ≥1000"

LONGNAME=n
while [ ${#LONGNAME} -lt 255 ]; do LONGNAME="${LONGNAME}n"; done
[ -f "$ROOT/flat/$LONGNAME" ] || fail "flat 里没有 255 字节名"

[ -f "$ROOT/flat/$(printf %b 'gbk-\316\304\274\376.txt')" ] || fail "flat 里没有 GBK 名"
[ -f "$ROOT/flat/$(printf 'nfc-\303\251')" ] || fail "flat 里没有 NFC 名"

# --- 属主必须是 tester ---
# `docker exec` 默认以 root 进容器，于是 `mkdir` 出来的目录全是 root:root 755。
# SFTP 登录的是 tester，于是**写入全部 permissionDenied**——第一轮跑契约时
# 传输那三格就是这么红的，而报的是"权限不足"，会把人支去查服务器权限而不是
# 查语料脚本。listing 语料不受影响（只读），所以这个坑第一次撞在写操作上。
chown -R tester:testter "$ROOT" 2>/dev/null || chown -R tester "$ROOT"

echo "契约语料就绪：$ROOT（flat $COUNT 条，属主 $(stat -c %U "$ROOT" 2>/dev/null || echo 未知)）"
INSIDE
)

FAILED=""
for c in $CONTAINERS; do
    printf '==> %s\n' "$c"
    if ! docker exec -i "$c" sh -s <<EOF
$BODY
EOF
    then
        FAILED="$FAILED $c"
    fi
done

if [ -n "$FAILED" ]; then
    echo "以下容器铺契约语料失败：$FAILED" >&2
    exit 1
fi

echo "五台（或指定容器）契约语料全部就绪。"

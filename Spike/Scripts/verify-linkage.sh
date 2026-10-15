#!/bin/bash
# 跑 spike 前确认"这个二进制里装的确实是当前 Vendor 里那份库"。
#
# 起因：M0b 有一整轮"打完补丁的复测数据"其实是拿旧二进制跑的——
# `swift build --build-path .build/out` 和已存在的 buildPath 叠加成 out/out，
# 产物路径写死在命令里，于是跑的是上一轮未打补丁的 15:30 那个文件，时间戳看不出来。
# 靠 mtime 判断不可靠（构建跳过时就复用旧文件），所以这里比内容：
# CVE 补丁引入了几个只有打完补丁才存在的字符串字面量，
# 在 vendor 归档里有、在二进制里没有，就是链到了旧产物（反之则是产物没带上补丁）。
set -u

MARKERS='ListFetch data too short|username_len out of bounds'
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRAMEWORK="$REPO/Packages/Backends/Vendor/FerrySSH.xcframework"

bin="${1:-}"
if [[ -z "$bin" || ! -f "$bin" ]]; then
    echo "用法：$0 <SpikeRunner 路径>（建议 \$(swift build --show-bin-path)/SpikeRunner，别写死）" >&2
    exit 2
fi

# 归档按当前架构取一片，避免 fat 文件里两片计数不同造成误判
arch="$(uname -m)"
slice=""
for d in "$FRAMEWORK"/*/; do
    [[ -f "${d}FerrySSH.a" ]] || continue
    if lipo -info "${d}FerrySSH.a" 2>/dev/null | grep -q "$arch"; then
        slice="${d}FerrySSH.a"
        break
    fi
done
[[ -n "$slice" ]] || { echo "vendor 归档里找不到 $arch 切片" >&2; exit 1; }

lib_hits=$(strings -a "$slice" | grep -cE "$MARKERS")
bin_hits=$(strings -a "$bin" | grep -cE "$MARKERS")

echo "二进制 $bin"
echo "  补丁标记 vendor=$lib_hits binary=$bin_hits"
if [[ "$lib_hits" -gt 0 && "$bin_hits" -eq 0 ]]; then
    echo "  → 判定：二进制链的是旧产物（vendor 已打补丁、二进制里没有）。重新构建再跑。" >&2
    exit 1
elif [[ "$lib_hits" -eq 0 && "$bin_hits" -gt 0 ]]; then
    echo "  → 判定：二进制比 vendor 新，vendor 归档反而没带补丁。检查构建是否覆盖。" >&2
    exit 1
elif [[ "$lib_hits" -eq 0 ]]; then
    echo "  → 判定：两边都无补丁标记，这是未打补丁的基线产物（对照组可用，别当成补丁版数据）。"
else
    echo "  → 判定：二进制与 vendor 一致，均含补丁标记。"
fi

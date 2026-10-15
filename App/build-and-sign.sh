#!/bin/bash
# M0b 出口项：逐层 ad-hoc 签名 + Hardened Runtime 下本地产物可启动。
#
# 做法刻意跟着发布流程走，只是把证书换成 ad-hoc：
#   1. 组 bundle（SwiftPM 出可执行体 + Info.plist + PkgInfo）
#   2. 由内向外逐个签嵌套代码，最后签主 App —— 全程不用 --deep
#   3. 验：codesign --verify --strict、-dvvv 看 flags、导 entitlements、spctl 评估、otool 看动态依赖
#   4. 启动：直接 exec 一次（拿探针输出），open 一次（拿 LaunchServices 的真实启动结果）
#   5. 分发场景：手动贴 com.apple.quarantine 再 open，量 Gatekeeper 到底拦不拦
#
# 用法：
#   App/build-and-sign.sh                                    # ad-hoc
#   FERRY_SIGN_IDENTITY="Apple Development: ..." App/build-and-sign.sh   # 用钥匙串里的正式身份
#   FERRY_HARDENED=0 App/build-and-sign.sh                   # 对照组：不开 runtime
#   App/build-and-sign.sh --no-rebuild                       # 复用现有可执行体，只重签
# 其余参数原样传给 bundle 里的探针（如 --skip-keychain）。
# 环境变量：FERRY_BUNDLE_ID / FERRY_SIGN_IDENTITY / FERRY_HARDENED / FERRY_CONFIG /
#           FERRY_ENTITLEMENTS / FERRY_PROBE_LOG / FERRY_QUARANTINE_FLAGS / FERRY_STAMP
# 探针自己的：FERRY_KC_SERVICE（换 Keychain 命名空间）/ FERRY_DLOPEN_PATH / FERRY_STAMP
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/build"
APP="$BUILD_DIR/Ferry.app"
# rm -rf 之前先确认目标在我们的构建目录里，别让人一个环境变量把仓库清了
case "$APP" in
    "$BUILD_DIR"/Ferry.app) ;;
    *) echo "APP 路径异常：$APP" >&2; exit 1 ;;
esac

BUNDLE_ID="${FERRY_BUNDLE_ID:-local.ferry.Ferry}"
IDENTITY="${FERRY_SIGN_IDENTITY:--}"          # 空 = ad-hoc（"-"）
HARDENED="${FERRY_HARDENED:-1}"
CONFIG="${FERRY_CONFIG:-debug}"
ENTITLEMENTS="${FERRY_ENTITLEMENTS:-$HERE/Support/Ferry.entitlements}"
PROBE_LOG="${FERRY_PROBE_LOG:-/tmp/ferry-probe.out}"

NO_REBUILD=0
probe_args=()
for a in "$@"; do
    if [[ "$a" == "--no-rebuild" ]]; then NO_REBUILD=1; else probe_args+=("$a"); fi
done

hr_flags=()
[[ "$HARDENED" == "1" ]] && hr_flags+=(--options runtime)
# ad-hoc 签名拿不到 secure timestamp，带 --timestamp 会直接报错，只对真身份开
ts_flags=()
[[ "$IDENTITY" != "-" ]] && ts_flags+=(--timestamp)

BIN=$(swift build --package-path "$HERE" -c "$CONFIG" --show-bin-path)/Ferry
echo "== 1. 构建可执行体（$CONFIG）"
if [[ "$NO_REBUILD" == "0" ]]; then
    swift build --package-path "$HERE" -c "$CONFIG" >/dev/null
fi
[[ -x "$BIN" ]] || { echo "找不到 $BIN" >&2; exit 1; }
echo "  $BIN  $(ls -l "$BIN" | awk '{print $5}') B"

echo "== 2. 组 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ferry"
chmod +x "$APP/Contents/MacOS/Ferry"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$HERE/Support/Info.plist.in" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
echo "  $APP  bundle id=$BUNDLE_ID"

echo "== 3. 由内向外签名（不用 --deep）"
# 找嵌套代码：dylib / framework / XPC。今天一个都没有（libssh2 与 OpenSSL 都是静态归档），
# 这个循环必须空转——空转本身就是结论：我们的产物不需要往 bundle 里塞动态库。
nested=$(find "$APP" \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' \) -print 2>/dev/null || true)
if [[ -n "$nested" ]]; then
    while IFS= read -r item; do
        echo "  签嵌套：$item"
        codesign --force --sign "$IDENTITY" "${hr_flags[@]+"${hr_flags[@]}"}" "${ts_flags[@]+"${ts_flags[@]}"}" \
            --entitlements "$ENTITLEMENTS" "$item"
    done <<< "$nested"
else
    echo "  嵌套代码 0 个（全静态）"
fi
codesign --force --sign "$IDENTITY" "${hr_flags[@]+"${hr_flags[@]}"}" "${ts_flags[@]+"${ts_flags[@]}"}" \
    --entitlements "$ENTITLEMENTS" "$APP"
echo "  签名身份：$IDENTITY   Hardened Runtime：$HARDENED   entitlements：$ENTITLEMENTS"

echo "== 4. 验签"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "  --- codesign -dvvv 关键字段"
codesign -dvvv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Signature|CDHash)=|flags=" | sed 's/^/  /'
echo "  --- 签名里带的 entitlements"
codesign -d --entitlements :- "$APP" 2>/dev/null | sed 's/^/  /' || echo "  （无）"
echo "  --- 动态依赖（非系统路径的应该一个都没有）"
otool -L "$APP/Contents/MacOS/Ferry" | tail -n +2 | grep -vE '^[[:space:]]+/(usr|System)/' \
    && echo "  ↑ 上面这些不是系统路径，得解释" || echo "  全部来自 /usr 或 /System"
echo "  --- Gatekeeper 评估"
spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/  /' || true

echo "== 5. 启动：直接 exec 拿探针结论"
set +e
"$APP/Contents/MacOS/Ferry" ${probe_args[@]+"${probe_args[@]}"} > "$PROBE_LOG" 2>&1
PROBE_RC=$?
set -e
sed 's/^/  /' "$PROBE_LOG"
echo "  探针退出码：$PROBE_RC"

echo "== 6. 启动：open（走 LaunchServices，才算『产物可启动』）"
# open 返回 0 只能证明"请求被接受"，不能证明进程真跑过；
# 探针每次运行都往 $STAMP 盖一个戳，用戳来判定"系统确实把它拉起来了"。
# 戳路径要和探针读的那个环境变量一致，否则换路径的人只会得到"没有戳"。
STAMP="${FERRY_STAMP:-/tmp/ferry-launch-stamp.txt}"
rm -f "$STAMP"
set +e
open -W -n "$APP" 2>/tmp/ferry-open.err
OPEN_RC=$?
set -e
if [[ -f "$STAMP" ]]; then
    echo "  open rc=$OPEN_RC，探针确实跑过：$(cat "$STAMP")"
else
    echo "  open rc=$OPEN_RC，但没有启动戳 —— 进程没被拉起来（或被静默拦了）"
    sed 's/^/    /' /tmp/ferry-open.err
fi

echo "== 7. 分发场景：另存一份、贴 com.apple.quarantine、再 open"
# 本机新建的文件没有隔离位，Gatekeeper 压根不介入；要量"用户从网上下到我们的包"
# 的真实表现，必须把隔离位贴到一个**没被系统记录过的新副本**上——
# 原地贴 xattr 会被 LaunchServices 的既有判定掩盖，测出来的"放行"是假的。
# flag 值用 Safari 真实写的那几个（0081/0083/0181 都试过，本机结论一致）。
GQ_DIR="$BUILD_DIR/quarantine"
ERR_LOG=/tmp/ferry-gatekeeper.err
rm -rf "$GQ_DIR"; mkdir -p "$GQ_DIR"
launch_copy() {           # $1=要 open 的 bundle，$2=人话标签
    rm -f "$STAMP"
    set +e
    open -W -n "$1" 2>"$ERR_LOG" &
    local p=$! watched=0
    while kill -0 "$p" 2>/dev/null && [[ $watched -lt 25 ]]; do sleep 1; watched=$((watched + 1)); done
    if kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
        set -e; echo "  $2：open 卡住超过 25 s —— 多半是 Gatekeeper 弹窗在等人点"; echo "WAIT"; return
    fi
    wait "$p"; local rc=$?
    set -e
    if [[ -f "$STAMP" ]]; then
        echo "  $2：open rc=$rc，有启动戳 → 跑起来了"; echo "RAN"
    else
        echo "  $2：open rc=$rc，无启动戳 → 没跑起来"; sed 's/^/    err: /' "$ERR_LOG" | head -3; echo "BLOCKED"
    fi
}
cp -R "$APP" "$GQ_DIR/"
xattr -wx com.apple.quarantine \
    "${FERRY_QUARANTINE_FLAGS:-0081};$(printf '%08x' "$(date +%s)");Safari;$(uuidgen)" "$GQ_DIR/Ferry.app"
GQ_OUT=$(launch_copy "$GQ_DIR/Ferry.app" "ad-hoc+HR 带隔离位副本")
echo "$GQ_OUT"
GQ_VERDICT=$(echo "$GQ_OUT" | tail -1)

# 对照组：同一份产物**去掉签名**再贴隔离位。如果这一层能拦住，说明隔离位与签名检查
# 在本机确实生效；那上面的"放行"就是 Gatekeeper 真放行的，不是测试没生效。
CTL_DIR="$BUILD_DIR/unsigned-control"
rm -rf "$CTL_DIR"; mkdir -p "$CTL_DIR"
cp -R "$APP" "$CTL_DIR/"
codesign --remove-signature "$CTL_DIR/Ferry.app" 2>/dev/null || true
xattr -wx com.apple.quarantine \
    "0081;$(printf '%08x' "$(date +%s)");Safari;$(uuidgen)" "$CTL_DIR/Ferry.app"
CTL_OUT=$(launch_copy "$CTL_DIR/Ferry.app" "无签名+隔离位对照组")
echo "$CTL_OUT"
CTL_VERDICT=$(echo "$CTL_OUT" | tail -1)
if [[ "$CTL_VERDICT" == "BLOCKED" ]]; then
    echo "  对照组被拦 ⇒ 本机的启动链路确实在查签名；上面 ad-hoc 的结论是有效测量"
else
    echo "  ⚠ 对照组也没拦 ⇒ 本机根本没在做这项检查，ad-hoc 那轮的『放行/拦截』都不能当结论"
fi
rm -rf "$GQ_DIR" "$CTL_DIR"

echo "== 结论"
echo "  macOS $(sw_vers -productVersion)（$(sw_vers -buildVersion)），spctl --status：$(spctl --status 2>&1 | tr -d '\n')"
echo "  探针 $PROBE_RC，open $OPEN_RC，隔离位副本 $GQ_VERDICT，无签名对照组 $CTL_VERDICT，日志 $PROBE_LOG"
[[ $PROBE_RC -eq 0 ]] || exit $PROBE_RC

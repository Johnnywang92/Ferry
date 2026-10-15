#!/usr/bin/env bash
# 构建 libssh2 + OpenSSL 3 的静态 xcframework，
# 产物 Packages/Backends/Vendor/FerrySSH.xcframework。
#
# 为什么放包内而不是仓库根 Vendor/：SwiftPM 拒绝任何越出 package root 的
# header search path（"header search path should not be outside the package root"），
# binaryTarget 的路径同样必须以包根为界。放到 Backends 包里，两边都合法。
#
# 为什么要自己建而不用 Homebrew：
#   - Homebrew 的 bottle 是动态库、版本随 brew update 漂移，且实测被链到 OpenSSL 4；
#     方案要求固定 commit + OpenSSL 3 静态链接，符号只在 Backends target 内可见。
#   - 签名与 Hardened Runtime 阶段要能证明"这个二进制来自哪个 commit"，bottle 给不出。
#
# 用法：
#   ThirdParty/build-xcframework.sh                 # 全量，arm64 + x86_64
#   ThirdParty/build-xcframework.sh --arch arm64    # 只出本机切片，调试时快一倍
#   ThirdParty/build-xcframework.sh --clean         # 清掉 build 目录重来
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=versions.env
source "$HERE/versions.env"

BUILD="$HERE/build"
OUT="$BUILD/out"
VENDOR="$REPO/Packages/Backends/Vendor"
FRAMEWORK="$VENDOR/FerrySSH.xcframework"

ARCHES=(arm64 x86_64)
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCHES=("$2"); shift 2 ;;
        --clean) DO_CLEAN=1; shift ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD" "$OUT" "$VENDOR"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
JOBS="$(sysctl -n hw.ncpu)"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# 校验钉版：tag 名字对不等于内容对，必须比 commit hash。
verify_commit() {
    local dir="$1" want="$2" name="$3"
    local got
    got="$(git -C "$dir" rev-parse HEAD)"
    if [[ "$got" != "$want" ]]; then
        echo "$name commit 不符：期望 $want 实际 $got" >&2
        exit 1
    fi
    echo "$name $got"
}

ensure_cmake() {
    if command -v cmake >/dev/null 2>&1; then
        CMAKE="$(command -v cmake)"
        echo "用系统 cmake：$($CMAKE --version | head -1)"
        return
    fi
    local dir="$BUILD/tools/cmake-$CMAKE_VERSION-macos-universal"
    local tgz="$BUILD/tools/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    if [[ ! -x "$dir/CMake.app/Contents/bin/cmake" ]]; then
        mkdir -p "$BUILD/tools"
        if [[ ! -f "$tgz" ]]; then
            log "下载 cmake $CMAKE_VERSION"
            curl -fsSL -o "$tgz" "$CMAKE_URL"
        fi
        # 官方 SHA-256 随发布件提供，本地重算比对
        local actual
        actual="$(shasum -a 256 "$tgz" | awk '{print $1}')"
        if [[ "$actual" != "$CMAKE_SHA256" ]]; then
            echo "cmake 校验失败：期望 $CMAKE_SHA256 实际 $actual" >&2
            exit 1
        fi
        tar xzf "$tgz" -C "$BUILD/tools"
    fi
    CMAKE="$dir/CMake.app/Contents/bin/cmake"
    echo "用下载的 cmake：$("$CMAKE" --version | head -1)"
}

fetch_src() {
    local url="$1" tag="$2" dir="$3"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" fetch --depth 1 origin "refs/tags/$tag" >/dev/null
        git -C "$dir" checkout --detach FETCH_HEAD >/dev/null
    else
        rm -rf "$dir"
        git clone --depth 1 --branch "$tag" "$url" "$dir" >/dev/null
    fi
}

# 1.11.1 是最新 release，但它不含任何已知 CVE 修复——修复全在 master 上且从未发版。
# 所以钉 tag 之后按序 git am 本地补丁系列，清单与来历见 ThirdParty/patches/README.md。
apply_patches() {
    local dir="$1"
    local sum="$HERE/patches/SHA256SUMS"
    [[ -f "$sum" ]] || { echo "缺 ThirdParty/patches/SHA256SUMS" >&2; exit 1; }

    # 补丁文件先自校验：内容改了忘了更新哈希，宁可在构建前停住也不要悄悄产出不同源的库
    (cd "$HERE/patches" && shasum -a 256 -c SHA256SUMS >/dev/null) || {
        echo "ThirdParty/patches 与 SHA256SUMS 对不上" >&2; exit 1; }

    PATCH_HASH="$(shasum -a 256 < "$sum" | awk '{print $1}')"

    # fetch_src 每轮都把 HEAD detach 回钉死的 commit，所以这里永远是干净基线，
    # 重复跑不会把补丁叠两层
    local applied=0 patch
    for patch in "$HERE"/patches/[0-9]*.patch; do
        [[ -e "$patch" ]] || break
        if ! git -C "$dir" -c user.name=Ferry -c user.email=ferry@localhost \
                am --quiet "$patch"; then
            echo "补丁 $(basename "$patch") 应用失败：libssh2 基线 commit 变了？" >&2
            exit 1
        fi
        applied=$((applied + 1))
    done
    echo "libssh2 安全补丁：应用 $applied 个，集束哈希 $PATCH_HASH"
    echo "打完后源码 tree：$(git -C "$dir" rev-parse 'HEAD^{tree}')"
}

# OpenSSL：只建库，不建 apps 与 tests；静态、不要 atexit 以外的默认项保持上游原样，
# 免得为了体积小动配置引出行为差异。
build_openssl() {
    local arch="$1"
    local src="$BUILD/src/openssl"
    local prefix="$OUT/openssl-$arch"
    local target
    case "$arch" in
        arm64) target=darwin64-arm64-cc ;;
        x86_64) target=darwin64-x86_64-cc ;;
        *) echo "不支持的架构 $arch" >&2; exit 2 ;;
    esac

    if [[ -f "$prefix/lib/libcrypto.a" && -f "$prefix/lib/libssl.a" && ${FORCE:-0} -eq 0 ]]; then
        echo "openssl-$arch 已存在，跳过（--clean 可重来）"
        return
    fi

    log "OpenSSL $OPENSSL_TAG [$arch] -> $target"
    rm -rf "$prefix"
    (cd "$src"
     make distclean >/dev/null 2>&1 || true
     ./Configure "$target" \
         --prefix="$prefix" \
         --libdir=lib \
         --openssldir="$prefix/ssl" \
         no-shared no-tests no-apps \
         -mmacosx-version-min="$DEPLOYMENT_TARGET" >/dev/null
     make -j"$JOBS" build_libs >/dev/null
     make install_sw >/dev/null)
}

build_libssh2() {
    local arch="$1"
    local src="$BUILD/src/libssh2"
    local bld="$BUILD/libssh2-$arch"
    local prefix="$OUT/libssh2-$arch"
    local ossl="$OUT/openssl-$arch"

    # 补丁集变了就必须重编，否则改了 patches/ 却复用旧 libssh2.a，
    # 产出的库跟补丁清单对不上——这类不一致比编译失败难查得多。
    if [[ -f "$prefix/lib/libssh2.a" && ${FORCE:-0} -eq 0
          && -f "$prefix/patches.sha256" && "$(cat "$prefix/patches.sha256")" == "$PATCH_HASH" ]]; then
        echo "libssh2-$arch 已存在，跳过"
        return
    fi

    log "libssh2 $LIBSSH2_TAG [$arch]"
    rm -rf "$bld" "$prefix"
    mkdir -p "$prefix/lib" "$prefix/include"
    "$CMAKE" -S "$src" -B "$bld" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        -DOPENSSL_ROOT_DIR="$ossl" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
    # 目标名随配置变：只建静态库时产物是 libssh2.a，同时开 shared 时才叫 libssh2_static.a。
    # 这里不用 --target 指定名字（1.11.1 里它随 BUILD_SHARED_LIBS 变化），直接建默认目标。
    "$CMAKE" --build "$bld" -- -j"$JOBS" >/dev/null

    local found
    found="$(find "$bld" -name "libssh2.a" -o -name "libssh2_static.a" | head -1)"
    if [[ -z "$found" ]]; then
        echo "libssh2 [$arch] 没找到静态库产物" >&2
        exit 1
    fi
    cp "$found" "$prefix/lib/libssh2.a"
    # 头文件不走 cmake --install：它要 install 目标存在且会连带装 examples，
    # 上游这三个头本来就是源码 include/ 里的原样文件。
    cp "$src/include/"*.h "$prefix/include/"
    # 打完补丁的构建才允许被复用，所以把补丁集哈希钉在产物旁边当指纹
    echo "$PATCH_HASH" > "$prefix/patches.sha256"
    echo "libssh2 [$arch]：$(lipo -info "$prefix/lib/libssh2.a")"
}

ensure_cmake

log "取源码"
fetch_src "$OPENSSL_REPO" "$OPENSSL_TAG" "$BUILD/src/openssl"
verify_commit "$BUILD/src/openssl" "$OPENSSL_COMMIT" "openssl"
fetch_src "$LIBSSH2_REPO" "$LIBSSH2_TAG" "$BUILD/src/libssh2"
verify_commit "$BUILD/src/libssh2" "$LIBSSH2_COMMIT" "libssh2"
apply_patches "$BUILD/src/libssh2"

for arch in "${ARCHES[@]}"; do
    build_openssl "$arch"
    build_libssh2 "$arch"
done

log "合并静态库"
MERGED="$OUT/merged"
rm -rf "$MERGED"
mkdir -p "$MERGED"

# 先逐架构 lipo，再 libtool 合成一个 .a：
# xcframework 同一平台只收一个 library，三个 .a 分开塞会被 xcodebuild 判成架构重叠。
for lib in libssh2 libcrypto libssl; do
    parts=()
    for arch in "${ARCHES[@]}"; do
        case "$lib" in
            libssh2) parts+=("$OUT/libssh2-$arch/lib/libssh2.a") ;;
            *) parts+=("$OUT/openssl-$arch/lib/${lib}.a") ;;
        esac
    done
    lipo -create "${parts[@]}" -output "$MERGED/${lib}.a"
done
libtool -static -o "$MERGED/FerrySSH.a" \
    "$MERGED/libssh2.a" "$MERGED/libcrypto.a" "$MERGED/libssl.a"

HEADERS="$OUT/merged/Headers"
mkdir -p "$HEADERS"
cp "$OUT/libssh2-${ARCHES[0]}/include/"*.h "$HEADERS/"

log "生成 xcframework"
rm -rf "$FRAMEWORK"
xcodebuild -create-xcframework \
    -library "$MERGED/FerrySSH.a" -headers "$HEADERS" \
    -output "$FRAMEWORK"

# 来源凭证：SecurityBaseline.md 与诊断报告都要能回答"这个二进制是什么编出来的"
{
    echo "构建时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "主机：$(uname -m) macOS $(sw_vers -productVersion) SDK $(xcrun --sdk macosx --show-sdk-version)"
    echo "架构：${ARCHES[*]}  部署目标：$DEPLOYMENT_TARGET"
    echo "openssl: $OPENSSL_TAG $(git -C "$BUILD/src/openssl" rev-parse HEAD)"
    echo "libssh2: $LIBSSH2_TAG $LIBSSH2_COMMIT（上游钉版 commit）"
    echo "libssh2 补丁集: sha256=$PATCH_HASH 共 $(ls "$HERE"/patches/[0-9]*.patch 2>/dev/null | wc -l | tr -d ' ') 个，清单见 ThirdParty/patches/README.md"
    # 只记 tree，不记 git am 产生的 HEAD：HEAD 的 committer 时间戳是"本次构建时刻"，换台机器就不一样，
    # 拿它做对照永远对不上；tree 不含提交者信息，同一补丁集必然同值。
    echo "libssh2 打完补丁的源码 tree: $(git -C "$BUILD/src/libssh2" rev-parse 'HEAD^{tree}')"
    echo "cmake: $CMAKE_VERSION sha256=$CMAKE_SHA256"
    # 这个哈希是"本次构建的身份证号"，用来把产物和这份日志对上（诊断包、CI 缓存），不是可复现性校验和。
    # 实测：libtool -static 每次调用都给归档成员写入当下时间戳，同样的输入连跑两次结果不同
    # （同一秒内跑两次才相同）。所以"重建一遍再比 sha256"必然失败，别拿它当完整性锚点。
    # 要复现内容一致，钉的是上面三行：tag+commit、补丁集 sha256、打完补丁的源码 tree。
    echo "FerrySSH.a sha256=$(shasum -a 256 "$MERGED/FerrySSH.a" | awk '{print $1}')（本次构建实例，非可复现校验和）"
    echo "FerrySSH.a：$(lipo -info "$MERGED/FerrySSH.a" | sed 's/^Architecture[s]*: //') $(du -h "$MERGED/FerrySSH.a" | awk '{print $1}')"
} > "$VENDOR/provenance.txt"
cat "$VENDOR/provenance.txt"

log "完成：$FRAMEWORK"

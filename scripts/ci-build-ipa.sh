#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
IOS_MIN="16.4"
LLVM_VERSION="15.0.7"
LLVM_MINGW_VERSION="20260421"
LLVM_MINGW_DIR="$ROOT/toolchains/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
LLVM_PROJECT_DIR="$ROOT/toolchains/llvm-project"
LLVM_HOST_BUILD="$ROOT/toolchains/llvm-host-build"
LLVM_IOS_BUILD="$ROOT/toolchains/llvm-ios-build"
GNUTLS_SRC_DIR="$ROOT/build/gnutls-ios/src"

export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"

download() {
    local url="$1"
    local output="$2"
    if [[ ! -s "$output" ]]; then
        echo "==> Downloading $(basename "$output")"
        curl --fail --location --retry 3 --retry-delay 2 --output "$output" "$url"
    fi
}

echo "==> Installing build dependencies"
for formula in autoconf automake libtool bison flex cmake ninja meson pkg-config; do
    brew list "$formula" >/dev/null 2>&1 || brew install "$formula"
done

mkdir -p "$ROOT/toolchains" "$ROOT/research/freetype" "$GNUTLS_SRC_DIR"

if [[ ! -x "$LLVM_MINGW_DIR/bin/aarch64-w64-mingw32-clang" ]]; then
    download \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal.tar.xz" \
        "$ROOT/toolchains/llvm-mingw.tar.xz"
    tar -xJf "$ROOT/toolchains/llvm-mingw.tar.xz" -C "$ROOT/toolchains"
fi
export PATH="$LLVM_MINGW_DIR/bin:$PATH"

if [[ ! -d "$ROOT/research/freetype/include" ]]; then
    rm -rf "$ROOT/research/freetype"
    git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git "$ROOT/research/freetype"
fi

download "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz" "$GNUTLS_SRC_DIR/gmp-6.3.0.tar.xz"
download "https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz" "$GNUTLS_SRC_DIR/nettle-3.10.1.tar.gz"
download "https://ftp.gnu.org/gnu/gnutls/v3.8/gnutls-3.8.9.tar.xz" "$GNUTLS_SRC_DIR/gnutls-3.8.9.tar.xz"

echo "==> Downloading Metal toolchain component"
xcodebuild -downloadComponent MetalToolchain || true

echo "==> Building LLVM tblgen host tool and iOS static libraries"
if [[ ! -f "$LLVM_PROJECT_DIR/llvm/CMakeLists.txt" ]]; then
    rm -rf "$LLVM_PROJECT_DIR"
    git clone --depth 1 --branch "llvmorg-${LLVM_VERSION}" --filter=blob:none --sparse \
        https://github.com/llvm/llvm-project.git "$LLVM_PROJECT_DIR"
    git -C "$LLVM_PROJECT_DIR" sparse-checkout set llvm cmake third-party
fi

LLVM_ADDLLVM="$LLVM_PROJECT_DIR/llvm/cmake/modules/AddLLVM.cmake"
if ! grep -q 'MATCHES "Darwin|iOS"' "$LLVM_ADDLLVM"; then
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' "$LLVM_ADDLLVM"
fi

if [[ ! -x "$LLVM_HOST_BUILD/bin/llvm-tblgen" ]]; then
    cmake -S "$LLVM_PROJECT_DIR/llvm" -B "$LLVM_HOST_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_BUILD_TOOLS=ON \
        -DLLVM_BUILD_UTILS=ON \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF
    cmake --build "$LLVM_HOST_BUILD" --target llvm-tblgen -j "$JOBS"
fi

if [[ ! -d "$LLVM_IOS_BUILD/lib" || -z "$(find "$LLVM_IOS_BUILD/lib" -name '*.a' -print -quit 2>/dev/null)" ]]; then
    cmake -S "$LLVM_PROJECT_DIR/llvm" -B "$LLVM_IOS_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
        -DLLVM_TARGETS_TO_BUILD= \
        -DLLVM_TABLEGEN="$LLVM_HOST_BUILD/bin/llvm-tblgen" \
        -DLLVM_NATIVE_TOOL_DIR="$LLVM_HOST_BUILD/bin" \
        -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF
    cmake --build "$LLVM_IOS_BUILD" -j "$JOBS"
fi

echo "==> Building FEXCore for iOS"
cmake -S "$ROOT/FEX" -B "$ROOT/FEX/build-ios" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DBUILD_STEAM_SUPPORT=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_FEXCONFIG=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_CCACHE=OFF \
    -DENABLE_GDB_SYMBOLS=OFF \
    -DENABLE_VIXL_DISASSEMBLER=OFF \
    -DENABLE_ZYDIS=OFF \
    -DENABLE_FEX_ALLOCATOR=OFF \
    -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DTUNE_CPU=none \
    -DTUNE_ARCH=generic
cmake --build "$ROOT/FEX/build-ios" \
    --target FEXCore FEXCore_Base JemallocLibs softfloat_3e cephes_128bit \
    -j "$JOBS"

echo "==> Configuring and building Wine host tools and base libraries"
pushd "$ROOT/wine" >/dev/null
./tools/make_requests
./tools/make_specfiles
./tools/make_makefiles
autoreconf -f
mkdir -p build-macos
if [[ ! -f build-macos/Makefile ]]; then
    pushd build-macos >/dev/null
    ../configure -C \
        --enable-win64 \
        --enable-archs=arm64ec,aarch64 \
        --with-mingw=llvm-mingw \
        --with-x=no \
        BISON="$(brew --prefix bison)/bin/bison"
    popd >/dev/null
fi
make -C build-macos -j "$JOBS"
if [[ ! -e build-arm64ec ]]; then
    ln -s build-macos build-arm64ec
fi
popd >/dev/null

if [[ ! -s "$ROOT/wine/build-macos/server/libwineserver.a" ]]; then
    echo "error: Wine did not produce server/libwineserver.a" >&2
    exit 1
fi
cp "$ROOT/wine/build-macos/server/libwineserver.a" "$ROOT/app/Madeira/libwineserver.a"

echo "==> Building iOS support libraries"
bash "$ROOT/build/gnutls-ios/build.sh"
bash "$ROOT/build/freetype-ios/build.sh"
bash "$ROOT/build/ntdll-unix/build.sh"
bash "$ROOT/build/wineserver/build.sh"
bash "$ROOT/build/win32u-unix/build.sh"

echo "==> Building DXMT iOS unix archive"
bash "$ROOT/build/dxmt-ios/build.sh"

echo "==> Combining DXMT and LLVM iOS archives"
if [[ ! -s "$ROOT/app/libdxmt_unix.a" ]]; then
    echo "error: app/libdxmt_unix.a is missing; build DXMT before running this workflow" >&2
    exit 1
fi
xcrun -sdk iphoneos libtool -static \
    -o "$ROOT/app/Madeira/libdxmt_combined.a" \
    "$ROOT/app/libdxmt_unix.a" \
    "$LLVM_IOS_BUILD/lib"/*.a

echo "==> Archiving unsigned iOS app"
rm -rf "$ROOT/build/DerivedData" "$ROOT/build/Madeira.xcarchive" "$ROOT/build/ipa"
xcodebuild \
    -project "$ROOT/app/Madeira.xcodeproj" \
    -scheme Madeira \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -archivePath "$ROOT/build/Madeira.xcarchive" \
    archive \
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

APP_PATH="$ROOT/build/Madeira.xcarchive/Products/Applications/Madeira.app"
[[ -d "$APP_PATH" ]] || { echo "error: Xcode archive did not contain Madeira.app" >&2; exit 1; }
mkdir -p "$ROOT/build/ipa/Payload"
cp -R "$APP_PATH" "$ROOT/build/ipa/Payload/"
(cd "$ROOT/build/ipa" && zip -qry "$ROOT/build/Madeira-unsigned.ipa" Payload)

echo "==> IPA created"
ls -lh "$ROOT/build/Madeira-unsigned.ipa"
unzip -l "$ROOT/build/Madeira-unsigned.ipa" | sed -n '1,20p'

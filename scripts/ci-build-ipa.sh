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
for formula in autoconf automake libtool bison flex cmake ninja meson pkg-config sevenzip; do
    brew list "$formula" >/dev/null 2>&1 || brew install "$formula"
done

mkdir -p "$ROOT/toolchains" "$ROOT/research/freetype" "$GNUTLS_SRC_DIR"

echo "==> Preparing Microsoft x86-64 VC runtime DLLs"
VCRT_DIR="$ROOT/app/Madeira/x86_64-vcruntime"
VCRT_NAMES=(
    concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait
    msvcp140_codecvt_ids vcamp140 vccorlib140 vcomp140 vcruntime140
    vcruntime140_1 vcruntime140_threads
)
missing_vcrt=0
for name in "${VCRT_NAMES[@]}"; do
    [[ -s "$VCRT_DIR/$name.dll" ]] || missing_vcrt=1
done
if [[ "$missing_vcrt" -ne 0 ]]; then
    VCRT_WORK="$(mktemp -d)"
    curl --fail --location --retry 3 --output "$VCRT_WORK/vc_redist.x64.exe" \
        https://aka.ms/vs/17/release/vc_redist.x64.exe
    python3 - "$VCRT_WORK/vc_redist.x64.exe" "$VCRT_WORK" <<'PY'
import re, sys
data = open(sys.argv[1], 'rb').read()
for i, match in enumerate(re.finditer(b'MSCF\x00\x00\x00\x00', data)):
    open(f'{sys.argv[2]}/carve{i}.cab', 'wb').write(data[match.start():])
print('carved', len(list(re.finditer(b'MSCF\x00\x00\x00\x00', data))), 'cabinet(s)')
PY
    for cab in "$VCRT_WORK"/carve*.cab; do
        7zz x "$cab" -o"${cab}.x" -y >/dev/null 2>&1 || true
    done
    for pass in 1 2 3; do
        expanded=0
        while IFS= read -r file; do
            out="${file}.x"
            [[ -d "$out" ]] && continue
            if 7zz x "$file" -o"$out" -y >/dev/null 2>&1; then
                expanded=1
            else
                rm -rf "$out"
            fi
        done < <(find "$VCRT_WORK" -type f -size +4k \
            ! -name 'vc_redist.x64.exe' ! -name 'carve*.cab')
        [[ "$expanded" -eq 0 ]] && break
    done
    mkdir -p "$VCRT_DIR"
    python3 - "$VCRT_WORK" "$VCRT_DIR" <<'PY'
import os, re, shutil, sys
root, dest = sys.argv[1:]
want = {
    'concrt140', 'msvcp140', 'msvcp140_1', 'msvcp140_2',
    'msvcp140_atomic_wait', 'msvcp140_codecvt_ids', 'vcamp140',
    'vccorlib140', 'vcomp140', 'vcruntime140', 'vcruntime140_1',
    'vcruntime140_threads',
}
found = {}
for current, _, files in os.walk(root):
    for filename in files:
        if 'arm64' in filename.lower():
            continue
        path = os.path.join(current, filename)
        try:
            with open(path, 'rb') as handle:
                if handle.read(2) != b'MZ':
                    continue
        except OSError:
            continue
        key = re.sub(r'^f_central_', '', filename.lower())
        key = re.sub(r'_(amd64|x64)$', '', key)
        key = re.sub(r'\.dll$', '', key)
        key = re.sub(r'_(amd64|x64)$', '', key)
        if key in want and key not in found:
            found[key] = path
for key, path in found.items():
    shutil.copy2(path, os.path.join(dest, key + '.dll'))
missing = sorted(want - set(found))
if missing:
    print('missing VC runtime DLLs:', ', '.join(missing))
    raise SystemExit(1)
print('prepared', len(found), 'VC runtime DLLs')
PY
    rm -rf "$VCRT_WORK"
fi

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

SDK_MAJOR="$(xcrun --sdk iphoneos --show-sdk-version | cut -d. -f1)"
if [[ "$SDK_MAJOR" -lt 26 ]]; then
    echo "==> Removing Liquid Glass calls unavailable in this SDK"
    python3 - "$ROOT/app/Madeira/ContentView.swift" <<'PY'
import re, sys

path = sys.argv[1]
source = open(path).read()
updated = re.sub(r'\.glassEffect\([^()]*(?:\([^()]*\)[^()]*)*\)', '', source)
print('removed', source.count('.glassEffect(') - updated.count('.glassEffect('), 'glassEffect call(s)')
open(path, 'w').write(updated)
if '.glassEffect(' in updated:
    raise SystemExit('ERROR: glassEffect calls remain')
PY
fi

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
        -DCMAKE_MACOSX_BUNDLE=OFF \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_TABLEGEN="$LLVM_HOST_BUILD/bin/llvm-tblgen" \
        -DLLVM_NATIVE_TOOL_DIR="$LLVM_HOST_BUILD/bin" \
        -DLLVM_INCLUDE_TOOLS=OFF \
        -DLLVM_INCLUDE_UTILS=OFF \
        -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_RUNTIMES=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF
    cmake --build "$LLVM_IOS_BUILD" -j "$JOBS"
fi

echo "==> Building FEXCore for iOS"
python3 - "$ROOT/FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = 'MADEIRA_CASPAL_STUB'
signature = 'static void IosLogUnimplementedCASPAL(uint32_t Size, uint64_t* GPRs, uint32_t AddressReg) {'
if marker not in source:
    start = source.find(signature)
    if start == -1:
        raise SystemExit('ERROR: IosLogUnimplementedCASPAL not found')
    end = source.find('\n}\n', start)
    if end == -1:
        raise SystemExit('ERROR: could not find IosLogUnimplementedCASPAL end')
    replacement = (signature + '\n'
                   '  /* MADEIRA_CASPAL_STUB: the original diagnostic uses Win32 '
                   'VirtualQuery, unavailable on iOS. */\n'
                   '  (void)Size; (void)GPRs; (void)AddressReg;\n')
    path.write_text(source[:start] + replacement + source[end + 1:])
    print('stubbed IosLogUnimplementedCASPAL for iOS')
else:
    print('IosLogUnimplementedCASPAL already stubbed')
PY
cmake -S "$ROOT/FEX" -B "$ROOT/FEX/build-ios" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS="-DFEX_IOS_HOST=1" \
    -DCMAKE_CXX_FLAGS="-DFEX_IOS_HOST=1" \
    -DBUILD_TESTING=OFF \
    -DBUILD_TESTS=False \
    -DBUILD_THUNKS=OFF \
    -DENABLE_LTO=False \
    -DENABLE_CCACHE=OFF \
    -DENABLE_VIXL_DISASSEMBLER=OFF \
    -DENABLE_VIXL_SIMULATOR=OFF \
    -DTUNE_CPU=none \
    -DTUNE_ARCH=generic
cmake --build "$ROOT/FEX/build-ios" \
    --target FEXCore FEXCore_Base JemallocLibs softfloat_3e cephes_128bit \
    -j "$JOBS"
for library in libFEXCore.a libFEXCore_Base.a libJemallocLibs.a libfmt.a libcephes_128bit.a libxxhash.a libsoftfloat_3e.a; do
    find "$ROOT/FEX/build-ios" -name "$library" -type f -print -quit | grep -q . \
        || { echo "error: missing FEX library $library" >&2; exit 1; }
done

echo "==> Configuring and building Wine host tools and base libraries"
pushd "$ROOT/wine" >/dev/null
./tools/make_requests
./tools/make_specfiles
./tools/make_makefiles
autoreconf -f
mkdir -p build-macos
if [[ ! -f build-macos/Makefile ]]; then
    pushd build-macos >/dev/null
    ../configure \
        --enable-win64 \
        --disable-tests \
        --without-x \
        --without-freetype
    popd >/dev/null
fi
make -C build-macos -k -j "$JOBS" 2>&1 | tail -40 || true

CRT0="$(find build-macos -name libwinecrt0.a -print -quit)"
if [[ -z "$CRT0" ]]; then
    echo "==> Building missing Wine ARM64 Windows CRT archive"
    make -C build-macos -j "$JOBS" \
        dlls/winecrt0/aarch64-windows/libwinecrt0.a || true
    CRT0="$(find build-macos -name libwinecrt0.a -print -quit)"
fi
[[ -n "$CRT0" ]] || { echo "error: Wine did not produce libwinecrt0.a" >&2; exit 1; }
[[ -f build-macos/include/config.h ]] || { echo "error: Wine config.h missing" >&2; exit 1; }

if ! ls build-macos/include/dwrite*.h >/dev/null 2>&1; then
    echo "==> Generating missing Wine DirectWrite headers"
    make -C build-macos include/dwrite.h include/dwrite_1.h include/dwrite_2.h include/dwrite_3.h || true
fi
ls build-macos/include/dwrite*.h >/dev/null 2>&1 \
    || { echo "error: Wine DirectWrite headers missing" >&2; exit 1; }

if [[ ! -e build-arm64ec ]]; then
    ln -s build-macos build-arm64ec
fi
popd >/dev/null

echo "==> Seeding wineserver base archive"
WINE_SERVER_OBJ="$ROOT/build/wineserver/obj"
if [[ ! -s "$WINE_SERVER_OBJ/libwineserver.a" ]]; then
    mkdir -p "$WINE_SERVER_OBJ/base"
    WINE_SERVER_FLAGS=(
        -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -miphoneos-version-min="$IOS_MIN" -O2
        -I"$ROOT/wine/include" -I"$ROOT/wine/include/wine"
        -I"$ROOT/wine/build-macos/include" -I"$ROOT/build/wineserver"
        -I"$ROOT/wine/server" -I"$ROOT/build/ntdll-unix/shims"
        -include "$ROOT/build/wineserver/config_ios.h"
        -include stdarg.h
        -include "$ROOT/build/wineserver/unicode_fix.h"
        -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
        -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main
        -Wno-implicit-function-declaration
    )
    base_ok=0
    base_failed=0
    for source in "$ROOT/wine/server"/*.c; do
        name="$(basename "$source" .c)"
        if xcrun -sdk iphoneos clang "${WINE_SERVER_FLAGS[@]}" \
            -c "$source" -o "$WINE_SERVER_OBJ/base/$name.o" \
            2>"$WINE_SERVER_OBJ/base/$name.err"; then
            base_ok=$((base_ok + 1))
        else
            base_failed=$((base_failed + 1))
        fi
    done
    echo "wineserver base: $base_ok compiled, $base_failed failed"
    find "$WINE_SERVER_OBJ/base" -name '*.o' -print -quit | grep -q . \
        || { echo "error: no wineserver objects compiled" >&2; exit 1; }
    ar rcs "$WINE_SERVER_OBJ/libwineserver.a" "$WINE_SERVER_OBJ/base"/*.o
fi

echo "==> Building iOS support libraries"
bash "$ROOT/build/gnutls-ios/build.sh"
bash "$ROOT/build/freetype-ios/build.sh"
bash "$ROOT/build/ntdll-unix/build.sh"
bash "$ROOT/build/wineserver/build.sh"
bash "$ROOT/build/win32u-unix/build.sh"

echo "==> Generating DXMT Metal shader headers"
DXMT_SHADER_HEADERS="$ROOT/build/dxmt-ios/shader-headers"
DXMT_SHADER_SOURCES="$ROOT/research/dxmt/src/airconv/shaders"
mkdir -p "$DXMT_SHADER_HEADERS"
for metal_source in "$DXMT_SHADER_SOURCES"/*.metal; do
    shader_name="$(basename "$metal_source" .metal)"
    air_file="$DXMT_SHADER_HEADERS/$shader_name.air"
    header_file="$DXMT_SHADER_HEADERS/$shader_name.h"
    xcrun -sdk macosx metal -o "$air_file" -c "$metal_source" \
        -std=metal3.1 --target=air64-apple-macos14.0
    python3 - "$air_file" "$header_file" "$shader_name" <<'PY'
import sys

air_path, header_path, name = sys.argv[1:]
data = open(air_path, 'rb').read()
rows = [', '.join(f'0x{byte:02x}' for byte in data[i:i + 12])
        for i in range(0, len(data), 12)]
with open(header_path, 'w') as header:
    header.write(f'unsigned char {name}[] = {{\n  ')
    header.write(',\n  '.join(rows))
    header.write(f'\n}};\nunsigned int {name}_len = {len(data)};\n')
print(f'{air_path} -> {header_path} ({len(data)} bytes)')
PY
done

echo "==> Building DXMT Windows PE modules"
ln -sfn ../../toolchains "$ROOT/research/dxmt/toolchains"
export PATH="$LLVM_MINGW_DIR/bin:/opt/homebrew/bin:$PATH"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
pushd "$ROOT/research/dxmt" >/dev/null
rm -rf build-pe
meson setup --cross-file build-aarch64-win.txt --native-file build-osx.txt \
    -Dwine_build_path=../../wine/build-macos build-pe
meson compile -C build-pe
mkdir -p "$ROOT/app/Madeira/aarch64-windows"
cp build-pe/src/d3d11/d3d11.dll \
    build-pe/src/dxgi/dxgi.dll \
    build-pe/src/winemetal/winemetal.dll \
    build-pe/src/d3d10/d3d10core.dll \
    "$ROOT/app/Madeira/aarch64-windows/"
popd >/dev/null

echo "==> Building DXMT iOS unix archive"
bash "$ROOT/build/dxmt-ios/build.sh"

echo "==> Combining DXMT and LLVM iOS archives"
DXMT_UNIX_LIB="$ROOT/build/dxmt-ios/libdxmt_unix.a"
if [[ ! -s "$DXMT_UNIX_LIB" ]]; then
    echo "error: freshly built DXMT archive is missing" >&2
    exit 1
fi
xcrun -sdk iphoneos libtool -static \
    -o "$ROOT/app/Madeira/libdxmt_combined.a" \
    "$DXMT_UNIX_LIB" \
    "$LLVM_IOS_BUILD/lib"/*.a

echo "==> Building unsigned iOS app"
rm -rf "$ROOT/build/out" "$ROOT/build/ipa"
xcodebuild \
    -project "$ROOT/app/Madeira.xcodeproj" \
    -target Madeira \
    -configuration Release \
    -sdk iphoneos \
    CONFIGURATION_BUILD_DIR="$ROOT/build/out" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

APP_PATH="$ROOT/build/out/Madeira.app"
[[ -d "$APP_PATH" ]] || { echo "error: Xcode build did not contain Madeira.app" >&2; exit 1; }
mkdir -p "$ROOT/build/ipa/Payload"
cp -R "$APP_PATH" "$ROOT/build/ipa/Payload/"
(cd "$ROOT/build/ipa" && zip -qry "$ROOT/build/Madeira-unsigned.ipa" Payload)

echo "==> IPA created"
lipo -info "$APP_PATH/Madeira"
ls -lh "$ROOT/build/Madeira-unsigned.ipa"
unzip -l "$ROOT/build/Madeira-unsigned.ipa" | sed -n '1,20p'

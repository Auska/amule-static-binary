#!/bin/bash
# build.sh
#
# Compiles fully-static aMule binaries inside an Alpine Linux container.
#
# Required environment variables:
#   VERSION_NUM   aMule version without the leading 'v' (e.g. 3.0.0)
#   AMULE_SHA     Git commit hash for aMule nightly build (e.g. 1a2b3c4d)
#   ARCH          Output filename suffix identifying the target CPU
#                 (e.g. amd64 or arm64)
# Optional environment variables:
#   SUFFIX        Extra suffix for the output filename

set -eux

: "${VERSION_NUM:=}"
: "${AMULE_SHA:=}"
: "${ARCH:?ARCH must be set (e.g. amd64 or arm64)}"
: "${SUFFIX:=}"

if [ -z "${VERSION_NUM}" ] && [ -z "${AMULE_SHA}" ]; then
    echo "VERSION_NUM must be set for release builds, or AMULE_SHA for nightly builds." >&2
    exit 1
fi

# Architecture-specific compiler flags
case "${ARCH}" in
    amd64 | x86_64)
        ARCH_CFLAGS="-march=x86-64-v2"
        ZLIB_AVX2="OFF"
        ;;
    amd64-gracemont | x86_64-gracemont)
        ARCH_CFLAGS="-march=gracemont -mtune=gracemont"
        ZLIB_AVX2="ON"
        ;;
    amd64-tremont | x86_64-tremont)
        ARCH_CFLAGS="-march=tremont -mtune=tremont"
        ZLIB_AVX2="OFF"
        ;;
    amd64-v3 | x86_64-v3)
        ARCH_CFLAGS="-march=x86-64-v3"
        ZLIB_AVX2="ON"
        ;;
    arm64 | aarch64)
        ARCH_CFLAGS="-march=armv8-a"
        ZLIB_AVX2="OFF"
        ;;
    *)
        ARCH_CFLAGS=""
        ZLIB_AVX2="OFF"
        ;;
esac
BASE_CFLAGS="${ARCH_CFLAGS} -static -O3 -pipe"

# System packages
apk add --no-cache \
    autoconf autoconf-archive automake bash build-base cmake cppunit-dev \
    curl gawk gettext-dev git jq libtool linux-headers ninja pkgconf python3 bison flex

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ============================================================================
# Part 1 — Fetch version information
# ============================================================================

MUSL_VERSION=$(curl -fsS "https://api.github.com/repos/ifduyue/musl/tags?per_page=10" | jq -r '.[].name' | sed 's/^v//' | sort -V | tail -1)
echo "musl: ${MUSL_VERSION}"

RPMALLOC_VERSION=$(curl -fsS "https://api.github.com/repos/mjansson/rpmalloc/releases/latest" | jq -r '.tag_name')
echo "rpmalloc: ${RPMALLOC_VERSION}"

ZLIB_NG_VERSION=$(curl -fsS "https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest" | jq -r '.tag_name')
echo "zlib-ng: ${ZLIB_NG_VERSION}"

LIBRESSL_VERSION=$(curl -fsS "https://api.github.com/repos/libressl/portable/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "libressl: ${LIBRESSL_VERSION}"

NGHTTP2_VERSION=$(curl -fsS "https://api.github.com/repos/nghttp2/nghttp2/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "nghttp2: ${NGHTTP2_VERSION}"

LIBPSL_VERSION=$(curl -fsS "https://api.github.com/repos/rockdaboot/libpsl/releases/latest" | jq -r '.tag_name')
echo "libpsl: ${LIBPSL_VERSION}"

CARES_VERSION=$(curl -fsS "https://api.github.com/repos/c-ares/c-ares/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "c-ares: ${CARES_VERSION}"

CURL_TAG=$(curl -fsS "https://api.github.com/repos/curl/curl/releases/latest" | jq -r '.tag_name')
CURL_VERSION=$(echo "$CURL_TAG" | sed 's/curl-//' | tr '_' '.')
echo "curl: ${CURL_VERSION}"

# Boost: use source archive with standard boost/ header layout
BOOST_VERSION=$(curl -fsS "https://api.github.com/repos/boostorg/boost/releases?per_page=10" |
    jq -r '[.[] | select(.tag_name | test("beta") | not) | .tag_name][0]')
echo "boost: ${BOOST_VERSION}"

CRYPTOPP_VERSION=$(curl -fsS "https://api.github.com/repos/cryptopp-modern/cryptopp-modern/tags?per_page=10" | jq -r '.[].name' | sort -V | tail -1)
echo "cryptopp: ${CRYPTOPP_VERSION}"

WXWIDGETS_VERSION=$(curl -fsS "https://api.github.com/repos/wxWidgets/wxWidgets/releases" |
    jq -r '[.[] | select(.tag_name | startswith("v3.2")) | .tag_name][0]')
echo "wxwidgets: ${WXWIDGETS_VERSION}"
WX_VERSION_STRIP="${WXWIDGETS_VERSION#v}"

READLINE_VERSION=$(curl -fsSL "https://ftp.gnu.org/gnu/readline/" |
    grep -o 'readline-[0-9]\+\.[0-9]\+\.tar\.gz' | sed 's/readline-//;s/\.tar\.gz//' | sort -V | tail -1)
echo "readline: ${READLINE_VERSION}"

LIBPNG_TAG=$(curl -fsS "https://api.github.com/repos/pnggroup/libpng/git/matching-refs/tags/v1.6" |
    jq -r '[.[].ref | split("/")[2] | select(test("rc|beta|alpha") | not)] | .[]' | sort -V | tail -1)
echo "libpng: ${LIBPNG_TAG}"

GD_VERSION=$(curl -fsS "https://api.github.com/repos/libgd/libgd/tags?per_page=20" |
    jq -r '[.[].name | select(test("^gd-"))] | .[]' | sort -V | tail -1)
echo "libgd: ${GD_VERSION}"

PUPNP_VERSION=$(curl -fsS "https://api.github.com/repos/pupnp/pupnp/releases/latest" | jq -r '.tag_name')
echo "pupnp: ${PUPNP_VERSION}"

# ============================================================================
# Part 2 — Download and extract source archives
# ============================================================================
mkdir -p /build
cd /build

# musl
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/ifduyue/musl/archive/refs/tags/v${MUSL_VERSION}.tar.gz"
tar xf "v${MUSL_VERSION}.tar.gz"
# GitHub archive extracts to "musl-{sha}" but we need a fixed dirname
mkdir -p "musl-${MUSL_VERSION}" && cd "musl-${MUSL_VERSION}"
tar xf "/build/v${MUSL_VERSION}.tar.gz" --strip-components=1
cd /build

# rpmalloc
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/mjansson/rpmalloc/archive/refs/tags/${RPMALLOC_VERSION}.tar.gz"
tar xf "${RPMALLOC_VERSION}.tar.gz"

# zlib-ng
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz"
tar xf "${ZLIB_NG_VERSION}.tar.gz"

# libressl
curl -fsSLO --retry 5 --retry-delay 10 "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"
tar xf "libressl-${LIBRESSL_VERSION}.tar.gz"

# nghttp2
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/nghttp2/nghttp2/archive/refs/tags/v${NGHTTP2_VERSION}.tar.gz"
tar xf "v${NGHTTP2_VERSION}.tar.gz"

# ncurses (generic URL, determine dir after extract)
curl -fsSLO --retry 5 --retry-delay 10 "https://invisible-island.net/archives/ncurses/ncurses.tar.gz"
tar xf ncurses.tar.gz
NCURSES_DIR=$(tar tzf ncurses.tar.gz | head -1 | cut -d/ -f1)

# libpsl
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VERSION}/libpsl-${LIBPSL_VERSION}.tar.gz"
tar xf "libpsl-${LIBPSL_VERSION}.tar.gz"

# c-ares
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz"
tar xf "c-ares-${CARES_VERSION}.tar.gz"

# curl
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/curl/curl/archive/refs/tags/curl-${CURL_VERSION//./_}.tar.gz"
tar xf "curl-${CURL_VERSION//./_}.tar.gz"

# Boost (cmake tarball from GitHub Releases)
BOOST_CMAKE_FILE="${BOOST_VERSION}-cmake.tar.xz"
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/boostorg/boost/releases/download/${BOOST_VERSION}/${BOOST_CMAKE_FILE}"
mkdir -p boost-src && cd boost-src
tar xf "/build/${BOOST_CMAKE_FILE}" --strip-components=1
cd /build

# cryptopp
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/cryptopp-modern/cryptopp-modern/archive/refs/tags/${CRYPTOPP_VERSION}.tar.gz"
tar xf "${CRYPTOPP_VERSION}.tar.gz"

# wxWidgets
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/wxWidgets/wxWidgets/releases/download/${WXWIDGETS_VERSION}/wxWidgets-${WX_VERSION_STRIP}.tar.bz2" || true
if [ -f "wxWidgets-${WX_VERSION_STRIP}.tar.bz2" ]; then
    tar xf "wxWidgets-${WX_VERSION_STRIP}.tar.bz2"
else
    git clone --depth=1 --branch "${WXWIDGETS_VERSION}" --filter=blob:none https://github.com/wxWidgets/wxWidgets.git
    mv wxWidgets "wxWidgets-${WX_VERSION_STRIP}"
fi

# readline
curl -fsSLO --retry 5 --retry-delay 10 "https://ftp.gnu.org/gnu/readline/readline-${READLINE_VERSION}.tar.gz"
tar xf "readline-${READLINE_VERSION}.tar.gz"

# libpng
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/pnggroup/libpng/archive/refs/tags/${LIBPNG_TAG}.tar.gz"
tar xf "${LIBPNG_TAG}.tar.gz"

# libgd
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/libgd/libgd/archive/refs/tags/${GD_VERSION}.tar.gz"
tar xf "${GD_VERSION}.tar.gz"

# pupnp
curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/pupnp/pupnp/archive/refs/tags/${PUPNP_VERSION}.tar.gz"
tar xf "${PUPNP_VERSION}.tar.gz"

# aMule (release or nightly)
if [ -n "${VERSION_NUM}" ]; then
    curl -fsSLO --retry 5 --retry-delay 10 "https://github.com/amule-project/amule/archive/refs/tags/${VERSION_NUM}.tar.gz"
    tar xf "${VERSION_NUM}.tar.gz"
else
    git clone --filter=blob:none --single-branch https://github.com/amule-project/amule.git
    cd amule && git checkout "${AMULE_SHA}" && cd /build
fi

# ============================================================================
# Part 3 — Build everything in dependency order
# ============================================================================
mkdir -p /build
cd /build

export LIBRARY_PATH="/usr/local/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CPATH="/usr/local/include${CPATH:+:$CPATH}"
export PATH="/usr/local/bin:${PATH}"

# ---------- 3.1 musl ----------
cd "musl-${MUSL_VERSION}"
./configure --prefix=/usr/local --disable-shared CFLAGS="${ARCH_CFLAGS} -O3 -pipe"
make -j"$(nproc)"
make install

# ---------- 3.2 rpmalloc ----------
cd "/build/rpmalloc-${RPMALLOC_VERSION}"
case "${ARCH}" in amd64* | x86_64*) RPMALLOC_ARCH="x86-64" ;; arm64 | aarch64) RPMALLOC_ARCH="arm64" ;; *) RPMALLOC_ARCH="" ;; esac
python3 configure.py --lto -c release --toolchain gcc ${RPMALLOC_ARCH:+-a "${RPMALLOC_ARCH}"}
ninja -j"$(nproc)" "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a"
mkdir -p /usr/local/lib
cp -f "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a" /usr/local/lib/

# ---------- 3.3 zlib-ng ----------
cd "/build/zlib-ng-${ZLIB_NG_VERSION}"
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DZLIB_COMPAT=ON -DWITH_AVX512=OFF -DWITH_AVX2=${ZLIB_AVX2} \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" -DCMAKE_EXE_LINKER_FLAGS="-static" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.4 libressl ----------
cd "/build/libressl-${LIBRESSL_VERSION}"
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF \
    -DLIBRESSL_APPS=OFF -DLIBRESSL_TESTS=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" -DCMAKE_EXE_LINKER_FLAGS="-static" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.5 nghttp2 ----------
cd "/build/nghttp2-${NGHTTP2_VERSION}"
autoreconf -fi
./configure --enable-static --disable-shared --disable-debug --enable-lib-only \
    PKG_CONFIG="pkg-config --static" CFLAGS="${BASE_CFLAGS}" CXXFLAGS="${BASE_CFLAGS}"
make -j"$(nproc)"
make install

# ---------- 3.6 Boost (cmake install) ----------
cd /build/boost-src
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_TESTING=OFF \
    -DBOOST_ENABLE_TESTING=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_CXX_FLAGS="${BASE_CFLAGS}"
cmake --build build
cmake --install build

# ---------- 3.7 ncurses ----------
cd "/build/${NCURSES_DIR}"
mkdir -p build_w && cd build_w
../configure --prefix=/usr/local --enable-static --disable-shared --enable-pc-files \
    --with-pkg-config-libdir=/usr/local/lib/pkgconfig --without-debug --without-manpages \
    --with-termlib --disable-big-core --disable-big-strings --disable-relink --disable-rpath \
    --without-ada --without-tests --without-progs --with-fallback="linux" --disable-full-macros \
    CFLAGS="${BASE_CFLAGS}" CXXFLAGS="${BASE_CFLAGS}"
make -j"$(nproc)"
make install.libs install.includes

# ---------- 3.8 readline (after ncurses) ----------
cd "/build/readline-${READLINE_VERSION}"
./configure --prefix=/usr/local --enable-static --disable-shared --with-curses \
    PKG_CONFIG="pkg-config --static" CFLAGS="${BASE_CFLAGS}" \
    CPPFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib -static"
make -j"$(nproc)" SHLIB_LIBS="-lncurses -ltinfo"
make install

# ---------- 3.9 libpsl ----------
cd "/build/libpsl-${LIBPSL_VERSION}"
./configure --prefix=/usr/local --enable-static --disable-shared --disable-gtk-doc \
    --disable-runtime --disable-nls --disable-man --without-libintl-prefix --without-libiconv-prefix \
    PKG_CONFIG="pkg-config --static" CFLAGS="${BASE_CFLAGS}"
make -j"$(nproc)"
make install

# ---------- 3.10 c-ares ----------
cd "/build/c-ares-${CARES_VERSION}"
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF \
    -DCARES_STATIC=ON -DCARES_SHARED=OFF -DCARES_BUILD_TESTS=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.11 curl ----------
cd "/build/curl-curl-${CURL_VERSION//./_}"
autoreconf -fi
./configure --prefix=/usr/local --enable-static --disable-shared --disable-debug \
    --disable-unix-sockets --disable-headers-api --disable-alt-svc --disable-hsts \
    --without-brotli --with-libpsl --with-openssl --with-nghttp2 \
    --without-nghttp3 --without-ngtcp2 --without-openssl-quic --with-zlib \
    --enable-ares --enable-ipv6 \
    --disable-ldap --disable-ldaps --disable-manual --disable-docs --disable-ipfs \
    --disable-dict --disable-gopher --disable-imap --disable-mqtt --disable-pop3 \
    --disable-rtsp --disable-smb --disable-smtp --disable-telnet --disable-tftp \
    PKG_CONFIG="pkg-config --static" CFLAGS="${BASE_CFLAGS}" CXXFLAGS="${BASE_CFLAGS}"
make -j"$(nproc)"
make install

# ---------- 3.12 libpng ----------
cd "/build/libpng-${LIBPNG_TAG#v}"
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" -DCMAKE_EXE_LINKER_FLAGS="-static" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.13 libgd ----------
cd "/build/libgd-${GD_VERSION}"
[ -f configure ] || autoreconf -fi
./configure --prefix=/usr/local --enable-static --enable-shared=no \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" CXXFLAGS="${BASE_CFLAGS}"
make -j"$(nproc)"
make install
# gdlib.pc: add -lpng -lz so PkgConfig::gdlib resolves transitive deps
GD_LIB_VERSION="${GD_VERSION#gd-}"
cat > /usr/local/lib/pkgconfig/gdlib.pc << GD_PC_EOF
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: gdlib
Description: GD graphics library
Version: ${GD_LIB_VERSION}
Libs: -L\${libdir} -lgd -lpng -lz
Cflags: -I\${includedir}
GD_PC_EOF

# ---------- 3.14 Crypto++ ----------
cd "/build/cryptopp-modern-${CRYPTOPP_VERSION}"
# CPU-specific feature flags: AVX2 based on arch, AVX512 always off
if [ "${ZLIB_AVX2}" = "OFF" ]; then
    CRYPTO_DISABLE_AVX2="ON"
else
    CRYPTO_DISABLE_AVX2="OFF"
fi
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF \
    -DCRYPTOPP_BUILD_TESTING=OFF -DCRYPTOPP_INSTALL=ON \
    -DCRYPTOPP_DISABLE_AVX2=${CRYPTO_DISABLE_AVX2} \
    -DCRYPTOPP_DISABLE_AVX512=ON \
    -DCMAKE_CXX_FLAGS="${BASE_CFLAGS}" -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.15 wxWidgets ----------
cd "/build/wxWidgets-${WX_VERSION_STRIP}"
mkdir -p build_wx && cd build_wx
../configure --prefix=/usr/local --disable-shared \
    --disable-gui \
    --enable-monolithic --disable-debug_flag --enable-optimise \
    --with-libcurl --with-zlib \
    CFLAGS="${BASE_CFLAGS}" CXXFLAGS="${BASE_CFLAGS}" \
    CPPFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib -static" \
    PKG_CONFIG="pkg-config --static"
make -j"$(nproc)"
make install

# ---------- 3.16 pupnp ----------
cd "/build/pupnp-${PUPNP_VERSION}"
cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=OFF \
    -DUPNP_BUILD_SHARED=OFF -DUPNP_BUILD_STATIC=ON -DUPNP_BUILD_SAMPLES=OFF \
    -DUPNP_ENABLE_TESTING=OFF -DUPNP_ENABLE_OPEN_SSL=OFF -DUPNP_ENABLE_IPV6=ON \
    -DUPNP_ENABLE_DEBUG=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" -DCMAKE_EXE_LINKER_FLAGS="-static" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build
cmake --install build

# ---------- 3.17 aMule ----------
AMULE_PREFIX="/opt/amule"
DEPS_PREFIX="/usr/local"

if [ -n "${VERSION_NUM}" ]; then
    cd "/build/amule-${VERSION_NUM}"
else
    cd /build/amule
fi

mkdir -p build && cd build
# cryptopp-modern uses a different version scheme; bypass the strict version check
sed -i 's/set (MIN_CRYPTOPP_VERSION 5.6)/set (MIN_CRYPTOPP_VERSION 0.0)/' ../CMakeLists.txt
# pupnp: static-only build uses UPNP::Static, not UPNP::Shared
sed -i 's/UPNP::Shared/UPNP::Static/g' \
    ../cmake/upnp.cmake ../src/CMakeLists.txt ../src/webserver/src/CMakeLists.txt 2>/dev/null || true
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DBUILD_WEBSERVER=ON -DBUILD_CAS=ON -DENABLE_NLS=OFF -DBUILD_MONOLITHIC=OFF \
    -DBUILD_REMOTEGUI=OFF -DBUILD_DAEMON=ON -DBUILD_WXCAS=OFF -DBUILD_ALCC=ON \
    -DBUILD_AMULECMD=ON -DBUILD_ALC=OFF -DBUILD_FILEVIEW=ON \
    -DCMAKE_INSTALL_PREFIX=${AMULE_PREFIX} -DENABLE_IP2COUNTRY=OFF -DENABLE_UPNP=ON \
    -DCMAKE_LIBRARY_PATH=${DEPS_PREFIX}/lib \
    -DZLIB_INCLUDE_DIR=${DEPS_PREFIX}/include -DZLIB_LIBRARY=${DEPS_PREFIX}/lib/libz.a \
    -DCMAKE_CXX_FLAGS="${BASE_CFLAGS} -I${DEPS_PREFIX}/include" \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS} -I${DEPS_PREFIX}/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-static -L${DEPS_PREFIX}/lib -lrpmalloc" \
    -DCMAKE_MODULE_LINKER_FLAGS="-static" \
    -DCMAKE_PREFIX_PATH=${DEPS_PREFIX} \
    -DCRYPTOPP_INCLUDE_PREFIX="cryptopp" \
    -DCRYPTOPP_LIBRARY=${DEPS_PREFIX}/lib/libcryptopp.a \
    -DCRYPTOPP_INCLUDE_DIR=${DEPS_PREFIX}/include
cmake --build .
cmake --install .

# ---------- Package output ----------
OUTPUT_DIR="/output"
PKG_DIR="${OUTPUT_DIR}/amule"
mkdir -p "${PKG_DIR}"
cp -a "${AMULE_PREFIX}"/* "${PKG_DIR}/"
for bin in amuled amulecmd amuleweb; do
    f="${PKG_DIR}/bin/${bin}"
    [ -f "$f" ] && strip "$f"
done

PACKAGE_NAME="amule-linux-${ARCH}${SUFFIX}"
tar -czf "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz" -C "${OUTPUT_DIR}" amule/

echo "=== Build complete ==="
echo "Package: ${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"
for f in "${PKG_DIR}/bin"/*; do
    [ -f "$f" ] && file "$f" && ls -lh "$f"
done
ls -lh "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"

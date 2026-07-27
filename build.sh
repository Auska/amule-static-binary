#!/bin/sh
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

# ---------------------------------------------------------------------------
# Architecture-specific compiler flags
# ---------------------------------------------------------------------------
case "${ARCH}" in
    amd64|x86_64)
        ARCH_CFLAGS="-march=x86-64-v2"
        ZLIB_AVX2="OFF"
        ;;
    amd64-gracemont|x86_64-gracemont)
        ARCH_CFLAGS="-march=gracemont -mtune=gracemont"
        ZLIB_AVX2="ON"
        ;;
    amd64-tremont|x86_64-tremont)
        ARCH_CFLAGS="-march=tremont -mtune=tremont"
        ZLIB_AVX2="OFF"
        ;;
    amd64-v3|x86_64-v3)
        ARCH_CFLAGS="-march=x86-64-v3"
        ZLIB_AVX2="ON"
        ;;
    arm64|aarch64)
        ARCH_CFLAGS="-march=armv8-a"
        ZLIB_AVX2="OFF"
        ;;
    *)
        ARCH_CFLAGS=""
        ZLIB_AVX2="OFF"
        ;;
esac
BASE_CFLAGS="${ARCH_CFLAGS} -static -O3 -pipe"

# ---------------------------------------------------------------------------
# Version pinning
# ---------------------------------------------------------------------------
MUSL_VERSION="1.2.6"
BOOST_VERSION="boost-1.91.0"
CRYPTOPP_VERSION="2026.7.1"
# wxWidgets: pick latest stable v3.2.x release (v3.3.x is development)
WXWIDGETS_VERSION=$(curl -fsS "https://api.github.com/repos/wxWidgets/wxWidgets/releases" | \
    jq -r '[.[] | select(.tag_name | startswith("v3.2")) | .tag_name][0]')
echo "Latest wxWidgets stable version: ${WXWIDGETS_VERSION}"
READLINE_VERSION="8.2"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
apk add --no-cache \
    autoconf \
    autoconf-archive \
    automake \
    build-base \
    cmake \
    cppunit-dev \
    curl \
    gawk \
    gettext-dev \
    git \
    jq \
    libtool \
    ninja \
    pkgconf \
    python3 \
    bison \
    flex

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# 2. Build musl libc
# ---------------------------------------------------------------------------
echo "Building musl libc ${MUSL_VERSION}"

mkdir -p /build
cd /build
curl -fsSLO "https://git.musl-libc.org/cgit/musl/snapshot/musl-${MUSL_VERSION}.tar.gz"
tar xf "musl-${MUSL_VERSION}.tar.gz"
cd "musl-${MUSL_VERSION}"

./configure \
    --prefix=/usr/local \
    --disable-shared \
    CFLAGS="${ARCH_CFLAGS} -O3 -pipe"

make -j"$(nproc)"
make install

export LIBRARY_PATH="/usr/local/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CPATH="/usr/local/include${CPATH:+:$CPATH}"

# ---------------------------------------------------------------------------
# 3. Build rpmalloc (modern heap memory allocator)
# ---------------------------------------------------------------------------
RPMALLOC_VERSION=$(curl -fsS "https://api.github.com/repos/mjansson/rpmalloc/releases/latest" | jq -r '.tag_name')
echo "Latest rpmalloc version: ${RPMALLOC_VERSION}"

mkdir -p /build
cd /build
curl -fsSLO "https://github.com/mjansson/rpmalloc/archive/refs/tags/${RPMALLOC_VERSION}.tar.gz"
tar xf "${RPMALLOC_VERSION}.tar.gz"
cd "rpmalloc-${RPMALLOC_VERSION}"

case "${ARCH}" in
    amd64*|x86_64*)  RPMALLOC_ARCH="x86-64"  ;;
    arm64|aarch64)   RPMALLOC_ARCH="arm64"    ;;
    *)               RPMALLOC_ARCH=""         ;;
esac

python3 configure.py --lto -c release --toolchain gcc ${RPMALLOC_ARCH:+-a "${RPMALLOC_ARCH}"}

ninja -j"$(nproc)" "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a"

mkdir -p /usr/local/lib
cp -f "lib/linux/release/${RPMALLOC_ARCH}/librpmalloc.a" /usr/local/lib/

# ---------------------------------------------------------------------------
# 4. Build zlib-ng
# ---------------------------------------------------------------------------
ZLIB_NG_VERSION=$(curl -fsS "https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest" | jq -r '.tag_name')
echo "Latest zlib-ng version: ${ZLIB_NG_VERSION}"

mkdir -p /build
cd /build
curl -fsSLO "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz"
tar xf "${ZLIB_NG_VERSION}.tar.gz"
cd "zlib-ng-${ZLIB_NG_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DZLIB_COMPAT=ON \
    -DWITH_AVX512=OFF \
    -DWITH_AVX2=${ZLIB_AVX2} \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

rm -f /usr/lib/pkgconfig/zlib.pc 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Build LibreSSL
# ---------------------------------------------------------------------------
LIBRESSL_VERSION=$(curl -fsS "https://api.github.com/repos/libressl/portable/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "Latest LibreSSL version: ${LIBRESSL_VERSION}"

cd /build
curl -fsSLO "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"
tar xf "libressl-${LIBRESSL_VERSION}.tar.gz"
cd "libressl-${LIBRESSL_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBRESSL_APPS=OFF \
    -DLIBRESSL_TESTS=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 6. Build nghttp2
# ---------------------------------------------------------------------------
NGHTTP2_VERSION=$(curl -fsS "https://api.github.com/repos/nghttp2/nghttp2/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "Latest nghttp2 version: ${NGHTTP2_VERSION}"

cd /build
curl -fsSLO "https://github.com/nghttp2/nghttp2/archive/refs/tags/v${NGHTTP2_VERSION}.tar.gz"
tar xf "v${NGHTTP2_VERSION}.tar.gz"
cd "nghttp2-${NGHTTP2_VERSION}"

autoreconf -fi
./configure \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --enable-lib-only \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 7. Build ncurses (needed by readline)
# ---------------------------------------------------------------------------
cd /build
curl -fsSLO "https://invisible-island.net/archives/ncurses/ncurses.tar.gz"
tar xf ncurses.tar.gz
NCURSES_DIR=$(tar tzf ncurses.tar.gz | head -1 | cut -d/ -f1)
cd "$NCURSES_DIR"

mkdir -p build && cd build

../configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --enable-pc-files \
    --with-pkg-config-libdir=/usr/local/lib/pkgconfig \
    --without-debug \
    --without-manpages \
    --with-termlib \
    --disable-big-core \
    --disable-big-strings \
    --disable-relink \
    --disable-rpath \
    --without-ada \
    --without-tests \
    --without-progs \
    --with-fallback="linux" \
    --disable-full-macros \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install.libs install.includes

# ---------------------------------------------------------------------------
# 8. Build libpsl (Public Suffix List library, needed by curl)
# ---------------------------------------------------------------------------
echo "Building libpsl"

cd /build
LIBPSL_VERSION="0.23.0"
curl -fsSLO "https://github.com/rockdaboot/libpsl/archive/refs/tags/${LIBPSL_VERSION}.tar.gz"
tar xf "${LIBPSL_VERSION}.tar.gz"
cd "libpsl-${LIBPSL_VERSION}"

# libpsl uses autotools; needs a kickstart
if [ ! -f configure ]; then
    autoreconf -fi
fi

./configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --disable-gtk-doc \
    --disable-runtime \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 9. Build c-ares (async DNS resolver, needed by curl)
# ---------------------------------------------------------------------------
CARES_VERSION=$(curl -fsS "https://api.github.com/repos/c-ares/c-ares/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
echo "Latest c-ares version: ${CARES_VERSION}"

cd /build
curl -fsSLO "https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz"
tar xf "c-ares-${CARES_VERSION}.tar.gz"
cd "c-ares-${CARES_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DCARES_STATIC=ON \
    -DCARES_SHARED=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 10. Build curl
# ---------------------------------------------------------------------------
CURL_TAG=$(curl -fsS "https://api.github.com/repos/curl/curl/releases/latest" | jq -r '.tag_name')
CURL_VERSION=$(echo "$CURL_TAG" | sed 's/curl-//' | tr '_' '.')
echo "Latest curl version: ${CURL_VERSION}"

cd /build
curl -fsSLO "https://github.com/curl/curl/archive/refs/tags/curl-${CURL_VERSION//./_}.tar.gz"
tar xf "curl-${CURL_VERSION//./_}.tar.gz"
cd "curl-curl-${CURL_VERSION//./_}"

autoreconf -fi
./configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-unix-sockets \
    --disable-headers-api \
    --disable-alt-svc \
    --disable-hsts \
    --without-brotli \
    --with-libpsl \
    --with-openssl \
    --with-nghttp2 \
    --without-nghttp3 \
    --without-ngtcp2 \
    --without-openssl-quic \
    --with-zlib \
    --enable-ares \
    --enable-ipv6 \
    --disable-ldap \
    --disable-ldaps \
    --disable-manual \
    --disable-docs \
    --disable-ipfs \
    --disable-dict \
    --disable-gopher \
    --disable-imap \
    --disable-mqtt \
    --disable-pop3 \
    --disable-rtsp \
    --disable-smb \
    --disable-smtp \
    --disable-telnet \
    --disable-tftp \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}"

make -j"$(nproc)"
make install

# ---------------------------------------------------------------------------
# 11. Build Boost (headers only)
# ---------------------------------------------------------------------------
echo "Building Boost ${BOOST_VERSION}"

cd /build
curl -fsSLO "https://github.com/boostorg/boost/archive/refs/tags/${BOOST_VERSION}.tar.gz"
tar xf "${BOOST_VERSION}.tar.gz"
cd "${BOOST_VERSION}"

# For aMule's use case (boost::asio, header-only boost::system with
# BOOST_ERROR_CODE_HEADER_ONLY), we only need the headers. No compiled
# Boost libraries are required on Linux.
cp -r boost /usr/local/include/boost

# Also install CMake config so find_package(Boost CONFIG) can find it
mkdir -p /usr/local/lib/cmake/boost_headers-1.91.0
cat > /usr/local/lib/cmake/boost_headers-1.91.0/boost_headers-config.cmake << 'BOOST_CMAKE_EOF'
if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../include"
    )
endif()
BOOST_CMAKE_EOF

# Also create a minimal BoostConfig.cmake so find_package(Boost CONFIG) works
cat > /usr/local/lib/cmake/BoostConfig.cmake << 'BOOST_CONFIG_EOF'
# Minimal BoostConfig.cmake for header-only usage
include(CMakeFindDependencyMacro)
if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include"
    )
endif()
set(Boost_FOUND TRUE)
set(Boost_VERSION 108100)
set(Boost_VERSION_STRING "1.91.0")
set(Boost_INCLUDE_DIRS "/usr/local/include")
set(Boost_INCLUDE_DIR "/usr/local/include")

# Define the component targets that find_package(Boost ... COMPONENTS ...) expects
foreach(_component asio system date_time regex filesystem thread)
    if(NOT TARGET Boost::${_component})
        add_library(Boost::${_component} INTERFACE IMPORTED)
        target_link_libraries(Boost::${_component} INTERFACE Boost::headers)
    endif()
endforeach()
BOOST_CONFIG_EOF

# Also provide BoostConfigVersion.cmake
cat > /usr/local/lib/cmake/BoostConfigVersion.cmake << 'BOOST_VERSION_EOF'
set(PACKAGE_VERSION "1.91.0")
if("${PACKAGE_FIND_VERSION}" VERSION_GREATER "1.91.0")
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if("${PACKAGE_FIND_VERSION}" VERSION_EQUAL "1.91.0")
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
endif()
BOOST_VERSION_EOF

# ---------------------------------------------------------------------------
# 12. Build Crypto++
# ---------------------------------------------------------------------------
echo "Building Crypto++ ${CRYPTOPP_VERSION}"

cd /build
curl -fsSLO "https://github.com/cryptopp-modern/cryptopp-modern/archive/refs/tags/${CRYPTOPP_VERSION}.tar.gz"
tar xf "${CRYPTOPP_VERSION}.tar.gz"
cd "cryptopp-modern-${CRYPTOPP_VERSION}"

# You can use an older cmake minimum to prevent it from needing newer cmake
# But we have cmake 3.31+ in Alpine, so it's fine.
sed -i 's/cmake_minimum_required(VERSION.*)/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt 2>/dev/null || true

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DCRYPTOPP_BUILD_TESTING=OFF \
    -DCRYPTOPP_INSTALL=ON \
    -DCMAKE_CXX_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 13. Build wxWidgets (wxBase + wxNet only, no GUI)
# ---------------------------------------------------------------------------
echo "Building wxWidgets ${WXWIDGETS_VERSION}"

cd /build
# Remove 'v' prefix for directory name
WX_VERSION_STRIP="${WXWIDGETS_VERSION#v}"
curl -fsSLO "https://github.com/wxWidgets/wxWidgets/releases/download/${WXWIDGETS_VERSION}/wxWidgets-${WX_VERSION_STRIP}.tar.bz2"
if [ -f "wxWidgets-${WX_VERSION_STRIP}.tar.bz2" ]; then
    tar xf "wxWidgets-${WX_VERSION_STRIP}.tar.bz2"
else
    # Fallback: use git clone
    git clone --depth=1 --branch "${WXWIDGETS_VERSION}" --filter=blob:none https://github.com/wxWidgets/wxWidgets.git
    mv wxWidgets "wxWidgets-${WX_VERSION_STRIP}"
fi
cd "wxWidgets-${WX_VERSION_STRIP}"

# Ensure our custom-built tools and libraries are findable
export PATH="/usr/local/bin:${PATH}"

# Build wxBase + wxNet with libcurl backend for wxWebRequest
# --disable-gui excludes all GUI code, giving us wxBase + wxNet
mkdir -p build_wx && cd build_wx

../configure \
    --prefix=/usr/local \
    --disable-shared \
    --enable-static \
    --disable-gui \
    --disable-debug \
    --enable-optimise \
    --with-libcurl \
    --without-expat \
    --without-libjpeg \
    --without-libpng \
    --without-libtiff \
    --without-sdl \
    --without-odbc \
    --without-libmspack \
    --without-gtk \
    --without-motif \
    --without-x11 \
    --disable-sys-libs \
    --disable-richtext \
    --disable-html \
    --disable-xrc \
    --disable-aui \
    --disable-propgrid \
    --disable-ribbon \
    --disable-stc \
    --disable-webkit \
    --disable-mediactrl \
    CFLAGS="${BASE_CFLAGS}" \
    CXXFLAGS="${BASE_CFLAGS}" \
    CPPFLAGS="-I/usr/local/include" \
    LDFLAGS="-L/usr/local/lib -static" \
    PKG_CONFIG="pkg-config --static"

make -j"$(nproc)"
make install

# Fix wx-config to output static link flags
if [ -f /usr/local/lib/wx/config/gtk3-unicode-static-3.2 ]; then
    WX_CONFIG="/usr/local/lib/wx/config/gtk3-unicode-static-3.2"
elif [ -f /usr/local/lib/wx/config/base-unicode-static-3.2 ]; then
    WX_CONFIG="/usr/local/lib/wx/config/base-unicode-static-3.2"
else
    WX_CONFIG=$(find /usr/local -name "wx-config" -type f 2>/dev/null | head -1)
fi

echo "wx-config: ${WX_CONFIG}"

# Override the system wx-config to ensure static linking
cat > /usr/local/bin/wx-config << 'WXCONFIG_SCRIPT'
#!/bin/sh
# Wrapper to ensure static linking flags
WX_CONFIG_REAL=$(find /usr/local/lib/wx/config -name '*-unicode-static-*' -type f 2>/dev/null | head -1)
if [ -z "$WX_CONFIG_REAL" ]; then
    WX_CONFIG_REAL=$(find /usr/local -name "wx-config" -type f ! -name "wx-config-wrapper" 2>/dev/null | head -1)
fi
exec "$WX_CONFIG_REAL" --static "$@"
WXCONFIG_SCRIPT
chmod +x /usr/local/bin/wx-config

# ---------------------------------------------------------------------------
# 14. Build readline (for amulecmd)
# ---------------------------------------------------------------------------
echo "Building readline ${READLINE_VERSION}"

cd /build
curl -fsSLO "https://ftp.gnu.org/gnu/readline/readline-${READLINE_VERSION}.tar.gz"
tar xf "readline-${READLINE_VERSION}.tar.gz"
cd "readline-${READLINE_VERSION}"

./configure \
    --prefix=/usr/local \
    --enable-static \
    --disable-shared \
    --with-curses \
    PKG_CONFIG="pkg-config --static" \
    CFLAGS="${BASE_CFLAGS}" \
    CPPFLAGS="-I/usr/local/include" \
    LDFLAGS="-L/usr/local/lib -static"

make -j"$(nproc)" SHLIB_LIBS="-lncurses -ltinfo"
make install

# ---------------------------------------------------------------------------
# 15. Build libpng (needed by libgd for CAS)
# ---------------------------------------------------------------------------
echo "Building libpng"

cd /build
LIBPNG_TAG="v1.6.58"
curl -fsSLO "https://github.com/pnggroup/libpng/archive/refs/tags/${LIBPNG_TAG}.tar.gz"
tar xf "${LIBPNG_TAG}.tar.gz"
cd "libpng-${LIBPNG_TAG#v}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DPNG_SHARED=OFF \
    -DPNG_STATIC=ON \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 16. Build libgd (for C aMule Statistics)
# ---------------------------------------------------------------------------
echo "Building libgd"

cd /build
GD_VERSION="gd-2.3.3"
curl -fsSLO "https://github.com/libgd/libgd/archive/refs/tags/${GD_VERSION}.tar.gz"
tar xf "${GD_VERSION}.tar.gz"
cd "libgd-${GD_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_PNG=ON \
    -DENABLE_JPEG=OFF \
    -DENABLE_TIFF=OFF \
    -DENABLE_WEBP=OFF \
    -DENABLE_FREETYPE=OFF \
    -DENABLE_FONTCONFIG=OFF \
    -DENABLE_XPM=OFF \
    -DENABLE_ICONV=OFF \
    -DENABLE_LIQ=OFF \
    -DENABLE_RAQM=OFF \
    -DENABLE_HEIF=OFF \
    -DENABLE_AVIF=OFF \
    -DENABLE_GD_FORMATS=OFF \
    -DBUILD_TEST=OFF \
    -DENABLE_CPP=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# Install pkg-config file for gdlib so aMule can find it
cat > /usr/local/lib/pkgconfig/gdlib.pc << 'GD_PC_EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: gdlib
Description: GD graphics library
Version: 2.3.3
Libs: -L${libdir} -lgd -lpng -lz
Cflags: -I${includedir}
GD_PC_EOF

# ---------------------------------------------------------------------------
# 17. Build pupnp (for UPnP support)
# ---------------------------------------------------------------------------
echo "Building pupnp"

cd /build
PUPNP_VERSION="release-22.0.4"
curl -fsSLO "https://github.com/pupnp/pupnp/archive/refs/tags/${PUPNP_VERSION}.tar.gz"
tar xf "${PUPNP_VERSION}.tar.gz"
cd "pupnp-${PUPNP_VERSION}"

cmake -B build \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=OFF \
    -DUPNP_BUILD_SHARED=OFF \
    -DUPNP_BUILD_STATIC=ON \
    -DUPNP_BUILD_SAMPLES=OFF \
    -DUPNP_ENABLE_TESTING=OFF \
    -DUPNP_ENABLE_OPEN_SSL=OFF \
    -DUPNP_ENABLE_IPV6=ON \
    -DUPNP_ENABLE_DEBUG=OFF \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -DCMAKE_INSTALL_LIBDIR=lib

cmake --build build -j"$(nproc)"
cmake --install build

# ---------------------------------------------------------------------------
# 18. Build aMule
# ---------------------------------------------------------------------------
echo "Building aMule"
cd /build

if [ -n "${VERSION_NUM}" ]; then
    # Download source tarball for the version tag
    curl -fsSLO \
        "https://github.com/amule-project/amule/archive/refs/tags/${VERSION_NUM}.tar.gz"
    tar xf "${VERSION_NUM}.tar.gz"
    cd "amule-${VERSION_NUM}"
else
    git clone --filter=blob:none --single-branch https://github.com/amule-project/amule.git
    cd amule
    git checkout "${AMULE_SHA}"
fi

PREFIX="/usr/local"

mkdir -p build && cd build

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DBoost_DIR=${PREFIX} \
    -DBUILD_WEBSERVER=ON \
    -DBUILD_CAS=ON \
    -DENABLE_NLS=OFF \
    -DBUILD_MONOLITHIC=OFF \
    -DBUILD_REMOTEGUI=OFF \
    -DBUILD_DAEMON=ON \
    -DBUILD_WXCAS=OFF \
    -DBUILD_ALCC=ON \
    -DBUILD_AMULECMD=ON \
    -DBUILD_ALC=OFF \
    -DBUILD_FILEVIEW=ON \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DENABLE_IP2COUNTRY=OFF \
    -DENABLE_UPNP=ON \
    -DZLIB_INCLUDE_DIR=${PREFIX}/include \
    -DZLIB_LIBRARY=${PREFIX}/lib/libz.a \
    -DCMAKE_CXX_FLAGS="${BASE_CFLAGS} -I${PREFIX}/include" \
    -DCMAKE_C_FLAGS="${BASE_CFLAGS} -I${PREFIX}/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-static -L${PREFIX}/lib -lrpmalloc" \
    -DCMAKE_MODULE_LINKER_FLAGS="-static" \
    -DPKG_CONFIG_EXECUTABLE="pkg-config --static" \
    -DCRYPTOPP_INCLUDE_PREFIX="cryptopp" \
    -DCRYPTOPP_LIBRARY=${PREFIX}/lib/libcryptopp.a \
    -DCRYPTOPP_INCLUDE_DIR=${PREFIX}/include

make -j"$(nproc)"

# ---------------------------------------------------------------------------
make install

OUTPUT_DIR="/output"
mkdir -p "${OUTPUT_DIR}"

BIN_DIR="${OUTPUT_DIR}/bin"
mkdir -p "${BIN_DIR}"

# Copy installed aMule binaries
for bin in amuled amulecmd amuleweb; do
    found=$(find /usr/local/bin -name "${bin}" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        cp "$found" "${BIN_DIR}/${bin}-linux-${ARCH}${SUFFIX}"
        strip "${BIN_DIR}/${bin}-linux-${ARCH}${SUFFIX}"
    fi
done

# Create tar.gz archive of all binaries
PACKAGE_NAME="amule-linux-${ARCH}${SUFFIX}"
tar -czf "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz" \
    -C "${OUTPUT_DIR}" \
    bin/

echo "=== Build complete ==="
echo "Package: ${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"
for f in "${BIN_DIR}"/*; do
    if [ -f "$f" ]; then
        file "$f"
        ls -lh "$f"
    fi
done
ls -lh "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"

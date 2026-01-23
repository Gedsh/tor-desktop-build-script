#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Required environment
###############################################################################

: "${TOR_VERSION:?}"
: "${PLATFORM:?}"        # linux | macos | windows
: "${ARCH:=amd64}"
: "${NUM_PROCS:=$(if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi)}"

PROJECT=tor
BUILDDIR=/var/tmp/build
DISTROOT=/var/tmp/dist
DISTDIR="$DISTROOT/$PROJECT"

TORDATADIR="$DISTDIR/data"
TORBINDIR="$DISTDIR/tor"
TORDOCSDIR="$DISTDIR/docs"

mkdir -p "$BUILDDIR" "$TORDATADIR" "$TORBINDIR" "$TORDOCSDIR"

###############################################################################
# Platform dependency paths
###############################################################################

if [[ "$PLATFORM" == "windows" ]]; then
  TARGET=x86_64-w64-mingw32
  export PATH="/usr/bin:$PATH"
  export CC=${TARGET}-gcc
  export CXX=${TARGET}-g++
  export AR=${TARGET}-ar
  export RANLIB=${TARGET}-ranlib
  export STRIP=${TARGET}-strip
  export WINDRES=${TARGET}-windres
  export PKG_CONFIG_PATH=""
  export LDFLAGS="-static-libgcc -static-libstdc++"
  ZLIBDIR="$BUILDDIR/zlib"
  OPENSSLDIR="$BUILDDIR/openssl"
  LIBEVENTDIR="$BUILDDIR/libevent"
  ZSTDDIR="$BUILDDIR/zstd"
elif [[ "$PLATFORM" == "macos" ]]; then
  export CC=clang
  export CXX=clang++
  export AR=$(xcrun --find ar)
  export RANLIB=$(xcrun --find ranlib)
  export MACOSX_DEPLOYMENT_TARGET=10.15
  export CFLAGS="${CFLAGS:-} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  export LDFLAGS="${LDFLAGS:-} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  OPENSSLDIR="$BUILDDIR/openssl"
  LIBEVENTDIR="$BUILDDIR/libevent"
else
  OPENSSLDIR="$BUILDDIR/openssl"
  LIBEVENTDIR="$BUILDDIR/libevent"
  ZLIBDIR="$BUILDDIR/zlib"
fi

###############################################################################
# Build dependencies
###############################################################################

cd "$BUILDDIR"

# Build OpenSSL

if [[ ! -d openssl ]]; then
    mkdir -p openssl
    git clone --single-branch --branch "$OPENSSL_VERSION" https://github.com/openssl/openssl.git openssl-src

fi
cd openssl-src
if [[ "$PLATFORM" == "windows" ]]; then
    ./Configure mingw64 no-tests no-shared --libdir=lib --prefix="$OPENSSLDIR"
elif [[ "$PLATFORM" == "macos" ]]; then
    ./Configure darwin64-$(uname -m)-cc no-tests no-shared --libdir=lib --prefix="$OPENSSLDIR"
else
    ./Configure linux-x86_64 shared enable-ec_nistp_64_gcc_128 --libdir=lib --prefix="$OPENSSLDIR"
fi
make -j"$NUM_PROCS"
make -j"$NUM_PROCS" install
cd ..

# Build libevent

if [[ ! -d libevent ]]; then
    mkdir -p libevent
    git clone --single-branch --branch "$LIBEVENT_VERSION" https://github.com/libevent/libevent.git libevent-src
fi
cd libevent-src
./autogen.sh
if [[ "$PLATFORM" == "windows" ]]; then
    ./configure --host="$TARGET" --disable-shared --disable-libevent-regress --disable-samples --disable-openssl --prefix="$LIBEVENTDIR"
else
    ./configure --disable-static --enable-shared --disable-libevent-regress --disable-samples --disable-openssl --prefix="$LIBEVENTDIR"
fi
make -j"$NUM_PROCS" install
cd ..

# Build zlib (Windows only)

if [[ "$PLATFORM" == "windows" && ! -d zlib ]]; then
    mkdir -p zlib
    git clone  --single-branch --branch "$ZLIB_VERSION" https://github.com/madler/zlib.git zlib-src
fi
if [[ "$PLATFORM" == "windows" ]]; then
    cd zlib-src

    make -f win32/Makefile.gcc \
        PREFIX=${TARGET}- \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        libz.a -j"$NUM_PROCS"

    # Manual install (Tor does this)
    mkdir -p "$ZLIBDIR/lib" "$ZLIBDIR/include"
    install -m 644 libz.a "$ZLIBDIR/lib/"
    install -m 644 zlib.h zconf.h "$ZLIBDIR/include/"

    cd ..
fi

# Build zstd (Windows only)
if [[ "$PLATFORM" == "windows" && ! -d zstd ]]; then
    git clone --single-branch --branch "$ZSTD_VERSION" https://github.com/facebook/zstd.git zstd-src
fi

if [[ "$PLATFORM" == "windows" ]]; then

    cd zstd-src

    # Use the generic Makefile with cross-compilers
    make CC="${TARGET}-gcc" AR="${TARGET}-ar" RANLIB="${TARGET}-ranlib" \
         PREFIX="$ZSTDDIR" -j"$NUM_PROCS"

    # Manual install
    mkdir -p "$ZSTDDIR/lib" "$ZSTDDIR/include"
    install -m 644 lib/libzstd.a "$ZSTDDIR/lib/"
    install -m 644 lib/zstd.h "$ZSTDDIR/include/"

    cd ..
fi

###############################################################################
# Build tor
###############################################################################

if [[ ! -d tor ]]; then
  git clone --single-branch --branch prod https://gitlab.torproject.org/Gedsh/tor.git
fi
cd tor
git rev-parse --short=16 HEAD | sed 's/^/"/;s/$/"/' > micro-revision.i

./autogen.sh
find . -type f -print0 | xargs -0 touch

CONFIGURE_FLAGS=(
  --disable-asciidoc
  --enable-gpl
  --prefix="$DISTDIR"
  --with-openssl-dir="$OPENSSLDIR"
  --with-libevent-dir="$LIBEVENTDIR"
)

if [[ "$PLATFORM" == "windows" ]]; then
  CONFIGURE_FLAGS+=(
    --host="$TARGET"
    --with-zlib-dir="$ZLIBDIR"
    --enable-static-libevent
    --enable-static-openssl
    --enable-static-zlib
    --disable-tool-name-check
  )

  export ZSTDDIR="$BUILDDIR/zstd"
  export CFLAGS="-I$ZSTDDIR/include $CFLAGS"
  export LDFLAGS="-L$ZSTDDIR/lib $LDFLAGS"
elif [[ "$PLATFORM" == "macos" ]]; then
  CONFIGURE_FLAGS+=(--enable-static-openssl)

  export CFLAGS="-I$OPENSSLDIR/include -I$LIBEVENTDIR/include  $CFLAGS"
  export LDFLAGS="${LDFLAGS:-} -L$OPENSSLDIR/lib"
else
  TORDEBUGDIR="$DISTDIR/debug"
  mkdir -p "$TORDEBUGDIR"

  cp -v "$OPENSSLDIR/lib/libssl.so.3" "$TORBINDIR/"
  cp -v "$OPENSSLDIR/lib/libcrypto.so.3" "$TORBINDIR/"
  cp -v "$LIBEVENTDIR/lib/libevent-2.1.so.7" "$TORBINDIR/"

  export LD_LIBRARY_PATH="$TORBINDIR:${LD_LIBRARY_PATH:-}"
  export CFLAGS="-I$OPENSSLDIR/include -I$LIBEVENTDIR/include  $CFLAGS"
  export LDFLAGS="${LDFLAGS:-} -L$OPENSSLDIR/lib -L$LIBEVENTDIR/lib -Wl,-rpath,'\$\$ORIGIN'"
fi

./configure "${CONFIGURE_FLAGS[@]}"
make -j"$NUM_PROCS"
make install


###############################################################################
# Final packaging
###############################################################################

cp "$DISTDIR/share/tor/geoip" "$TORDATADIR"
cp "$DISTDIR/share/tor/geoip6" "$TORDATADIR"
cp LICENSE "$TORDOCSDIR/tor.txt"

if [[ "$PLATFORM" == "linux" ]]; then
  objcopy --only-keep-debug "$DISTDIR/bin/tor" "$TORDEBUGDIR/tor"
  strip "$DISTDIR/bin/tor"
  install "$DISTDIR/bin/tor" "$TORBINDIR"
  objcopy --add-gnu-debuglink="$TORDEBUGDIR/tor" "$TORBINDIR/tor"

elif [[ "$PLATFORM" == "macos" ]]; then
   # macOS: libevent dynamic, OpenSSL static
  cp "$LIBEVENTDIR/lib/libevent-"*.dylib "$TORBINDIR"
  cp "$DISTDIR/bin/tor" "$TORBINDIR"

  LIBEVENT_FILE=$(basename "$LIBEVENTDIR/lib/libevent-"*.dylib)

  install_name_tool \
    -change "$LIBEVENTDIR/lib/$LIBEVENT_FILE" \
    "@executable_path/$LIBEVENT_FILE" \
    "$TORBINDIR/tor"
  install_name_tool \
    -id "@executable_path/$LIBEVENT_FILE" \
    "$TORBINDIR/$LIBEVENT_FILE"

else
  install -s "$DISTDIR/bin/tor.exe" "$TORBINDIR"
  install -s "$DISTDIR/bin/tor-gencert.exe" "$TORBINDIR"

  # Ship MinGW SSP runtime (required by GCC)
  SSP_DLL="$(dirname "$($CC -print-libgcc-file-name)")/libssp-0.dll"
  if [[ -f "$SSP_DLL" ]]; then
    install -m 755 "$SSP_DLL" "$TORBINDIR"
  else
    echo "WARNING: libssp-0.dll not found"
  fi
fi

SUFFIX="$PLATFORM-$ARCH"

# Detect CI workspace safely
if [[ -n "$GITHUB_WORKSPACE" ]]; then
  OUTROOT="$GITHUB_WORKSPACE/artifacts"
elif [[ -n "$CI_PROJECT_DIR" ]]; then
  OUTROOT="$CI_PROJECT_DIR/artifacts"
else
  # local fallback
  OUTROOT="$PWD/artifacts"
fi

mkdir -p "$OUTROOT"

BASENAME="tor-$TOR_VERSION-$SUFFIX"

cd "$DISTROOT" || exit 1

if [[ "$PLATFORM" == "windows" ]]; then
  zip -r -9 "$OUTROOT/$BASENAME.zip" tor
  ARTIFACT="$OUTROOT/$BASENAME.zip"
else
  tar -caf "$OUTROOT/$BASENAME.tar.xz" tor
  ARTIFACT="$OUTROOT/$BASENAME.tar.xz"
fi

echo "Artifact created: $ARTIFACT"


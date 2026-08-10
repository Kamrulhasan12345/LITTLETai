#!/data/data/com.termux/files/usr/bin/bash
#
# lbuild.sh - build llama.cpp on Termux with switchable backends
#
#   ./lbuild.sh                       # CPU only (default)
#   ./lbuild.sh --vulkan
#   ./lbuild.sh --opencl
#   ./lbuild.sh --profile             # standalone binary for /data/local/tmp
#   ./lbuild.sh --profile --static    # fully static, no bionic at all
#   ./lbuild.sh --kleidi              # KleidiAI micro-kernels (needs network)
#   ./lbuild.sh --streamline          # link Streamline annotation lib
#   ./lbuild.sh --arch armv8.2-a+dotprod
#   ./lbuild.sh --bench               # build, then run llama-bench
#   ./lbuild.sh --stage --perf        # push to /data/local/tmp, then simpleperf
#   ./lbuild.sh -DGGML_NATIVE=ON -DSOMETHING=OFF     # extra cmake args
#   ./lbuild.sh --clean               # wipe this preset's build dir first
#
# Each backend gets its own build dir, so switching between them does NOT
# recompile everything from scratch. Feature flags (--kleidi, --streamline,
# --static) are part of the build dir name for the same reason.

set -euo pipefail

# ---------------------------------------------------------------- settings
# SRC = your llama.cpp tree. This is the one you edit ggml kernels in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$SCRIPT_DIR/src}"
OUT="${OUT:-./build}"
MODEL="${MODEL:-$HOME/models/model.gguf}"

PREFIX="/data/data/com.termux/files/usr"
NDK_SHADER_TOOLS="${NDK:-}/shader-tools/linux-x86_64"

# Streamline annotation support. Build once with:
#   git clone https://github.com/ARM-software/gator.git
#   cd gator/annotate && make
# then point ANNOTATE_DIR at the directory holding libstreamline_annotate.a
# and streamline_annotate.h. Must match your installed Streamline version.
ANNOTATE_DIR="${ANNOTATE_DIR:-$SCRIPT_DIR/src/streamline_annotation}"

# ---------------------------------------------------------------- args
BACKEND="bare"
JOBS="$(nproc)"
DO_BENCH=0
DO_CLEAN=0
DO_STAGE=0
DO_PERF=0
USE_DL=0
USE_KLEIDI=0
USE_STREAMLINE=0
USE_STATIC=0
ARCH=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bare)       BACKEND="bare"     ;;
    --vulkan)     BACKEND="vulkan"   ;;
    --opencl)     BACKEND="opencl"   ;;
    --profile)    BACKEND="profile"  ;;
    --dl)         USE_DL=1           ;;
    --kleidi)     USE_KLEIDI=1       ;;
    --streamline) USE_STREAMLINE=1   ;;
    --static)     USE_STATIC=1       ;;
    --arch)       ARCH="$2"; shift   ;;
    --arch=*)     ARCH="${1#--arch=}";;
    --bench)      DO_BENCH=1         ;;
    --clean)      DO_CLEAN=1         ;;
    --stage)      DO_STAGE=1         ;;
    --perf)       DO_PERF=1          ;;
    -j*)          JOBS="${1#-j}"     ;;
    -D*)          EXTRA+=("$1")      ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "lbuild: unknown option '$1'" >&2; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------- sanity
# GPU backends dlopen their loaders out of /system. A fully static binary
# cannot dlopen, so these combinations are dead on arrival.
if (( USE_STATIC )) && [[ "$BACKEND" == "vulkan" || "$BACKEND" == "opencl" ]]; then
  echo "lbuild: --static is incompatible with $BACKEND (needs dlopen)" >&2
  exit 1
fi
if (( USE_STATIC && USE_DL )); then
  echo "lbuild: --static is incompatible with --dl (GGML_BACKEND_DL needs dlopen)" >&2
  exit 1
fi
# KleidiAI ships one micro-kernel set per ISA level. GGML_CPU_ALL_VARIANTS
# builds several CPU variants into one artifact; the KleidiAI selection is
# resolved once at configure time from ARCH_FLAGS, so it does not follow.
if (( USE_KLEIDI && USE_DL )); then
  echo "lbuild: --kleidi with --dl builds KleidiAI for one ISA level only" >&2
  echo "        (GGML_CPU_ALL_VARIANTS will not vary it). Continuing anyway." >&2
fi
if (( USE_STREAMLINE )); then
  for f in "$ANNOTATE_DIR/libstreamline_annotate.a" "$ANNOTATE_DIR/streamline_annotate.h"; do
    [[ -f "$f" ]] || { echo "lbuild: --streamline needs $f (build gator/annotate)" >&2; exit 1; }
  done
fi

# Build dir encodes the feature set so presets never clobber each other.
TAG="$BACKEND"
(( USE_KLEIDI ))     && TAG+="-kai"
(( USE_STREAMLINE )) && TAG+="-sl"
(( USE_STATIC ))     && TAG+="-static"
(( USE_DL ))         && TAG+="-dl"
BUILD="$OUT/$TAG"

# ---------------------------------------------------------------- flags
# These -isystem paths are what make posix_spawn_file_actions_addchdir_np
# resolve. Termux's patched headers declare it; bionic's do not.
# Do not remove them for in-Termux builds.
CFLAGS_COMMON="-O3 -fstack-protector-strong"
CFLAGS_COMMON+=" -isystem$PREFIX/include/c++/v1 -isystem$PREFIX/include"
CFLAGS_COMMON+=" -I$ANNOTATE_DIR"

# CMAKE_LINKER is a path to a program, not a place for flags. Flags belong
# in the *_LINKER_FLAGS variables, which CMake appends after the objects --
# which is exactly where -landroid-spawn has to be.
LINKER_BIN="$PREFIX/bin/ld.lld"
LDFLAGS_COMMON="-L$PREFIX/lib"
LDFLAGS_COMMON+=" -Wl,--enable-new-dtags -Wl,--as-needed -Wl,-z,relro,-z,now"
LDFLAGS_COMMON+=" -landroid-spawn"

ARGS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_AR="$PREFIX/bin/llvm-ar"
  -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib"
  -DCMAKE_STRIP="$PREFIX/bin/llvm-strip"
  -DCMAKE_MAKE_PROGRAM="$PREFIX/bin/ninja"
  -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_SKIP_INSTALL_RPATH=ON
  -DBUILD_SHARED_LIBS=ON
  -DBUILD_TESTING=OFF
  -DLLAMA_BUILD_TESTS=OFF
  -DGGML_OPENMP=OFF
  # Downloader deps. LLAMA_CURL is the old name (deprecated on current
  # master, harmless); LLAMA_OPENSSL is what replaced it and defaults ON.
  # Passing both keeps this script working across the b6xxx..b10xxx range.
  -DLLAMA_CURL=OFF
  -DLLAMA_OPENSSL=OFF
)

# ---------------------------------------------------------------- preset
if [[ "$BACKEND" == "profile" ]]; then
  # Standalone binary runnable as shell uid from /data/local/tmp.
  # Nothing may resolve back into $PREFIX -- that dir is 0700 termux-uid.
  CFLAGS_COMMON="-O3 -fstack-protector-strong"     # drop -isystem
  LDFLAGS_COMMON="-Wl,--as-needed -Wl,-z,relro,-z,now"   # drop -landroid-spawn
  ARGS+=(
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    -DCMAKE_INSTALL_RPATH=""
  )
  # profile implies static llama/ggml libs; --static goes further (see below)
  USE_STATIC_LIBS=1
else
  USE_STATIC_LIBS=0
fi

# ---------------------------------------------------------------- linkage
# Two independent axes, easy to conflate:
#   BUILD_SHARED_LIBS=OFF  -> llama/ggml become .a, folded into the exe.
#                             Still dynamically linked against bionic.
#   -static                -> no dynamic loader at all. Everything, libc
#                             included, is in the binary.
# The Arm learning paths use both; --profile gives you the first, --static
# adds the second.
LDFLAGS_EXE_EXTRA=""
if (( USE_STATIC || USE_STATIC_LIBS )); then
  ARGS=( "${ARGS[@]/-DBUILD_SHARED_LIBS=ON/-DBUILD_SHARED_LIBS=OFF}" )
fi

if (( USE_STATIC )); then
  # Fully static. dlopen() is a stub in static bionic, so backend DL and
  # GPU loaders are already ruled out above. -static-libstdc++ is implied
  # but harmless to keep explicit.
  LDFLAGS_EXE_EXTRA=" -static -static-libstdc++"
  # Debug info survives -static and is what Streamline needs for
  # source-level attribution.
  CFLAGS_COMMON+=" -g"
elif (( USE_STATIC_LIBS )); then
  LDFLAGS_EXE_EXTRA=" -static-libstdc++"
fi

# ---------------------------------------------------------------- dl mode
# Backend loading mode.
#   default: CPU backend compiled straight into the binary, one variant,
#            tuned for THIS device. No dlopen, no runtime dispatch --
#            what you build is what runs. Correct for kernel work.
#   --dl:    packaging mode. Separate libggml-*.so files, many CPU variants,
#            selected at runtime. Use only when producing a .deb.
if (( USE_DL )); then
  ARGS+=( -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON )
else
  ARGS+=( -DGGML_BACKEND_DL=OFF )
fi

# ---------------------------------------------------------------- arch
# GGML_NATIVE probes the host and appends the ISA tags it finds. That is
# right when building on the device you will run on, and wrong the moment
# you want to pin an ISA level -- e.g. to check what the no-dotprod
# fallback path actually does on hardware that has dotprod.
#
# GGML_NATIVE and an explicit -march fight over ARCH_FLAGS, so --arch
# turns GGML_NATIVE off. Note KleidiAI reads its feature gates by regex
# from these same flags, which is why the two have to agree.
if [[ -n "$ARCH" ]]; then
  CFLAGS_COMMON+=" -march=$ARCH"
  ARGS+=( -DGGML_NATIVE=OFF )
else
  ARGS+=( -DGGML_NATIVE=ON )
fi

# ---------------------------------------------------------------- kleidi
# KleidiAI micro-kernels. The base set is gated on +dotprod, with extra
# tiers for +i8mm, +sve and +sme -- none of which your A55/A75 have. On a
# no-dotprod part (Pi Zero 2 W) this builds fine and contributes nothing.
#
# Configure-time FetchContent pulls a tarball from github, so the first
# configure of a clean build dir needs network.
if (( USE_KLEIDI )); then
  ARGS+=( -DGGML_CPU_KLEIDIAI=ON )
  case "${ARCH:-native}" in
    *sme*|*sve*)
      echo "lbuild: warning -- --arch '$ARCH' requests SVE/SME KleidiAI kernels." >&2
      echo "        A55/A75 have neither. Expect SIGILL on the first such kernel." >&2
      ;;
  esac
else
  ARGS+=( -DGGML_CPU_KLEIDIAI=OFF )
fi

# ---------------------------------------------------------------- streamline
# Wire the annotation library in without touching the llama.cpp tree:
#   -I<dir>  makes streamline_annotate.h visible to every TU
#   the .a on the exe linker line is appended after the objects, so the
#   ANNOTATE_* symbols resolve wherever you put the markers
#   -DLBUILD_STREAMLINE lets you guard the markers so an unpatched tree
#   and a patched one are the same source
# A static lib whose symbols nothing references costs nothing, so this is
# safe to leave on.
if (( USE_STREAMLINE )); then
  CFLAGS_COMMON+="  -DLBUILD_STREAMLINE"
  [[ "$CFLAGS_COMMON" == *" -g"* ]] || CFLAGS_COMMON+=" -g"
  LDFLAGS_EXE_EXTRA+=" $ANNOTATE_DIR/libstreamline_annotate.a -llog"
  # Streamline attributes samples to source lines; without symbols you get
  # addresses. Keep them even in Release.
  ARGS+=( -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -g" )
  ARGS+=( -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -g" )
fi

# ---------------------------------------------------------------- assemble
ARGS+=(
  -DCMAKE_C_FLAGS="$CFLAGS_COMMON"
  -DCMAKE_CXX_FLAGS="$CFLAGS_COMMON"
  -DCMAKE_LINKER="$LINKER_BIN"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_COMMON$LDFLAGS_EXE_EXTRA"
  -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_COMMON"
)

case "$BACKEND" in
  bare|profile)
    ARGS+=( -DGGML_VULKAN=OFF -DGGML_OPENCL=OFF )
    ;;
  vulkan)
    [[ -d "$NDK_SHADER_TOOLS" ]] && export PATH="$NDK_SHADER_TOOLS:$PATH"

    # CMake's FindVulkan needs an actual .so path -- a bare "vulkan" fails
    # because libvulkan.so is not in $PREFIX/lib on-device.
    # Order: vulkan-loader package, then the system loader.
    if [[ -z "${VULKAN_LIB:-}" ]]; then
      for c in "$PREFIX/lib/libvulkan.so" \
               /system/lib64/libvulkan.so \
               /system/lib/libvulkan.so; do
        [[ -f "$c" ]] && { VULKAN_LIB="$c"; break; }
      done
    fi
    [[ -n "${VULKAN_LIB:-}" ]] || {
      echo "lbuild: no libvulkan.so found. Try 'pkg install vulkan-loader'," >&2
      echo "        or set VULKAN_LIB=/path/to/libvulkan.so" >&2
      exit 1
    }
    echo ">>> vulkan loader: $VULKAN_LIB"

    ARGS+=( -DGGML_VULKAN=ON -DGGML_OPENCL=OFF -DVulkan_LIBRARY="$VULKAN_LIB" )
    ;;
  opencl)
    ARGS+=( -DGGML_OPENCL=ON -DGGML_VULKAN=OFF )
    ;;
esac

# Anything you passed on the command line goes LAST, so it wins.
ARGS+=( "${EXTRA[@]+"${EXTRA[@]}"}" )

# ---------------------------------------------------------------- build
[[ -d "$SRC" ]] || { echo "lbuild: no source tree at $SRC" >&2; exit 1; }
(( DO_CLEAN )) && rm -rf "$BUILD"
mkdir -p "$BUILD"

echo ">>> backend=$BACKEND  tag=$TAG  src=$SRC  build=$BUILD"
(( USE_KLEIDI ))     && echo ">>> kleidiai: on"
(( USE_STREAMLINE )) && echo ">>> streamline: $ANNOTATE_DIR"
(( USE_STATIC ))     && echo ">>> linkage: fully static"
[[ -n "$ARCH" ]]     && echo ">>> arch: $ARCH (GGML_NATIVE off)"

cmake -S "$SRC" -B "$BUILD" "${ARGS[@]}"
cmake --build "$BUILD" -j"$JOBS"

echo ">>> binaries in $BUILD/bin"

# Confirm what you actually got, because "static" is easy to get wrong.
if (( USE_STATIC )) && command -v file >/dev/null 2>&1; then
  file "$BUILD/bin/llama-bench" | sed 's/^/>>> /'
fi

# ---------------------------------------------------------------- stage
# Push binary + model to /data/local/tmp so they run as the shell uid.
# Has to happen AFTER the build, not before.
if (( DO_STAGE )); then
  TMP=/data/local/tmp
  BINS=( "$BUILD/bin/llama-bench" )
  # A non-static build still needs its .so files alongside it, since
  # $PREFIX is 0700 and unreadable to the shell uid.
  if (( ! USE_STATIC )); then
    while IFS= read -r so; do BINS+=( "$so" ); done \
      < <(find "$BUILD/bin" -maxdepth 1 -name '*.so' 2>/dev/null)
  fi
  cp "${BINS[@]}" "$MODEL" /sdcard/
  NAMES=""
  for b in "${BINS[@]}" "$MODEL"; do NAMES+=" /sdcard/$(basename "$b")"; done
  ./rish -c "cp$NAMES $TMP/ && chmod 755 $TMP/llama-bench"
  echo ">>> staged to $TMP"
fi

# ---------------------------------------------------------------- perf
if (( DO_PERF )); then
  # All events carry :u -- kernel-mode counting is denied on this device.
  EV="cpu-cycles:u,instructions:u,raw-stall-backend:u,raw-ll-cache-miss-rd:u"
  echo ">>> cooling down 60s"
  sleep 60
  ./rish -c "cd /data/local/tmp && LD_LIBRARY_PATH=/data/local/tmp \
             simpleperf stat -e $EV --per-core \
             -- ./llama-bench -m $(basename "$MODEL") -p 0 -n 128 -t ${THREADS:-8}"
fi

# ---------------------------------------------------------------- bench
if (( DO_BENCH )); then
  if [[ ! -f "$MODEL" ]]; then
    echo "lbuild: no model at $MODEL (set MODEL=/path/to.gguf)" >&2
    exit 1
  fi
  echo ">>> cooling down 60s so thermals don't skew the numbers"
  sleep 60
  LD_LIBRARY_PATH="$BUILD/bin:${LD_LIBRARY_PATH:-}" \
    "$BUILD/bin/llama-bench" -m "$MODEL" -r 5 -o md
fi

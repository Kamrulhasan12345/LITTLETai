#!/data/data/com.termux/files/usr/bin/bash
#
# lbuild.sh - build llama.cpp on Termux with switchable backends
#
#   ./lbuild.sh                  # CPU only (default)
#   ./lbuild.sh --vulkan
#   ./lbuild.sh --opencl
#   ./lbuild.sh --bench          # build, then run llama-bench
#   ./lbuild.sh -DGGML_NATIVE=ON -DSOMETHING=OFF     # extra cmake args
#   ./lbuild.sh --clean          # wipe this preset's build dir first
#
# Each backend gets its own build dir, so switching between them does NOT
# recompile everything from scratch.

set -euo pipefail

# ---------------------------------------------------------------- settings
# SRC = your llama.cpp tree. This is the one you edit ggml kernels in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$SCRIPT_DIR/src}"
OUT="${OUT:-./build}"
MODEL="${MODEL:-$HOME/models/model.gguf}"

PREFIX="/data/data/com.termux/files/usr"
NDK_SHADER_TOOLS="${NDK:-}/shader-tools/linux-x86_64"

# ---------------------------------------------------------------- args
BACKEND="bare"
JOBS="$(nproc)"
DO_BENCH=0
DO_CLEAN=0
DO_STAGE=0
DO_PERF=0
USE_DL=0
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bare)    BACKEND="bare"   ;;
    --vulkan)  BACKEND="vulkan" ;;
    --opencl)  BACKEND="opencl" ;;
    --dl)      USE_DL=1         ;;
    --bench)   DO_BENCH=1       ;;
    --clean)   DO_CLEAN=1       ;;
    --profile) BACKEND="profile";;
    --stage)   DO_STAGE=1       ;;
    --perf)    DO_PERF=1        ;;
    -j*)       JOBS="${1#-j}"   ;;
    -D*)       EXTRA+=("$1")    ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "lbuild: unknown option '$1'" >&2; exit 1 ;;
  esac
  shift
done

BUILD="$OUT/$BACKEND"

# ---------------------------------------------------------------- flags
# These -isystem paths are what make posix_spawn_file_actions_addchdir_np
# resolve. Termux's patched headers declare it; bionic's do not.
# Do not remove them.
CFLAGS_COMMON="-O3 -fstack-protector-strong"
CFLAGS_COMMON+=" -isystem$PREFIX/include/c++/v1 -isystem$PREFIX/include"

# -landroid-spawn must land AFTER the objects, which is why it goes on the
# linker line and not in LDFLAGS.
LINKER="$PREFIX/bin/ld.lld -L$PREFIX/lib"
LINKER+=" -Wl,--enable-new-dtags -Wl,--as-needed -Wl,-z,relro,-z,now"
LINKER+=" -landroid-spawn"

ARGS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_FLAGS="$CFLAGS_COMMON"
  -DCMAKE_CXX_FLAGS="$CFLAGS_COMMON"
  -DCMAKE_LINKER="$LINKER"
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
)

# Backend loading mode.
#   default: CPU backend compiled straight into the binary, one variant,
#            tuned for THIS device. No dlopen, no runtime dispatch --
#            what you build is what runs. Correct for kernel work.
#   --dl:    packaging mode. Separate libggml-*.so files, many CPU variants,
#            selected at runtime. Use only when producing a .deb.
if (( USE_DL )); then
  ARGS+=( -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON )
else
  ARGS+=( -DGGML_BACKEND_DL=OFF -DGGML_NATIVE=ON )
fi

if [[ "$BACKEND" == "profile" ]]; then
  # Standalone binary runnable as shell uid from /data/local/tmp.
  # Nothing may resolve back into $PREFIX -- that dir is 0700 termux-uid.
  CFLAGS_COMMON="-O3 -fstack-protector-strong"        # drop -isystem
  LINKER="$PREFIX/bin/ld.lld"                          # drop -landroid-spawn
  LINKER+=" -Wl,--as-needed -Wl,-z,relro,-z,now"
  ARGS=( "${ARGS[@]/-DBUILD_SHARED_LIBS=ON/-DBUILD_SHARED_LIBS=OFF}" )
  ARGS+=(
    -DCMAKE_C_FLAGS="$CFLAGS_COMMON"
    -DCMAKE_CXX_FLAGS="$CFLAGS_COMMON"
    -DCMAKE_LINKER="$LINKER"
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    -DCMAKE_INSTALL_RPATH=""
    -DGGML_VULKAN=OFF -DGGML_OPENCL=OFF
    -DGGML_BACKEND_DL=OFF -DGGML_NATIVE=ON -DLLAMA_CURL=OFF
  )
fi

if (( DO_STAGE )); then
  TMP=/data/local/tmp
  cp "$BUILD/bin/llama-bench" "$MODEL" /sdcard/
  ./rish -c "cp /sdcard/llama-bench /sdcard/$(basename "$MODEL") $TMP/ \
             && chmod 755 $TMP/llama-bench"
fi

if (( DO_PERF )); then
  EV="cpu-cycles:u,instructions:u,raw-stall-backend:u,raw-ll-cache-miss-rd:u"
  echo ">>> cooling down 60s"
  sleep 60
  ./rish -c "cd /data/local/tmp && simpleperf stat -e $EV --per-core \
             -- ./llama-bench -m $(basename "$MODEL") -p 0 -n 128 -t ${THREADS:-8}"
fi

case "$BACKEND" in
  bare)
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

echo ">>> backend=$BACKEND  src=$SRC  build=$BUILD"
cmake -S "$SRC" -B "$BUILD" "${ARGS[@]}"
cmake --build "$BUILD" -j"$JOBS"

echo ">>> binaries in $BUILD/bin"

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

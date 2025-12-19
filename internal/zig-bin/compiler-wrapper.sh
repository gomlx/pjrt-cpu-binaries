#!/bin/bash
ZIG_EXEC=$(which zig)
TARGET="-target x86_64-linux-gnu.2.34"
FLAGS="-Wno-unused-command-line-argument"

# Permissive flags for a Fat Binary:
# +evex512: Allows 512-bit registers (AVX-512)
# +avx512f, +avx512cd, +avx512bw, +avx512dq, +avx512vl: Standard AVX-512 block
# +avx512bf16, +avx512vnni: DL-specific extensions
FLAGS="${FLAGS} -mevex512"

# Errors with abort due to invalid ABI? Here is the error log:
# libc++abi: terminating due to uncaught exception of type std::__1::system_error: recursive_mutex lock failed: Invalid argument
# SIGABRT: abort
FLAGS="${FLAGS} -unwindlib=libunwind -rtlib=compiler-rt -stdlib=libstdc++"

# 1. Mode Detection
if [[ "$(basename "$0")" == *"++"* ]]; then
  CMD="c++"
  # Force Zig to use its internal libc++ rather than searching host paths
  STDLIB_FLAGS="-stdlib=libc++"
else
  CMD="cc"
  STDLIB_FLAGS=""
fi

# Force C++: bazel expects clang to behave like a C++ compiler.
CMD="c++"

if [ -z "$ZIG_GLOBAL_CACHE_DIR" ]; then
  # Fallback if Bazel didn't pass the env var correctly
  export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
  export ZIG_LOCAL_CACHE_DIR="/tmp/zig-cache"
  mkdir -p /tmp/zig-cache
fi

# 3. Handle STDIN (Critical for Bazel's feature detection)
IS_STDIN=0
for arg in "$@"; do
  if [[ "$arg" == "-" ]]; then IS_STDIN=1; break; fi
done

if [ "$IS_STDIN" -eq 1 ]; then
  # Use .cpp extension to force C++ mode if needed
  EXT=$([[ "$CMD" == "c++" ]] && echo "cpp" || echo "c")
  TMP_FILE=$(mktemp .tmp_XXXXXX.$EXT)
  cat > "$TMP_FILE"

  ARGS=()
  for arg in "$@"; do
    [[ "$arg" == "-" ]] && ARGS+=("$TMP_FILE") || ARGS+=("$arg")
  done

  "$ZIG_EXEC" "$CMD" $TARGET $STDLIB_FLAGS $FLAGS "${ARGS[@]}"
  EXIT_CODE=$?
  rm -f "$TMP_FILE"
  exit $EXIT_CODE
else
  exec "$ZIG_EXEC" "$CMD" $TARGET $FLAGS $STDLIB_FLAGS "$@"
fi

# Use Amazon Linux 2023 as the base image for glibc 2.34 compatibility
FROM amazonlinux:2023

# --- Install Dependencies and Fix DNF Conflict ---
# Fix DNF package conflict (curl-minimal vs curl) with --allowerasing
# Install tools: git, tar, make, C++ toolchain headers, clang20, lld20, binutils, python, pip, xz, curl
RUN dnf update -y && \
    dnf install -y --allowerasing \
    git tar make gcc-c++ binutils \
    clang20 lld20 \
    python3 python3-pip python3-devel \
    curl xz && \
    ln -sf /usr/lib64/llvm20/bin/clang /usr/bin/clang && \
    ln -sf /usr/lib64/llvm20/bin/clang++ /usr/bin/clang++ && \
    ln -sf /usr/lib64/llvm20/bin/ld.lld /usr/bin/ld.lld

# --- Environment Setup ---
ENV LLVM_VERSION=20
ENV LLVM_PATH="/usr/lib64/llvm20"
ENV PATH="${LLVM_PATH}/bin:$PATH"
ENV CC="${LLVM_PATH}/bin/clang"
ENV CXX="${LLVM_PATH}/bin/clang++"
ENV BAZEL_COMPILER="clang"
ENV HERMETIC_PYTHON_VERSION="3.11"
ENV BUILD_DIR="/app"
WORKDIR ${BUILD_DIR}

# --- Python Dependencies ---
RUN pip3 install six numpy

# --- Bazelisk Installation ---
# Install Bazelisk, rename it to 'bazel', and place it in /usr/local/bin to be on the default PATH.
RUN curl -LO "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64" && \
    chmod +x bazelisk-linux-amd64 && \
    mv bazelisk-linux-amd64 /usr/local/bin/bazel

RUN python3 --version

# --- Copy Project Files ---
# Assuming this Dockerfile is run from the root of the 'pjrt-cpu-binaries' repository
# This makes BUILDER_VERSION.txt and XLA_COMMIT_HASH.txt available.
COPY BUILDER_VERSION.txt ${BUILD_DIR}
COPY XLA_COMMIT_HASH.txt ${BUILD_DIR}

# --- Clone External Repository ---
# Fetch only the specific commit needed to save time and disk space.
RUN XLA_COMMIT_HASH="$(cat XLA_COMMIT_HASH.txt)" && \
    echo "Cloning XLA at commit hash ${XLA_COMMIT_HASH}" && \
    mkdir xla && cd xla && \
    git init && \
    git remote add origin https://github.com/openxla/xla && \
    git fetch --depth 1 origin "${XLA_COMMIT_HASH}" && \
    git checkout "${XLA_COMMIT_HASH}"

# --- Build Command ---
RUN <<EOF
# Exit immediately if a command exits with a non-zero status
set -e
# Print commands and their arguments as they are executed (Great for debugging!)
set -x

BUILDER_VERSION=$(cat BUILDER_VERSION.txt)
PJRT_C_API_HEADER="./xla/xla/pjrt/c/pjrt_c_api.h"

MAJOR=$(grep -E '#define PJRT_API_MAJOR' "${PJRT_C_API_HEADER}" | awk '{print $3}')
MINOR=$(grep -E '#define PJRT_API_MINOR' "${PJRT_C_API_HEADER}" | awk '{print $3}')
RELEASE_VERSION="v${MAJOR}.${MINOR}.${BUILDER_VERSION}"

echo "Building PJRT CPU plugin ${RELEASE_VERSION}"
cd xla
printf "\n- Configuring XLA build:\n"
python3 ./configure.py \
  --backend CPU \
  --os LINUX \
  --host_compiler CLANG \
  --clang_path "${CC}"

printf "\n- Starting XLA bazel build:\n"
bazel build -c opt //xla/service/cpu:runtime_matmul \
  --action_env=CC="$CC" \
  --action_env=CXX="$CXX" \
  --linkopt="-fuse-ld=lld"
bazel build -c opt //xla/pjrt/c:pjrt_c_api_cpu_plugin.so \
  --action_env=CC="$CC" \
  --action_env=CXX="$CXX" \
  --linkopt="-fuse-ld=lld"

printf "\n- Verifying glibc requirements:\n"
objdump -p bazel-bin/xla/pjrt/c/pjrt_c_api_cpu_plugin.so | grep GLIBC

cd ..

BINARY_NAME="pjrt_c_api_cpu_plugin.so"
NEW_BINARY_NAME="pjrt_c_api_cpu_${RELEASE_VERSION}_plugin.so"
BUILD_DIR="xla/bazel-bin/xla/pjrt/c"
TARBALL_NAME="pjrt_cpu_amazonlinux_amd64.tar.gz"

printf "\n- Packaging to ${TARBALL_NAME}\n"
mv "${BUILD_DIR}/${BINARY_NAME}" "${NEW_BINARY_NAME}"
rm -rf xla/   # Free up space, before creating tarball.
tar -czvf "${TARBALL_NAME}" "${NEW_BINARY_NAME}"

echo "✅ Successfully created ${TARBALL_NAME} containing ${NEW_BINARY_NAME}"
EOF

# Use /bin/bash as the entry point for interactive exploration/debugging
CMD ["/bin/bash"]

FROM scratch AS export
COPY --from=0 /app/pjrt_cpu_amazonlinux_amd64.tar.gz .

# Kernel builder image for the bench harness. Simpler than the pinned
# ghcr.io/edera-dev/kernel-buildenv (no sccache, no uv, no Python 3.14, no
# published-digest reproducibility). All deps land at image-build time -- so
# `podman run` as a non-root user (which this sandbox forces) doesn't need to
# apt-get anything.
FROM docker.io/library/debian:bookworm-slim

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential bison flex bc libssl-dev libelf-dev pahole kmod cpio \
      xz-utils zstd curl ca-certificates patch python3 python3-yaml python3-packaging \
      gnupg && \
    rm -rf /var/lib/apt/lists/*

# Clang/lld/llvm 18 from apt.llvm.org, only zone-lto uses this (bookworm's own
# clang-14 predates the kernel's >=15 minimum). Baking it in keeps zone-lto
# builds simple; other flavors ignore it.
ARG LLVM_VERSION=18
RUN export DEBIAN_FRONTEND=noninteractive && \
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
      | gpg --dearmor >/usr/share/keyrings/llvm.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-${LLVM_VERSION} main" \
      >/etc/apt/sources.list.d/llvm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      "clang-${LLVM_VERSION}" "lld-${LLVM_VERSION}" "llvm-${LLVM_VERSION}" && \
    rm -rf /var/lib/apt/lists/*

# Non-root by default -- matches how this sandbox runs containers -- with a
# writable HOME under /home/build. Kernel sources land in /tmp inside the
# container (a fresh tmpfs), NOT /build, so the sandbox-seal Landlock policy
# permits exec of the build's helper scripts.
RUN useradd -ms /bin/bash -u 1000 build
USER build
WORKDIR /tmp

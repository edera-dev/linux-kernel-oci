FROM --platform=$BUILDPLATFORM scratch AS kernelsrc
ARG KERNEL_SRC_URL=
ADD ${KERNEL_SRC_URL} /src.tar.xz

FROM --platform=$BUILDPLATFORM scratch AS firmware
ARG FIRMWARE_URL=
ARG FIRMWARE_SIG_URL=
ADD ${FIRMWARE_URL} /firmware.tar.xz
ADD ${FIRMWARE_SIG_URL} /firmware.tar.sign

FROM --platform=$BUILDPLATFORM debian:bookworm@sha256:0a5bf4ecacfc050bad0131c8e1401063fd1e8343a418723f6dbd3cd13a7b9e33 AS buildenv
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y \
      build-essential squashfs-tools python3-yaml \
      patch diffutils sed mawk findutils zstd \
      python3 python3-packaging curl rsync cpio gpg grep \
      flex bison pahole libssl-dev libelf-dev bc kmod ccache && \
      rm -rf /var/lib/apt/lists/*
ARG BUILDPLATFORM
RUN if [ "${BUILDPLATFORM}" = "linux/amd64" ]; then \
      apt-get update && apt-get install -y linux-headers-amd64 g++-aarch64-linux-gnu gcc-aarch64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
RUN if [ "${BUILDPLATFORM}" = "linux/arm64" ] || [ "${BUILDPLATFORM}" = "linux/aarch64" ]; then \
      apt-get update && apt-get install -y linux-headers-arm64 g++-x86-64-linux-gnu gcc-x86-64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
ENV PATH="/usr/lib/ccache:${PATH}"
RUN useradd -ms /bin/sh build
COPY --chown=build:build . /build
USER build
WORKDIR /build
RUN chmod +x hack/build/docker-build-internal.sh

FROM buildenv AS build-staged
COPY --from=kernelsrc --chown=build:build /src.tar.xz /build/override-kernel-src.tar.xz

FROM build-staged AS build-staged-amdgpu
COPY --from=firmware --chown=build:build /firmware.tar.xz /build/override-firmware.tar.xz
COPY --from=firmware --chown=build:build /firmware.tar.sign /build/override-firmware.tar.sign

FROM scratch AS kernel-ccachebuild
COPY --from=ccachebuild kernel /kernel/image
COPY --from=ccachebuild config.gz /kernel/config.gz
COPY --from=ccachebuild addons.squashfs /kernel/addons.squashfs
COPY --from=ccachebuild metadata /kernel/metadata

FROM alpine:3.23@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS sdkbuild-ccachebuild
ARG KERNEL_VERSION=
ARG KERNEL_FLAVOR=zone
COPY --from=ccachebuild sdk.tar.gz /sdk.tar.gz
RUN mkdir -p /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} && \
    tar -zx -C /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} -f /sdk.tar.gz && \
    mkdir -p /lib/modules/${KERNEL_VERSION} && \
    ln -sf /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} /lib/modules/${KERNEL_VERSION}/build && \
    rm -rf /sdk.tar.gz

FROM scratch AS sdk-ccachebuild
COPY --from=sdkbuild-ccachebuild /usr/src /usr/src

FROM --platform=$BUILDPLATFORM scratch AS kernelsrc
ARG KERNEL_SRC_URL=
ADD ${KERNEL_SRC_URL} /src.tar.xz

FROM --platform=$BUILDPLATFORM debian:bookworm@sha256:17122fe3d66916e55c0cbd5bbf54bb3f87b3582f4d86a755a0fd3498d360f91b AS buildenv
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y \
      build-essential squashfs-tools python3-yaml \
      patch diffutils sed mawk findutils zstd \
      python3 python3-packaging curl rsync cpio \
      flex bison pahole libssl-dev libelf-dev bc kmod && \
      rm -rf /var/lib/apt/lists/*
ARG BUILDPLATFORM
RUN if [ "${BUILDPLATFORM}" = "linux/amd64" ]; then \
      apt-get update && apt-get install -y linux-headers-amd64 gcc-aarch64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
RUN if [ "${BUILDPLATFORM}" = "linux/arm64" ] || [ "${BUILDPLATFORM}" = "linux/aarch64" ]; then \
      apt-get update && apt-get install -y linux-headers-arm64 gcc-x86-64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
RUN useradd -ms /bin/sh build
COPY --chown=build:build . /build
USER build
WORKDIR /build
RUN chmod +x hack/build/docker-build-internal.sh

FROM buildenv AS build
ARG KERNEL_VERSION=
ARG KERNEL_FLAVOR=zone
ARG BUILDPLATFORM
ARG TARGETPLATFORM
COPY --from=kernelsrc --chown=build:build /src.tar.xz /build/override-kernel-src.tar.xz
RUN KERNEL_SRC_URL="/build/override-kernel-src.tar.xz" ./hack/build/docker-build-internal.sh

FROM alpine:3.20@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a AS sdkbuild
ARG KERNEL_VERSION=
ARG KERNEL_FLAVOR=zone
COPY --from=build /build/target/sdk.tar.gz /sdk.tar.gz
RUN mkdir -p /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} && \
    tar -zx -C /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} -f /sdk.tar.gz && \
    mkdir -p /lib/modules/${KERNEL_VERSION} && \
    ln -sf /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} /lib/modules/${KERNEL_VERSION}/build && \
    rm -rf /sdk.tar.gz

FROM scratch AS sdk
COPY --from=sdkbuild /usr/src /usr/src    

FROM scratch AS kernelcopy
COPY --from=build /build/target/kernel /kernel/image
COPY --from=build /build/target/config.gz /kernel/config.gz
COPY --from=build /build/target/addons.squashfs /kernel/addons.squashfs
COPY --from=build /build/target/metadata /kernel/metadata

FROM scratch AS kernel
COPY --from=kernelcopy /kernel /kernel

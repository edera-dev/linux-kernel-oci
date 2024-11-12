FROM --platform=$BUILDPLATFORM scratch AS kernelsrc
ARG KERNEL_SRC_URL=
ADD ${KERNEL_SRC_URL} /src.tar.gz

FROM --platform=$BUILDPLATFORM debian:bookworm@sha256:10901ccd8d249047f9761845b4594f121edef079cfd8224edebd9ea726f0a7f6 AS buildenv
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y \
      build-essential squashfs-tools \
      patch diffutils sed mawk findutils zstd \
      python3 python3-packaging curl rsync cpio \
      flex bison pahole libssl-dev libelf-dev bc && \
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
COPY --from=kernelsrc --chown=build:build /src.tar.gz /build/override-kernel-src.tar.gz
RUN KERNEL_SRC_URL="/build/override-kernel-src.tar.gz" ./hack/build/docker-build-internal.sh

FROM alpine:3.20@sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d AS sdkbuild
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

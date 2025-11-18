FROM --platform=$BUILDPLATFORM scratch AS kernelsrc
ARG KERNEL_SRC_URL=
ADD ${KERNEL_SRC_URL} /src.tar.xz

FROM --platform=$BUILDPLATFORM scratch AS firmware
ARG FIRMWARE_URL=
ARG FIRMWARE_SIG_URL=
ADD ${FIRMWARE_URL} /firmware.tar.xz
ADD ${FIRMWARE_SIG_URL} /firmware.tar.sign

FROM --platform=$BUILDPLATFORM debian:bookworm@sha256:6337ad82d5c764a8b6a16cde86b157fdce353e36d8ca06fc1b16d4f34d29960e AS buildenv
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y \
      build-essential squashfs-tools python3-yaml \
      patch diffutils sed mawk findutils zstd \
      python3 python3-packaging curl rsync cpio gpg grep \
      flex bison pahole libssl-dev libelf-dev bc kmod && \
      rm -rf /var/lib/apt/lists/*
ARG BUILDPLATFORM
RUN if [ "${BUILDPLATFORM}" = "linux/amd64" ]; then \
      apt-get update && apt-get install -y linux-headers-amd64 g++-aarch64-linux-gnu gcc-aarch64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
RUN if [ "${BUILDPLATFORM}" = "linux/arm64" ] || [ "${BUILDPLATFORM}" = "linux/aarch64" ]; then \
      apt-get update && apt-get install -y linux-headers-arm64 g++-x86-64-linux-gnu gcc-x86-64-linux-gnu && rm -rf /var/lib/apt/lists/*; fi
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
COPY --from=firmware --chown=build:build /firmware.tar.xz /build/override-firmware.tar.xz
COPY --from=firmware --chown=build:build /firmware.tar.sign /build/override-firmware.tar.sign
RUN if [ "${KERNEL_FLAVOR}" = "zone-amdgpu" ]; then \
        FIRMWARE_SIG_URL="/build/override-firmware.tar.sign" \
        FIRMWARE_URL="/build/override-firmware.tar.xz" \
        KERNEL_SRC_URL="/build/override-kernel-src.tar.xz" \
        ./hack/build/docker-build-internal.sh; \
    else \
        KERNEL_SRC_URL="/build/override-kernel-src.tar.xz" \
        ./hack/build/docker-build-internal.sh; \
    fi

FROM alpine:3.22@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS sdkbuild
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

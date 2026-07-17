FROM --platform=$BUILDPLATFORM scratch AS kernelsrc
ARG KERNEL_SRC_URL=
ADD ${KERNEL_SRC_URL} /src.tar.xz

FROM --platform=$BUILDPLATFORM scratch AS firmware
ARG FIRMWARE_URL=
ARG FIRMWARE_SIG_URL=
ADD ${FIRMWARE_URL} /firmware.tar.xz
ADD ${FIRMWARE_SIG_URL} /firmware.tar.sign

FROM --platform=$BUILDPLATFORM scratch AS nvidia-modules
ARG NV_MODULES_TARBALL_URL=
ADD ${NV_MODULES_TARBALL_URL} /nvidia-modules.tar.gz

# The toolchain (compilers, kbuild deps, sccache + wrappers) comes from the
# published build environment image so it only changes via deliberate,
# reviewed digest bumps - see Dockerfile.buildenv and buildenv.yml. Dependabot
# keeps the pin current, with buildenv-diff.yml summarizing the package
# changes in each bump PR.
FROM --platform=$BUILDPLATFORM ghcr.io/edera-dev/kernel-buildenv:latest@sha256:5f1111cde2487436b4102ae876c1810c304760a3accbb4ba51ff3f725b7374eb AS buildenv
COPY --chown=build:build . /build
USER build
WORKDIR /build
RUN chmod +x hack/build/docker-build-internal.sh

FROM buildenv AS build-staged
COPY --from=kernelsrc --chown=build:build /src.tar.xz /build/override-kernel-src.tar.xz

FROM build-staged AS build-staged-amdgpu
COPY --from=firmware --chown=build:build /firmware.tar.xz /build/override-firmware.tar.xz
COPY --from=firmware --chown=build:build /firmware.tar.sign /build/override-firmware.tar.sign

FROM build-staged AS build-staged-nvidiagpu
COPY --from=nvidia-modules --chown=build:build /nvidia-modules.tar.gz /build/override-nvidia-modules.tar.gz

FROM scratch AS kernel-prebuilt
COPY --from=prebuilt kernel /kernel/image
COPY --from=prebuilt config.gz /kernel/config.gz
COPY --from=prebuilt addons.squashfs /kernel/addons.squashfs
COPY --from=prebuilt metadata /kernel/metadata

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS sdkbuild-prebuilt
ARG KERNEL_FLAVOR=zone
COPY --from=prebuilt sdk.tar.gz /sdk.tar.gz
COPY --from=prebuilt metadata /metadata
RUN KERNEL_UNAME_R=$(grep '^KERNEL_UNAME_R=' /metadata | cut -d= -f2) && \
    mkdir -p /usr/src/kernel-sdk-${KERNEL_UNAME_R}-${KERNEL_FLAVOR} && \
    tar -zx -C /usr/src/kernel-sdk-${KERNEL_UNAME_R}-${KERNEL_FLAVOR} -f /sdk.tar.gz && \
    mkdir -p /lib/modules/${KERNEL_UNAME_R} && \
    ln -sf /usr/src/kernel-sdk-${KERNEL_UNAME_R}-${KERNEL_FLAVOR} /lib/modules/${KERNEL_UNAME_R}/build && \
    rm -rf /sdk.tar.gz /metadata

FROM scratch AS sdk-prebuilt
COPY --from=sdkbuild-prebuilt /usr/src /usr/src

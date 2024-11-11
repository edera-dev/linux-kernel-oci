ARG KERNEL_BUILDENV_TAG=latest
FROM ghcr.io/edera-dev/linux-kernel-buildenv:${KERNEL_BUILDENV_TAG} AS build

ARG KERNEL_VERSION=
ARG KERNEL_BUILD_JOBS=
ARG KERNEL_FLAVOR=zone
RUN ./hack/build/docker-build-internal.sh

FROM scratch AS intermediate
COPY --from=build /build/target/kernel /kernel/image
COPY --from=build /build/target/config.gz /kernel/config.gz
COPY --from=build /build/target/addons.squashfs /kernel/addons.squashfs
COPY --from=build /build/target/addons.squashfs /kernel/metadata

FROM scratch
COPY --from=intermediate /kernel /kernel

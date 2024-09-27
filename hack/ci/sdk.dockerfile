FROM alpine:latest AS builder
COPY . /all
ARG KERNEL_VERSION=unknown
ARG KERNEL_FLAVOR=zone
RUN mkdir -p /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} && \
    tar -zx -C /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} -f /all/kernel-$(uname -m)-${KERNEL_VERSION}-${KERNEL_FLAVOR}/sdk.tar.gz && \
    mkdir -p /lib/modules/${KERNEL_VERSION} && \
    ln -sf /usr/src/kernel-sdk-${KERNEL_VERSION}-${KERNEL_FLAVOR} /lib/modules/${KERNEL_VERSION}/build && \
    rm -rf /all

FROM scratch
COPY --from=builder /usr/src /usr/src

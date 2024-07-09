FROM alpine:latest AS builder
COPY . /all
ARG KERNEL_VERSION=unknown
ARG KERNEL_FLAVOR=standard
RUN mkdir -p /kernel && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}-${KERNEL_FLAVOR}/kernel" /kernel/image && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}-${KERNEL_FLAVOR}/addons.squashfs" /kernel/addons.squashfs && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}-${KERNEL_FLAVOR}/config.gz" /kernel/config.gz && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}-${KERNEL_FLAVOR}/metadata" /kernel/metadata && \
    rm -rf /all

FROM scratch
COPY --from=builder /kernel /kernel

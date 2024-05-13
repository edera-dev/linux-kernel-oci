FROM alpine:latest AS builder
COPY . /all
ARG KERNEL_VERSION=unknown
RUN mkdir -p /kernel && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}/kernel" /kernel/image && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}/addons.squashfs" /kernel/addons.squashfs && \
    cp "/all/kernel-$(uname -m)-${KERNEL_VERSION}/metadata" /kernel/metadata && \
    rm -rf /all

FROM scratch
COPY --from=builder /kernel /kernel

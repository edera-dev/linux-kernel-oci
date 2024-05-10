FROM scratch
COPY kernel /kernel/image
COPY addons.squashfs /kernel/addons.squashfs

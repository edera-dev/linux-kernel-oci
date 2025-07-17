# linux-kernel-oci

Builds the Linux kernel into OCI images.

## Build overview

This repo is a series of helper scripts and Github Actions that

1. Use [config.yaml](config.yaml) and various scripts in `hack/build` to generate a matrix of kernel upstream versions, variants, and flavors to be built.
1. Fetches `kernel.org` tarballs, applies custom config flags, and patches, depending on version, flavor and variant.
1. Builds those kernels for x86_64/arm64.

### Variant and flavor configs

See the [configs](configs/README.md) directory for more info.

### Patches

See the [patches](patches) directory for the current set of patches Edera carries against upstream kernels.

Note that not all the patches will be applied to all kernel versions, this is driven by version constraints in [config.yaml](config.yaml).


### Building a custom debug kernel locally

For most of the kernels in this registry, debugging symbols and features are disabled, to keep the kernel artifacts small.

You may want or need to build your own debugging kernel with custom patches/options locally, and publish it to a transient OCI registry (like [](ttl.sh)) for testing purposes.

To do this, you will need `docker` installed and configured correctly to support cross-builds (`docker buildx`) in your local environment.

The simplest way to do that is to

1. Clone this repo locally: `git clone git@github.com:edera-dev/linux-kernel-oci.git`
1. Manually edit [config.yaml](config.yaml) on-disk:
   - to change the `imageNameFormat` key to push to an OCI registry you have access to.
   - to change the `architectures` YAML key to only include the architectures you care about (x86_64, arm64, or both - `docker buildx` is used so you can build arm64 on x86_64 and vice-versa).
   - to change the `flavors` YAML key to only include the flavors you care about (host, or zone, or both).
   - to change the `versions` YAML key to only include the `kernel.org` versions you care about. For instance, to only build the latest `5.4` kernel.org upstream release, use:

        ```yaml
        versions:
            - series: '5.4'
        ```

1. For example, if I wanted to only build the `zone` kernel flavor, only for `x86_64`, only the latest `6.15` point release, and tag the result for a custom `ttl.sh/hackben` registry, the final result would look something like this:

   ```yaml
    imageNameFormat: "ttl.sh/hackben/[image]:[tag]"
    architectures:
    - x86_64
    flavors:
    - name: zone-debu
    constraints:
        series:
        - '6.15'
    versions:
    - current: true
   ```

1. Run [hack/build/docker-build.sh](hack/build/docker-build.sh)
   - It is **important** you follow step 2 above, and edit the [config.yaml](config.yaml) locally to reduce the number of kernels the script will try to build, or you may end up building 15+ different kernels in parallel on your local box, which will take a very, very long time.
   - When this command runs, it will generate a build matrix and print out what it will build.
1. When the above command finishes, you can see the local OCI images that were built by running `docker image list`. The images will be tagged with the repo you specified in `imageNameFormat` in the [config.yaml](config.yaml).
1. From this point, you may push those images to an OCI registry with standard commands like `docker image push <image tag>`, and consume them how you wish.
1. If you wish to unpack and inspect the image (for instance, to make sure certain modules or firmware exist in the correct paths, or that the final `config.gz` has the options you expect), you can then do the following to fetch and extract the image artifact you just pushed to your local disk with [`crane`](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md):

    ```sh
    crane export  ttl.sh/hackben/zone-kernel:6.15.6 - --platform=linux/amd64 | tar --keep-directory-symlink -xf - -C .
    cd `kernel`
    zcat config.gz
    unsquashfs addons.squashfs
    ...
    ```

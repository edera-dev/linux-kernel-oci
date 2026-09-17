# linux-kernel-oci

Builds the Linux kernel into OCI images.

## Build overview

Kernels are built from [github.com/edera-dev/linux](https://github.com/edera-dev/linux), Edera's downstream
Linux tree. Every Edera change is a commit on a branch there, so this repo carries no patch series of its
own: whatever the branch says is what gets built.

This repo is a series of helper scripts and Github Actions that

1. Resolve each branch listed in [config.yaml](/config.yaml) to the commit it currently points at, and read
   the kernel version out of that commit's `Makefile`.
1. Use that, plus the flavors and architectures in `config.yaml`, to generate a build matrix.
1. Fetch the source archive for that exact commit, apply the Edera kconfig fragments, and build for
   x86_64/aarch64.

### Branches

| Branch in `config.yaml` | Ref on `edera-dev/linux` | What it is |
| --- | --- | --- |
| `6.18-lts` | `edera/6.18-lts` | The 6.18 LTS series with the Edera stack. Also publishes `latest`. |
| `mainline` | `edera/mainline` | Current mainline (including `-rc`) with the Edera stack. |

Adding a branch is three lines in `config.yaml`; nothing else needs to know about it.

### Image tags

Each build publishes one immutable tag and a set of moving aliases. For example, `edera/6.18-lts` at
6.18.52, commit `efb09285bd95`:

| Tag | Moves? |
| --- | --- |
| `zone-kernel:6.18.52-gefb09285bd95` | no - one commit, forever |
| `zone-kernel:6.18.52` | yes |
| `zone-kernel:6.18` | yes |
| `zone-kernel:6.18-lts` | yes |
| `zone-kernel:latest` | yes |

and `edera/mainline` at 7.3-rc3, commit `391f6f12ecf5`, publishes `7.3.0-rc3-g391f6f12ecf5`, `7.3.0-rc3` and
`mainline`. A prerelease deliberately does not claim the bare series tag (`7.3`), which belongs to the
eventual 7.3 release.

The immutable tag names the *source tree*, not every build input. A change to a kconfig fragment in
[configs](/configs) rebuilds and republishes the same tags against the same commit; the kernel inside
changes, the tag does not. `config.gz` and the image's `metadata` (which records
`KERNEL_SRC_REPO`/`KERNEL_SRC_REF`/`KERNEL_SRC_COMMIT` alongside a hash of the kconfig) are what
distinguish two such builds.

### Build specifications

The `Build Kernels` action takes a build spec of `<type>[:<constraints>]`:

- `new` (default) - build only what the registry does not already have. Since each build carries an
  immutable `<version>-g<commit>` tag, this means "build every branch that has moved". This is what the
  weekly cron runs.
- `rebuild` - build everything the config selects, published or not. Use this when something other than the
  kernel source changed: a kconfig fragment, the buildenv, the packaging. A merge touching `configs/**`
  triggers this automatically.

Constraints are semicolon-separated `key=value` pairs over `branch`, `flavor` and `arch`, with
comma-separated values:

```
new
rebuild:branch=mainline
rebuild:branch=6.18-lts;flavor=host,zone
new:flavor=zone;arch=aarch64
```

### Variant and flavor configs

See the [configs](/configs/README.md) directory for more info.

## Building your own kernels with custom KConfig (Using Github Actions)

1. Fork [this repo](https://github.com/edera-dev/linux-kernel-oci.git) into your Github org/account.
1. Inspect the Github Action file [.github/workflows/build.yaml](/.github/workflows/build.yaml):
   1. This will use the default `GITHUB_TOKEN` granted to all Github Action workflows by default to push OCI images to `ghcr.io` in your fork's context. Refer to [Github's documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) for details on access permissions and how `GITHUB_TOKEN` works.
   1. You should not need to make changes to this file, but it is best practice to understand what an Action does and what permissions it expects **before** you run it.
1. Edit [config.yaml](/config.yaml) in the root of your fork:
   1. Edit the line `imageNameFormat: "ghcr.io/edera-dev/[image]:[tag]"` and change it to `imageNameFormat: "ghcr.io/<your GH org>/[image]:[tag]"`
   1. Add or remove any `Kconfig` options you want to the `flavor` and `variant` Kconfig fragments in [configs](/configs), as outlined by the [README](/configs/README.md) in that folder.
   1. Commit those changes to `main` in your fork.
1. From your forked repository's `Actions` tab, run the `Build Kernels` job with a Build Specification like: `rebuild:flavor=zone,host`. This will build the `zone` and `host` flavors of every branch in `config.yaml`.
   1. ![Example](/images/job-example.png)

## Building your own kernels with custom KConfig (Locally, for debugging)

For most of the kernels in this registry, debugging symbols and features are disabled, to keep the kernel artifacts small.

You may want or need to build your own debugging kernel with custom options locally, and publish it to a transient OCI registry (like [ttl.sh](ttl.sh)) for testing purposes.

To do this, you will need `docker` installed and configured correctly to support cross-builds (`docker buildx`) in your local environment.

The simplest way to do that is to

1. Clone this repo locally: `git clone git@github.com:edera-dev/linux-kernel-oci.git`
1. Manually edit [config.yaml](/config.yaml) on-disk:
   - to change the `imageNameFormat` key to push to an OCI registry you have access to.
   - to change the `architectures` YAML key to only include the architectures you care about (x86_64, aarch64, or both - `docker buildx` is used so you can build aarch64 on x86_64 and vice-versa).
   - to change the `flavors` YAML key to only include the flavors you care about (host, or zone, or both).
   - to change the `branches` YAML key to only include the branches you care about. You can also point
     `source.repo` at your own fork of `edera-dev/linux` and list a branch on it.
   - For example, if I wanted to only build the `zone` kernel flavor, only for `x86_64`, only from the LTS
     branch, and tag the result for a custom `ttl.sh/hackben` registry, the final result would look
     something like this:

        ```yaml
            imageNameFormat: "ttl.sh/hackben/[image]:[tag]"
            source:
              repo: https://github.com/edera-dev/linux
            branches:
            - name: 6.18-lts
              ref: edera/6.18-lts
            architectures:
            - x86_64
            flavors:
            - name: zone
        ```

1. Add or remove any `Kconfig` options you want to the `flavor` and `variant` Kconfig fragments in [configs](/configs), as outlined by the [README](/configs/README.md) in that folder.
1. Run [hack/build/docker-build.sh](hack/build/docker-build.sh)
   - It is **important** you follow the previous step, and edit the [config.yaml](config.yaml) locally to reduce the number of kernels the script will try to build, or you may end up building many different kernels in parallel on your local box, which will take a very, very long time.
   - When this command runs, it will generate a build matrix and print out what it will build.
   - Pass a build spec as the first argument to narrow it further, e.g.
     `./hack/build/docker-build.sh 'rebuild:branch=6.18-lts;flavor=zone'` (quote it - `;` is a shell
     metacharacter).
1. When the above command finishes, you can see the local OCI images that were built by running `docker image list`. The images will be tagged with the repo you specified in `imageNameFormat` in the [config.yaml](/config.yaml).
1. From this point, you may push those images to an OCI registry with standard commands like `docker image push <image tag>`, and consume them how you wish.
1. If you wish to unpack and inspect the final image (for instance, to make sure certain modules or firmware exist in the correct paths, or that the final `config.gz` has the options you expect), you can do the following to fetch and extract the image artifact you just pushed to your local disk with [`crane`](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md):

    ```sh
    crane export  ttl.sh/hackben/zone-kernel:6.18-lts - --platform=linux/amd64 | tar --keep-directory-symlink -xf - -C .
    cd `kernel`
    zcat config.gz
    cat metadata
    unsquashfs addons.squashfs
    ...
    ```

### Building a branch that isn't in `config.yaml`

`hack/build/build.sh` takes `KERNEL_SRC_URL` directly and understands a `git::<url>[::<ref>]` form, which
clones that ref instead of fetching an archive. That is the escape hatch for building a work-in-progress
branch without listing it in `config.yaml` first. It expects the kbuild toolchain to already be present, so
run it inside the build environment image (`ghcr.io/edera-dev/kernel-buildenv`) rather than on a bare host:

```sh
KERNEL_VERSION=6.18.52 KERNEL_FLAVOR=zone \
  KERNEL_SRC_URL='git::https://github.com/edera-dev/linux::azenla/zone-perf' \
  ./hack/build/build.sh
```

# General config hierarchy

When a kernel is built, we layer various Edera config fragments on top of the upstream kernel's default config,
and (if selected) any variant configs on top of that, relying on the kernel's `make` system to do config merging.

## Difference between a `flavor` config and a `variant` config

`flavors` are the different basic kernels we ship. `variants` are variations on those `flavors`.

- The `flavor` configs are expressed as delta fragments from the upstream kernel's default config for the given architecture.
- The `variant` configs are expressed as delta fragments from the `flavor` configs for the given architecture.

When a kernel is built, we take the flavor config, and any variants (if defined) and overlay them on top of the default config. The result is the actual config the kernels are built with.

- We currently have two kernel `flavors` - `zone` and `host`
- We currently have two `zone` flavor `variants`, `zone-amdgpu` and `zone-openpax`

## Generating trimmed `flavor` configs

A "flavor config" is an Edera config fragment that contains only the Edera-specific changes from the latest stable _upstream_ kernel's default config file, for a given architecture.
Example: we want to generate a clean/updated `zone.config` against the latest default upstream 6.14.6 kernel config for x86_64
1. Run `./hack/build/generate-clean-flavor-config.sh 6.14.6 x86_64 configs/x86_64/zone.config my-updated-zone.config`
1. `my-updated-zone.config` should only have the kernel config options that are _not_ in the x86_64 default config for linux 6.14.6 now.
1. `cp my-updated-zone.config configs/x86_64/zone.config` and check in.
1. ditto for `host.config`, and `aarch64`.
1. It is strongly recommended to use the _oldest_ kernel version Edera currently supports as the base version, as newer kernels commonly add new defaults that were optional in older kernels.

## Generating trimmed `variant` configs

A "variant config" is an Edera config fragment that contains only the Edera-specific changes from the `flavor` config it belongs to, for a given architecture.
Example: we want to generate a clean/updated `zone-amdgpu.config` from the latest `zone.config`
1. Run `./hack/build/generate-clean-variant-config.sh 6.14.6 amd64 configs/x86_64/zone-amdgpu.fragment.config my-updated-zone-admgpu.fragment.config`
1. This will fetch & extract the latest full flavor `config` from `ghcr.io/edera-dev/zone-kernel:6.14.6`.
1. `my-updated-zone-admgpu.fragment` should only have the kernel config options that are _not_ in the extracted full flavor config now.
1. `cp my-updated-zone-admgpu.fragment configs/x86_64/zone-amdgpu.fragment.config`
1. It is strongly recommended to use the *oldest* kernel version Edera currently supports as the base version, as newer kernels commonly add new defaults that were optional in older kernels.

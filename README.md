# ekuOS kernel builder

Builds hardened x86-64 Linux kernels with Clang/LLVM. The default `eku.conf`
is shared by standalone and Gentoo builds. It enables common PC and VM
hardware, including built-in NVMe, SATA, USB storage, VirtIO, ext4 and Btrfs.
Its driver selection draws on Fedora and Ubuntu's x86-64 kernel configs and
includes signed modules for audio, networking, graphics, cameras, and laptop
and USB peripherals.

| Flavor | Security module | Artifacts |
| --- | --- | --- |
| `se` (primary) | Enforcing SELinux | `out/linux-eku-se/` |
| `aa` | AppArmor | `out/linux-eku-aa/` |

Both flavors enforce module signatures and confidentiality lockdown. Install
the appropriate userspace security policy separately.

Both also activate the [Microvisor LSM](https://github.com/ekuOS/microvisor-lsm).
Microvisor protects browser files marked with `security.microvisor` labels.
To add or change labels, boot with `microvisor` omitted from the `lsm=` list
and follow the upstream setup instructions. Include `microvisor` in any custom
`lsm=` list used for normal boots.

## Build locally

Requires Dart 3+, Git, GNU make and patch, Clang/LLVM and LLD 22+, Rust 1.85+
with its standard library sources (`rust-src`), bindgen 0.71.1+, flex, bison,
bc, and OpenSSL and libelf development headers.

```console
dart run build.dart --tag v7.3.6      # Build both flavors
dart run build.dart --tag v7.3.6 --flavor se
dart run build.dart --help           # Source, tag, config and other options
dart run build.dart clean --dry-run  # Preview cleanup; --keep-source preserves Linux
```

A missing source tree is cloned from the latest stable Linux tag by default.
Existing source trees are reused; patches in `patches/` are applied in filename
order. When Microvisor is enabled, the builder first clones its upstream
repository and merges the source from a pinned commit. The integration targets
Linux 7.3.6; use `--source` to choose a fresh directory if an existing source
tree is on a different version. The builder exports the kernel image, config
and signed modules; it does not install them or change the bootloader.

## Binary packages

The [installation guide](https://ekuos.github.io/kernel/en/installation)
explains how to install the signed packages with APT, DNF, pacman, or Portage.
It is also available in [日本語](https://ekuos.github.io/kernel/ja/installation)
and [简体中文](https://ekuos.github.io/kernel/zh-CN/installation).

Build tooling is [MIT-licensed](LICENSE); Linux and third-party patches
retain their own licenses.

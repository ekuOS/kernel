# ekuOS kernel builder

Builds hardened x86-64 Linux kernels with Clang/LLVM. The default `eku.conf`
is shared by standalone and Gentoo builds. It enables common PC and VM
hardware, including built-in NVMe, SATA, USB storage, VirtIO, ext4 and Btrfs.

| Flavor | Security module | Artifacts |
| --- | --- | --- |
| `se` (primary) | Enforcing SELinux | `out/linux-eku-se/` |
| `aa` | AppArmor | `out/linux-eku-aa/` |

Both flavors enforce module signatures and confidentiality lockdown. Install
the appropriate userspace security policy separately.

## Build locally

Requires Dart 3+, Git, GNU make and patch, Clang/LLVM and LLD 22+, flex,
bison, bc, and OpenSSL and libelf development headers.

```console
dart run build.dart                  # Build both flavors
dart run build.dart --flavor se      # Or build only SELinux
dart run build.dart --help           # Source, tag, config and other options
dart run build.dart clean --dry-run  # Preview cleanup; --keep-source preserves Linux
```

A missing source tree is cloned from the latest stable Linux tag by default.
Existing source trees are reused; patches in `patches/` are applied in filename
order. The builder exports the kernel image, config and signed modules; it
does not install them or change the bootloader.

## Gentoo

See [Gentoo binhost](packaging/gentoo/README.md) for signed packages,
Portage setup and GitHub Pages publication.

Build tooling is [MIT-licensed](LICENSE); Linux and third-party patches
retain their own licenses.

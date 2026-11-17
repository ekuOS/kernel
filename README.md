# ekuOS kernel builder

Build hardened Linux kernels using Dart as a scripting language. One command clones the source if needed, applies patches once, and builds two independent kernels:

| Flavor | Active major LSM | Kernel suffix | Build directory | Artifact directory |
| --- | --- | --- | --- | --- |
| `linux-eku-se` | SELinux | `-eku-se` | `build/linux-eku-se/` | `out/linux-eku-se/` |
| `linux-eku-aa` | AppArmor | `-eku-aa` | `build/linux-eku-aa/` | `out/linux-eku-aa/` |

Both kernels default to **confidentiality lockdown**. SELinux remains the primary system option; the AppArmor kernel provides an alternative security profile. The builder does not install kernels or change the bootloader.

## Requirements

- Dart SDK 3.0 or later; no pub packages or Bash/Python helper scripts are needed.
- Git, GNU make, GNU patch, Clang 22 or later, LLD, LLVM utilities, flex, bison, bc, OpenSSL development headers, and libelf development headers.
- An x86_64 Linux source tree compatible with the supplied Linux 7.4 profiles, or network access to clone it.

External commands are launched directly with argument lists. The kernel's own build system and native signing utility are used for compilation and module signing.

## Usage

```console
dart run build.dart
dart run build.dart --tag v7.4-rc3 --arch x86_64
dart run build.dart --flavor se
dart run build.dart --flavor aa
dart run build.dart --help
```

The default `--flavor both` builds SELinux first, then AppArmor, using all processors detected by Dart for each build. `--jobs NUMBER` overrides that count. The two builds run sequentially to avoid multiplying CPU and memory demand. Each has a separate configuration, kernel release, module signing key, and artifact bundle.

`--config` selects the common profile (default: `eku.conf`). The built-in flavor profile is merged afterward and takes precedence:

- `profiles/linux-eku-se.conf`: enforcing SELinux, with AppArmor disabled.
- `profiles/linux-eku-aa.conf`: AppArmor, with SELinux disabled, plus SquashFS, namespaces, and cgroup support.

Flavor profile paths are resolved relative to `build.dart`. Other relative paths are resolved against the current directory. `--output` and `--artifacts` select the parent directories of the flavor directories. Source and build paths must not contain spaces or shell metacharacters.

```console
dart run build.dart --source linux --config eku.conf --output build --artifacts out --jobs 8
```

For the original single generic build behavior, use `--flavor custom`. It adds no flavor profile or directory suffix and supports other architectures with a suitable configuration:

```console
dart run build.dart --flavor custom --config config.txt --source /path/to/linux
dart run build.dart --flavor custom --config config.txt --arch arm64 --llvm --target Image --target modules
```

## Source and patches

A missing or empty source directory is shallow-cloned from the official Torvalds Linux repository using `git clone --depth 1 --single-branch`. Without `--tag`, the clone uses upstream default branch HEAD. `--tag TAG` selects an exact tag; branch names are rejected as tag selections. `--repo URL` selects a mirror or a local repository.

Existing source trees are reused without fetching, pulling, resetting, or switching revisions. With `--tag`, the existing local tag must resolve to HEAD. Use a new source directory to change revisions or obtain a fresh upstream HEAD.

Files ending in `.patch` or `.diff` directly inside `patches/` are applied in filename order before either flavor builds. Use names such as `001-name.patch` with `a/` and `b/` paths for `patch -p1`. Each patch is dry-run first, and a successful reverse dry run identifies an already applied patch. Later patches that change the same lines can prevent this detection. Applied patches remain in the source tree if a later step fails.

## Hardening and LSM selection

The shared profile enables Clang/LLVM, enforced kCFI, x86 IBT, CPU mitigations, ASLR with increased mmap entropy, stack-offset randomization, strong stack protection, strict memory permissions, fortified copies, hardened usercopy, slab freelist protection, type-partitioned allocation caches, zero initialization, syscall stack erasure, enforced page-table checks, list corruption checks, and signed-module enforcement.

`LLVM=1` is a build setting, passed to every make invocation. `--llvm` also selects it. Linux 7.4 uses `CONFIG_CFI`; the older `CONFIG_CFI_CLANG` is transitional. kCFI does not require LTO. `CONFIG_CFI_AUTO_DEFAULT=n` selects kCFI instead of automatic FineIBT selection at boot.

Both profiles force `CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y`, with the `NONE` and `INTEGRITY` choices disabled. Confidentiality mode includes integrity restrictions and additionally restricts interfaces exposing kernel secrets. Some debugging, tracing, and performance-monitoring operations will be unavailable. Other tradeoffs include memory-zeroing and checking overhead, disabled hibernation/kexec/`/dev/mem`, and no legacy vsyscall mapping.

In the SELinux flavor, development/permissive support and the `selinux=0` boot parameter are disabled. A labeled filesystem and an appropriate enforcing userspace policy are required. The AppArmor flavor enables policy verification and introspection, but its userspace policies must still be installed and loaded.

The Linux 7.4-rc3 sources mark both SELinux and AppArmor with `LSM_FLAG_EXCLUSIVE`. They cannot be active together on this kernel; listing both in `CONFIG_LSM` does not provide simultaneous enforcement. Each flavor selects exactly one major LSM while retaining Landlock, Yama, SafeSetID, and lockdown. See the upstream [LSM documentation](https://docs.kernel.org/admin-guide/LSM/index.html), [Clang build documentation](https://docs.kernel.org/kbuild/llvm.html), and [kernel self-protection documentation](https://docs.kernel.org/security/self-protection.html).

## Runtime checks

Install the appropriate userspace policy tools and policies, then check the running system after boot:

```console
cat /sys/kernel/security/lsm
cat /sys/kernel/security/lockdown
# SELinux flavor:
getenforce
# AppArmor flavor:
aa-status
```

The active LSM list should include `apparmor` for the AppArmor flavor, or `selinux` for the SELinux flavor; lockdown should show `[confidentiality]`. Confirm that the selected LSM's policies are loaded and enforcing.

## Configuration syntax and build process

Write one `HOGE=value` or `CONFIG_HOGE=value` per line. Strings must use Kconfig quotes; `n` disables an option. Blank lines and `#` comments are ignored, except `# CONFIG_... is not set`, which disables the symbol. The last assignment wins. Put comments on separate lines; inline comments are treated as part of the value.

```text
LLVM=1
CONFIG_LOCALVERSION="-eku"
CONFIG_HARDENED_USERCOPY=y
CONFIG_DEVMEM=n
```

Each flavor starts from `make O=... defconfig` (override with `--defconfig`), merges the common and flavor settings, and runs `olddefconfig`. Every requested value must survive dependency resolution; otherwise the build stops and reports the mismatch. Compilation then runs with the detected CPU count and optional repeated `--target` selections. Manual edits to generated `.config` files are discarded on the next run. Unset `KCONFIG_CONFIG` before running the builder.

## Artifacts and logs

Each flavor exports `bzImage`, `vmlinux`, `System.map`, `.config`, module metadata, and the modules listed in `modules.order` under its own artifact directory. `build-profile.conf` contains the effective merged profile. `build-info.json` records the flavor, source revision, compiler, parallelism, signed module count, and file sizes.

When module signing is selected, copied modules are signed with Kbuild's native `scripts/sign-file`. `signing_key.x509` contains the public certificate; the private key remains in that flavor's build directory. `modules/` is an artifact bundle, not a populated `/lib/modules/<release>` installation. Each flavor's keys and modules belong to its own kernel.

Artifacts are copied after successful configuration verification and compilation. Matching filenames are overwritten; unrelated files from older exports remain. Artifact directories must not overlap source/build directories. A completed first flavor remains available if the second flavor fails; the overall command exits with failure.

Logs show elapsed time, stage labels, and real-time command output. Information is cyan, success green, warnings yellow, and errors red. Colors are disabled for redirected output, `NO_COLOR`, or `--no-color`. Failures return exit code 1.

## Verification

```console
dart format --output=none --set-exit-if-changed build.dart test/
dart analyze build.dart test/
dart run test/build_test.dart
dart run test/verify_kernel.dart
```

The fixture suite uses real Git, make, patch, and a C compiler in temporary directories; it simulates Kconfig with Dart and requires no network. It covers both-flavor isolation, per-flavor selection, configuration merging, artifact export, and failure propagation.

The optional real-build verifier checks both default flavor directories. It requires OpenSSL and GNU readelf, verifies all effective profile values, default confidentiality lockdown, exclusive LSM selection, file sizes and copied contents, kCFI/IBT ELF sections, and every exported module's PKCS#7 signature against its flavor's public certificate. It confirms that module payloads match the original compiled modules and that private keys were not exported. For custom directories:

```console
dart run test/verify_kernel.dart build/linux-eku-se out/linux-eku-se out/linux-eku-se/build-profile.conf
```

Builds use Linux tag `v7.4-rc3` at commit `aebb7274476403040d582c61478df8f4a7bf9cd3`, with Clang/LLD 22.1.8 on Fedora 44. Missing dependencies in this workspace were extracted from Fedora RPMs to `/tmp/ekuos-build-tools`. With those temporary tools, run:

```console
env PATH="/tmp/ekuos-build-tools/usr/bin:$PATH" LD_LIBRARY_PATH=/tmp/ekuos-build-tools/usr/lib64 BISON_PKGDATADIR=/tmp/ekuos-build-tools/usr/share/bison PKG_CONFIG_PATH=/tmp/ekuos-build-tools/usr/lib64/pkgconfig dart run build.dart --tag v7.4-rc3 --arch x86_64
```

Both real builds completed successfully on November 17, 2026, using 10 detected processors for each flavor, in about 435 seconds total:

| Kernel release | Verified overrides | Exported artifacts | Verified module signatures | Default lockdown |
| --- | ---: | ---: | ---: | --- |
| `7.4.0-rc3-eku-se` | 112 | 22 | 12 | confidentiality |
| `7.4.0-rc3-eku-aa` | 135 | 22 | 12 | confidentiality |

The fixture suite passed all 20 tests. Both ELF images contain kCFI/IBT sections, and OpenSSL verified every exported module signature against its corresponding kernel's public certificate. The local build log is `build/dual-build.log`.

The environment overrides are unnecessary when dependencies are installed in system paths. Compile-time and artifact verification do not test boot behavior or policy enforcement on a running system.

## License

This build tooling is licensed under the [MIT License](LICENSE). Linux sources and third-party patches retain their respective licenses.

# ekuOS kernel builder

Build a Linux kernel using Dart as a scripting language. The script clones the source, applies patches, merges text-based overrides into the default configuration, and compiles the kernel. It needs no pub packages or Bash/Python helper scripts. External commands are launched directly with argument lists.

## Requirements

- Dart SDK 3.0 or later
- Git, GNU make, GNU patch, a compiler, and the dependencies required to build your kernel
- Network access for cloning, or an existing Linux source tree
- A suitable toolchain for cross compilation, if needed

## Usage

```console
dart run build.dart
```

By default, the script shallow-clones the default branch HEAD of the official Torvalds Linux repository into `linux/`, reads `config.txt` and `patches/`, and writes configuration and build artifacts to `build/`. The default revision is the latest upstream development code at clone time. To build a release, specify its exact tag with `--tag`.

After a successful build, artifacts are copied to `out/` (override with `--artifacts PATH`). This includes the kernel image (for example, `out/bzImage`), `vmlinux`, `System.map`, the resolved `.config`, module metadata, and the modules listed in `modules.order`, preserving their paths under `out/modules/`. `build-profile.conf` records the input profile, and `build-info.json` records the source revision, toolchain, parallelism, and exported file sizes. Files with matching names are overwritten; unrelated files from earlier exports are left in place. The artifact directory must not overlap the source or build directory. Artifacts are exported only after configuration verification and compilation succeed.

When `CONFIG_MODULE_SIG_ALL` or `CONFIG_MODULE_SIG_FORCE` is enabled, exported module copies are signed using Kbuild's native `scripts/sign-file` executable and the configured file-based signing key. The generated public certificate is exported as `out/signing_key.x509`; the private key remains in the build directory. The modules under `out/modules/` are an artifact bundle, not a populated `/lib/modules/<release>` installation.

All relative paths are resolved against the current directory. Source and output paths must not contain spaces or shell metacharacters.

```console
dart run build.dart --tag v6.12 --source linux-v6.12 --output build-v6.12
dart run build.dart --source /path/to/linux --config config.txt --patches patches --output build --jobs 8
dart run build.dart --source /path/to/linux --arch arm64 --cross-compile aarch64-linux-gnu- --defconfig defconfig --target Image --target modules
dart run build.dart --help
```

The tag above illustrates the syntax; choose the release you want to build. `--tag` accepts a tag name, not a branch name. `--repo URL` selects another Git repository, such as a stable kernel mirror or a local repository.

A missing or empty source directory is cloned automatically using `git clone --depth 1 --single-branch`; with `--tag`, the clone also uses `--branch TAG`. Existing source trees are reused without fetching, pulling, resetting, or switching revisions. When `--tag` is supplied for an existing tree, its local tag must resolve to the current HEAD; otherwise the build stops. Use a new source directory to build a different tag or obtain a fresh upstream HEAD.

## ekuOS hardening profile

```console
dart run build.dart --config eku.conf --arch x86_64
```

`eku.conf` selects Clang/LLVM with `LLVM=1`, which the builder passes to every make invocation rather than adding it to `.config`. You can also select this toolchain with `--llvm`. Install Clang, LLD, and LLVM utilities, plus the usual kernel build dependencies such as flex, bison, bc, OpenSSL development headers, and libelf development headers.

The profile targets Linux 7.4 on x86_64 and enables enforced kCFI, x86 kernel IBT, CPU mitigations, KASLR and stack-offset randomization, strong stack protection, strict memory permissions, fortified copies, hardened slab allocation without default slab merging, zero initialization, list corruption checks, enforced module signatures, seccomp, Landlock, Yama, SafeSetID, SELinux, and integrity lockdown. On this kernel, kCFI uses `CONFIG_CFI` (the previous `CONFIG_CFI_CLANG` is transitional); it does not require LTO. `CONFIG_CFI_AUTO_DEFAULT=n` selects kCFI at boot rather than automatic FineIBT selection. Every override must survive Kconfig dependency resolution before compilation begins. Other kernel versions may require different symbol names.

Parallelism defaults to Dart's detected processor count. Omit `--jobs` to use all detected CPUs; supply it only to override that default.

These choices have runtime effects: zeroing memory on free adds overhead, lockdown restricts privileged kernel access, and disabling hibernation, kexec, `/dev/mem`, and legacy TIOCSTI removes those interfaces. SELinux requires an appropriate userspace policy for a complete system. This profile builds a kernel; it does not install it, configure a bootloader, or test boot/runtime behavior.

See the upstream documentation on [Clang/LLVM builds](https://docs.kernel.org/kbuild/llvm.html) and [kernel self-protection](https://docs.kernel.org/security/self-protection.html).

## Configuration file

Write one `HOGE=value` or `CONFIG_HOGE=value` entry per line in `config.txt`. Use Kconfig value syntax: quote strings and use `n` to disable an option.

```text
LOCALVERSION="-ekuos"
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_DEBUG_INFO=n
# CONFIG_UNUSED_SYMBOL is not set
```

Blank lines and comments beginning with `#` are ignored, except for `# CONFIG_... is not set`, which disables that option. For duplicate keys, the last value wins. Put comments on separate lines; inline comments are treated as part of the value.

Each run performs these steps:

1. Stream the overrides file one line at a time.
2. Clone the source if needed and verify the requested tag, if supplied.
3. Apply `.patch` and `.diff` files directly inside `patches/` in filename order. Use names such as `001-name.patch` and `-p1` paths with `a/` and `b/` prefixes.
4. Generate defaults with `make O=... defconfig`. Select a different initial target with `--defconfig`.
5. Merge overrides into the generated `.config`, then resolve dependencies with `make olddefconfig`.
6. Verify that the resolved settings match the requested values, then compile with `make -j...`.

If missing dependencies, unknown symbols, or other Kconfig rules prevent an override from taking effect, the script reports the requested and resolved values and stops. Each run regenerates the configuration from defaults, so manual edits to `build/.config` are discarded. Unset the `KCONFIG_CONFIG` environment variable before running the script.

Patches modify the source tree directly. Each patch is checked with a dry run before application. If a reverse dry run succeeds, the patch is considered already applied and skipped. Later patches that change the same lines can prevent this detection, so use a fresh source tree when changing the patch series. If a run fails, patches applied earlier in that run remain in place.

Logs include elapsed seconds and stage labels. In a terminal, information is cyan, success is green, warnings are yellow, and errors are red. Command output is streamed in real time, and failures produce exit code 1. Colors are disabled when output is redirected, when `NO_COLOR` is set, or when `--no-color` is supplied.

## Development checks

```console
dart format --output=none --set-exit-if-changed build.dart test/build_test.dart
dart analyze build.dart test/build_test.dart
dart run test/build_test.dart
```

Tests are written entirely in Dart. They create a small Makefile and C source in a temporary directory and exercise the build pipeline with real Git, make, patch, and a C compiler. Clone tests use a local Git repository with two tagged revisions and require no network access. Kconfig dependency resolution is simulated by a Dart fixture. These tests do not compile a complete Linux kernel.

## License

This build tooling is licensed under the [MIT License](LICENSE). Linux kernel sources and third-party patches retain their respective licenses.

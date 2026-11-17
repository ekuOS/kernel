# ekuOS kernel builder

Build a Linux kernel using Dart as a scripting language. The script applies patches, merges text-based overrides into the default configuration, and compiles the kernel. It needs no pub packages or Bash/Python helper scripts. External commands are launched directly with argument lists.

## Requirements

- Dart SDK 3.0 or later
- GNU make, GNU patch, a compiler, and the dependencies required to build your kernel
- An unpacked Linux source tree, plus a suitable toolchain for cross compilation

## Usage

```console
dart run build.dart --source /path/to/linux
```

By default, the script reads `config.txt` and `patches/` from the current directory and writes configuration and build artifacts to `build/`. All relative paths are resolved against the current directory. Source and output paths must not contain spaces or shell metacharacters.

```console
dart run build.dart --source /path/to/linux --config config.txt --patches patches --output build --jobs 8
dart run build.dart --source /path/to/linux --arch arm64 --cross-compile aarch64-linux-gnu- --defconfig defconfig --target Image --target modules
dart run build.dart --help
```

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
2. Apply `.patch` and `.diff` files directly inside `patches/` in filename order. Use names such as `001-name.patch` and `-p1` paths with `a/` and `b/` prefixes.
3. Generate defaults with `make O=... defconfig`. Select a different initial target with `--defconfig`.
4. Merge overrides into the generated `.config`, then resolve dependencies with `make olddefconfig`.
5. Verify that the resolved settings match the requested values, then compile with `make -j...`.

If missing dependencies, unknown symbols, or other Kconfig rules prevent an override from taking effect, the script reports the requested and resolved values and stops. Each run regenerates the configuration from defaults, so manual edits to `build/.config` are discarded. Unset the `KCONFIG_CONFIG` environment variable before running the script.

Patches modify the source tree directly. Each patch is checked with a dry run before application. If a reverse dry run succeeds, the patch is considered already applied and skipped. Later patches that change the same lines can prevent this detection, so use a fresh source tree when changing the patch series. If a run fails, patches applied earlier in that run remain in place.

Logs include elapsed seconds and stage labels. In a terminal, information is cyan, success is green, warnings are yellow, and errors are red. Command output is streamed in real time, and failures produce exit code 1. Colors are disabled when output is redirected, when `NO_COLOR` is set, or when `--no-color` is supplied.

## Development checks

```console
dart format --output=none --set-exit-if-changed build.dart test/build_test.dart
dart analyze build.dart test/build_test.dart
dart run test/build_test.dart
```

Tests are written entirely in Dart. They create a small Makefile and C source in a temporary directory and exercise the build pipeline with real make, patch, and a C compiler. Kconfig dependency resolution is simulated by a Dart fixture. These tests do not compile a complete Linux kernel.

## License

This build tooling is licensed under the [MIT License](LICENSE). Linux kernel sources and third-party patches retain their respective licenses.

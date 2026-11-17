#!/usr/bin/env dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const usage = '''Linux kernel builder (Dart SDK 3+)

Usage: dart run build.dart [options]

  --source PATH        Source directory (default: linux; cloned if absent/empty)
  --tag TAG            Clone an exact tag; default: upstream default branch HEAD
  --repo URL           Git repository (default: official torvalds/linux)
  --config PATH        Overrides file (default: config.txt)
  --patches PATH       Patch directory (default: patches)
  --output PATH        Out-of-tree build directory (default: build)
  --artifacts PATH     Copy successful build artifacts here (default: out)
  --llvm               Use Clang/LLVM (also selectable with LLVM=1 in profile)
  --defconfig NAME     Initial make target (default: defconfig)
  --jobs NUMBER        Parallel jobs (default: available CPU count)
  --arch NAME          Kernel ARCH, e.g. arm64
  --cross-compile TEXT CROSS_COMPILE prefix, e.g. aarch64-linux-gnu-
  --target NAME        Build target; repeatable (default: kernel make default)
  --no-color          Disable ANSI colors (also honors NO_COLOR)
  --help              Show this help

Relative paths are resolved against the current directory.
Each run regenerates .config from the selected defconfig.
Existing source trees are reused without pulling or switching revisions.
''';

class BuildFailure implements Exception {
  BuildFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class Options {
  String source = 'linux';
  String repo =
      'https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git';
  String? tag;
  String config = 'config.txt';
  String patches = 'patches';
  String output = 'build';
  String artifacts = 'out';
  bool llvm = false;
  String defconfig = 'defconfig';
  int jobs = Platform.numberOfProcessors;
  String? arch;
  String? crossCompile;
  final List<String> targets = [];
  bool noColor = false;
  bool help = false;

  static Options parse(List<String> args) {
    final result = Options();
    for (var i = 0; i < args.length; i++) {
      final option = args[i];
      if (option == '--help') {
        result.help = true;
        continue;
      }
      if (option == '--no-color') {
        result.noColor = true;
        continue;
      }
      if (option == '--llvm') {
        result.llvm = true;
        continue;
      }
      if (!const {
        '--source',
        '--tag',
        '--repo',
        '--config',
        '--patches',
        '--output',
        '--artifacts',
        '--defconfig',
        '--jobs',
        '--arch',
        '--cross-compile',
        '--target',
      }.contains(option)) {
        throw BuildFailure('Unknown option: $option');
      }
      if (++i >= args.length || args[i].startsWith('--') || args[i].isEmpty) {
        throw BuildFailure('Missing value for $option');
      }
      final value = args[i];
      switch (option) {
        case '--source':
          result.source = value;
        case '--tag':
          result.tag = value;
        case '--repo':
          result.repo = value;
        case '--config':
          result.config = value;
        case '--patches':
          result.patches = value;
        case '--output':
          result.output = value;
        case '--artifacts':
          result.artifacts = value;
        case '--defconfig':
          result.defconfig = value;
        case '--jobs':
          result.jobs = int.tryParse(value) ?? 0;
          if (result.jobs < 1) throw BuildFailure('--jobs must be positive');
        case '--arch':
          result.arch = value;
        case '--cross-compile':
          result.crossCompile = value;
        case '--target':
          result.targets.add(value);
      }
    }
    for (final target in [result.defconfig, ...result.targets]) {
      if (!RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_./+-]*$').hasMatch(target)) {
        throw BuildFailure('Invalid make target: $target');
      }
    }
    return result;
  }
}

class Log {
  Log({bool noColor = false})
    : color =
          !noColor &&
          stdout.hasTerminal &&
          !Platform.environment.containsKey('NO_COLOR');
  final bool color;
  final Stopwatch watch = Stopwatch()..start();

  void write(String label, String message, int code, {bool error = false}) {
    final time = watch.elapsed.inSeconds.toString().padLeft(4);
    final prefix = '[$time s] [$label]';
    (error ? stderr : stdout).writeln(
      '${color ? '\x1b[${code}m' : ''}$prefix'
      '${color ? '\x1b[0m' : ''} $message',
    );
  }

  void info(String message) => write('INFO', message, 36);
  void ok(String message) => write('OK', message, 32);
  void warn(String message) => write('WARN', message, 33);
  void fail(String message) => write('ERROR', message, 31, error: true);
}

final assignment = RegExp(r'^(?:CONFIG_)?([A-Za-z0-9_]+)=(.*)$');
final disabled = RegExp(r'^# CONFIG_([A-Za-z0-9_]+) is not set$');

/// Values are passed through verbatim; quote Kconfig string values in the file.
Future<Map<String, String>> readOverrides(
  File file, {
  Map<String, String>? buildVariables,
}) async {
  final values = <String, String>{};
  var number = 0;
  await for (final raw
      in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    number++;
    final line = raw.trim();
    final unset = disabled.firstMatch(line);
    if (unset != null) {
      values['CONFIG_${unset[1]}'] = 'n';
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = assignment.firstMatch(line);
    if (match == null || match[2]!.trim().isEmpty) {
      throw BuildFailure('${file.path}:$number: expected KEY=value');
    }
    final value = match[2]!.trim();
    if (buildVariables != null && line.startsWith('LLVM=')) {
      if (value != '1') {
        throw BuildFailure('${file.path}:$number: LLVM must be 1');
      }
      buildVariables['LLVM'] = value;
    } else {
      values['CONFIG_${match[1]}'] = value;
    }
  }
  return values;
}

String? symbolOf(String line) {
  final set = assignment.firstMatch(line);
  if (set != null) return 'CONFIG_${set[1]}';
  final unset = disabled.firstMatch(line);
  return unset == null ? null : 'CONFIG_${unset[1]}';
}

Future<void> mergeConfig(File file, Map<String, String> overrides) async {
  final pending = Map<String, String>.of(overrides);
  final lines = <String>[];
  final written = <String>{};
  String entry(String key, String value) =>
      value == 'n' ? '# $key is not set' : '$key=$value';
  for (final line in await file.readAsLines()) {
    final key = symbolOf(line);
    if (key != null && overrides.containsKey(key)) {
      if (written.add(key)) lines.add(entry(key, pending.remove(key)!));
    } else {
      lines.add(line);
    }
  }
  for (final item in pending.entries) {
    lines.add(entry(item.key, item.value));
  }
  await file.writeAsString('${lines.join('\n')}\n');
}

class Runner {
  Runner(this.log);
  final Log log;

  Future<void> run(String command, List<String> args, {String? cwd}) async {
    log.info(([command, ...args]).map(jsonEncode).join(' '));
    final process = await Process.start(command, args, workingDirectory: cwd);
    final signals = <StreamSubscription<ProcessSignal>>[
      ProcessSignal.sigint.watch().listen(
        (_) => process.kill(ProcessSignal.sigint),
      ),
      ProcessSignal.sigterm.watch().listen(
        (_) => process.kill(ProcessSignal.sigterm),
      ),
    ];
    Future<void> pipe(Stream<List<int>> stream, bool error) async {
      await for (final line
          in stream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        log.write(command, line, error ? 33 : 90, error: error);
      }
    }

    try {
      final streams = Future.wait([
        pipe(process.stdout, false),
        pipe(process.stderr, true),
      ]);
      final code = await process.exitCode;
      await streams;
      if (code != 0) throw BuildFailure('$command failed (exit $code)');
    } finally {
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  }
}

Future<void> applyPatches(
  Directory directory,
  String source,
  Runner runner,
) async {
  final patches = await directory
      .list()
      .where(
        (entry) =>
            entry is File &&
            (entry.path.endsWith('.patch') || entry.path.endsWith('.diff')),
      )
      .toList();
  patches.sort((a, b) => a.path.compareTo(b.path));
  if (patches.isEmpty)
    runner.log.warn('No .patch or .diff files in ${directory.path}');
  for (final patch in patches) {
    final args = [
      '--batch',
      '--fuzz=0',
      '-p1',
      '--reject-file=-',
      '-i',
      patch.absolute.path,
    ];
    final check = await Process.run('patch', [
      ...args,
      '--forward',
      '--dry-run',
    ], workingDirectory: source);
    if (check.exitCode != 0) {
      final reverse = await Process.run('patch', [
        ...args,
        '--reverse',
        '--force',
        '--dry-run',
      ], workingDirectory: source);
      if (reverse.exitCode == 0) {
        runner.log.warn('Already applied: ${patch.path}');
        continue;
      }
      throw BuildFailure(
        'Patch check failed: ${patch.path}\n'
        '${check.stdout}${check.stderr}',
      );
    }
    await runner.run('patch', [...args, '--forward'], cwd: source);
    runner.log.ok('Applied: ${patch.path}');
  }
}

Future<void> prepareSource(Options options, Runner runner) async {
  final source = Directory(options.source).absolute;
  final tag = options.tag;
  if (tag != null) {
    final valid = await Process.run('git', [
      'check-ref-format',
      'refs/tags/$tag',
    ]);
    if (tag.startsWith('-') || valid.exitCode != 0) {
      throw BuildFailure('Invalid Git tag: $tag');
    }
  }
  final exists = await source.exists();
  if (!exists || await source.list().isEmpty) {
    runner.log.info('Cloning ${tag == null ? "upstream HEAD" : "tag $tag"}');
    await runner.run('git', [
      'clone',
      '--depth',
      '1',
      '--single-branch',
      if (tag != null) ...['--branch', tag],
      '--',
      options.repo,
      source.path,
    ]);
  } else {
    runner.log.info('Reusing source tree: ${source.path}');
  }
  if (!await File('${source.path}/Makefile').exists()) {
    throw BuildFailure('Source Makefile not found: ${source.path}');
  }
  if (tag != null) {
    final top = await Process.run('git', [
      '-C',
      source.path,
      'rev-parse',
      '--show-toplevel',
    ]);
    if (top.exitCode != 0 ||
        top.stdout.toString().trim() != await source.resolveSymbolicLinks()) {
      throw BuildFailure('--tag requires a Git repository at ${source.path}');
    }
    final revision = await Process.run('git', [
      '-C',
      source.path,
      'rev-parse',
      '--verify',
      'refs/tags/$tag^{commit}',
    ]);
    final head = await Process.run('git', [
      '-C',
      source.path,
      'rev-parse',
      '--verify',
      'HEAD',
    ]);
    if (revision.exitCode != 0 ||
        head.exitCode != 0 ||
        revision.stdout.toString().trim() != head.stdout.toString().trim()) {
      throw BuildFailure(
        'Source HEAD does not match tag $tag. '
        'Use a new --source directory to clone the requested tag.',
      );
    }
    runner.log.ok('Verified tag $tag at ${head.stdout.toString().trim()}');
  }
}

Future<void> build(Options options, Log log) async {
  final source = Directory(options.source);
  final patches = Directory(options.patches).absolute;
  final buildVariables = <String, String>{};
  final overrides = await readOverrides(
    File(options.config),
    buildVariables: buildVariables,
  );
  if (options.llvm) buildVariables['LLVM'] = '1';
  if (!await patches.exists()) {
    throw BuildFailure('Patch directory not found: ${patches.path}');
  }
  final runner = Runner(log);
  await prepareSource(options, runner);
  final sourcePath = await source.resolveSymbolicLinks();
  final output = Directory(options.output).absolute;
  await output.create(recursive: true);
  final outputPath = await output.resolveSymbolicLinks();
  if (sourcePath == outputPath) {
    throw BuildFailure('--output must differ from --source');
  }
  final artifacts = Directory(options.artifacts).absolute;
  await artifacts.create(recursive: true);
  final artifactsPath = await artifacts.resolveSymbolicLinks();
  for (final path in [sourcePath, outputPath]) {
    if (artifactsPath == path ||
        artifactsPath.startsWith('$path/') ||
        path.startsWith('$artifactsPath/')) {
      throw BuildFailure(
        '--artifacts must not overlap the source or build directory',
      );
    }
  }
  // Kbuild embeds O= in shell commands: spaces and shell metacharacters are unsafe.
  for (final path in [sourcePath, outputPath]) {
    if (!RegExp(r'^[/a-zA-Z0-9_.+\-]+$').hasMatch(path)) {
      throw BuildFailure(
        'Kernel source/output paths need shell-safe characters: $path',
      );
    }
  }
  if (Platform.environment.containsKey('KCONFIG_CONFIG')) {
    throw BuildFailure(
      'Unset KCONFIG_CONFIG so this script can manage output/.config',
    );
  }
  await applyPatches(patches, sourcePath, runner);
  final makeArgs = [
    '-C',
    sourcePath,
    'O=$outputPath',
    for (final item in buildVariables.entries) '${item.key}=${item.value}',
    if (options.arch != null) 'ARCH=${options.arch}',
    if (options.crossCompile != null) 'CROSS_COMPILE=${options.crossCompile}',
  ];
  log.info('Generating defaults: ${options.defconfig}');
  await runner.run('make', [...makeArgs, options.defconfig]);
  final config = File('$outputPath/.config');
  await mergeConfig(config, overrides);
  log.info(
    'Merged ${overrides.length} overrides; resolving Kconfig dependencies',
  );
  await runner.run('make', [...makeArgs, 'olddefconfig']);
  final actual = await readOverrides(config);
  var mismatches = 0;
  for (final item in overrides.entries) {
    if (actual[item.key] != item.value) {
      mismatches++;
      log.fail(
        '${item.key}: requested ${item.value}, resolved '
        '${actual[item.key] ?? "<missing>"}',
      );
    }
  }
  if (mismatches > 0) {
    throw BuildFailure(
      '$mismatches overrides did not survive olddefconfig; '
      'check symbol names, value syntax and Kconfig dependencies',
    );
  }
  log.ok('Configuration verified');
  await runner.run('make', [
    ...makeArgs,
    '-j${options.jobs}',
    ...options.targets,
  ]);
  log.ok('Build complete: $outputPath');
  await copyArtifacts(outputPath, artifactsPath, options, buildVariables, log);
}

Future<void> copyArtifacts(
  String output,
  String destination,
  Options options,
  Map<String, String> buildVariables,
  Log log,
) async {
  final files = <String, String>{};
  for (final name in [
    'vmlinux',
    'vmlinuz',
    'System.map',
    '.config',
    'Module.symvers',
    'modules.order',
    'modules.builtin',
    'modules.builtin.modinfo',
    'modules.builtin.ranges',
    'include/config/kernel.release',
    'certs/signing_key.x509',
  ]) {
    if (await File('$output/$name').exists()) {
      files[name] =
          const {
            'include/config/kernel.release': 'kernel.release',
            'certs/signing_key.x509': 'signing_key.x509',
          }[name] ??
          name;
    }
  }
  for (final image in [
    'arch/x86/boot/bzImage',
    'arch/arm64/boot/Image',
    'arch/arm64/boot/Image.gz',
    'arch/arm/boot/zImage',
    'arch/arm/boot/uImage',
    'arch/riscv/boot/Image',
    'arch/riscv/boot/Image.gz',
    'arch/s390/boot/bzImage',
    'arch/loongarch/boot/vmlinuz.efi',
    'arch/powerpc/boot/zImage',
  ]) {
    if (await File('$output/$image').exists())
      files[image] = image.split('/').last;
  }
  final order = File('$output/modules.order');
  if (await order.exists()) {
    for (final line in await order.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final module = line.trim().replaceFirst(RegExp(r'\.o$'), '.ko');
      if (module.startsWith('/') ||
          module.split('/').contains('..') ||
          !module.endsWith('.ko')) {
        throw BuildFailure('Invalid module path in modules.order: $line');
      }
      if (!await File('$output/$module').exists()) {
        throw BuildFailure('Built module is missing: $module');
      }
      files[module] = 'modules/$module';
    }
  }
  if (!files.containsKey('vmlinux') &&
      !files.keys.any(
        (path) => path.startsWith('arch/') || path.endsWith('.ko'),
      )) {
    throw BuildFailure('No kernel image or modules found to export in $output');
  }
  final resolvedConfig = await readOverrides(File('$output/.config'));
  final signModules =
      resolvedConfig['CONFIG_MODULE_SIG_ALL'] == 'y' ||
      resolvedConfig['CONFIG_MODULE_SIG_FORCE'] == 'y';
  var signedModules = 0;
  final manifest = <Map<String, Object>>[];
  for (final item in files.entries) {
    final target = File('$destination/${item.value}');
    await target.parent.create(recursive: true);
    await File('$output/${item.key}').copy(target.path);
    if (item.key.endsWith('.ko') && signModules) {
      // Kbuild signs at modules_install time. Sign our exported copies using
      // its native executable, without exporting the private signing key.
      final key = jsonDecode(
        resolvedConfig['CONFIG_MODULE_SIG_KEY'] ?? '"certs/signing_key.pem"',
      ) as String;
      final hash = jsonDecode(
        resolvedConfig['CONFIG_MODULE_SIG_HASH'] ?? '"sha256"',
      ) as String;
      final outputKey = key.startsWith('/') ? key : '$output/$key';
      final keyPath = await File(outputKey).exists()
          ? outputKey
          : '${options.source}/$key';
      final signed = await Process.run('$output/scripts/sign-file', [
        hash,
        keyPath,
        '$output/certs/signing_key.x509',
        target.path,
      ]);
      if (signed.exitCode != 0) {
        throw BuildFailure(
          'Module signing failed: ${item.value}\n${signed.stdout}${signed.stderr}',
        );
      }
      signedModules++;
    }
    manifest.add({'path': item.value, 'bytes': await target.length()});
  }
  await File(options.config).copy('$destination/build-profile.conf');
  final revision = await Process.run('git', [
    '-C',
    options.source,
    'rev-parse',
    '--verify',
    'HEAD',
  ]);
  final compiler = resolvedConfig['CONFIG_CC_VERSION_TEXT'];
  final metadata = {
    'builtAt': DateTime.now().toUtc().toIso8601String(),
    'source': Directory(options.source).absolute.path,
    'revision': revision.exitCode == 0
        ? revision.stdout.toString().trim()
        : null,
    'tag': options.tag,
    'makeVariables': buildVariables,
    'arch': options.arch,
    'targets': options.targets,
    'jobs': options.jobs,
    'defconfig': options.defconfig,
    'compiler': compiler == null ? null : jsonDecode(compiler),
    'signedModules': signedModules,
    'files': manifest,
  };
  await File(
    '$destination/build-info.json',
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(metadata)}\n');
  log.ok('Exported ${files.length} artifacts to $destination');
  if (signedModules > 0)
    log.ok(
      'Signed $signedModules exported modules; private key stays in build directory',
    );
}

Future<void> main(List<String> args) async {
  final log = Log(noColor: args.contains('--no-color'));
  try {
    final options = Options.parse(args);
    if (options.help) {
      stdout.write(usage);
      return;
    }
    await build(options, log);
  } on Object catch (error) {
    log.fail(error.toString());
    exitCode = 1;
  }
}

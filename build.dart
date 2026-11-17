#!/usr/bin/env dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const usage = '''Linux kernel builder (Dart SDK 3+)

Usage: dart run build.dart --source PATH [options]

  --source PATH        Linux source tree (required; patches modify this tree)
  --config PATH        Overrides file (default: config.txt)
  --patches PATH       Patch directory (default: patches)
  --output PATH        Out-of-tree build directory (default: build)
  --defconfig NAME     Initial make target (default: defconfig)
  --jobs NUMBER        Parallel jobs (default: available CPU count)
  --arch NAME          Kernel ARCH, e.g. arm64
  --cross-compile TEXT CROSS_COMPILE prefix, e.g. aarch64-linux-gnu-
  --target NAME        Build target; repeatable (default: kernel make default)
  --no-color          Disable ANSI colors (also honors NO_COLOR)
  --help              Show this help

Relative paths are resolved against the current directory.
Each run regenerates .config from the selected defconfig.
''';

class BuildFailure implements Exception {
  BuildFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class Options {
  String? source;
  String config = 'config.txt';
  String patches = 'patches';
  String output = 'build';
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
      if (!const {
        '--source',
        '--config',
        '--patches',
        '--output',
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
        case '--config':
          result.config = value;
        case '--patches':
          result.patches = value;
        case '--output':
          result.output = value;
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
    if (!result.help && result.source == null) {
      throw BuildFailure('--source is required');
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
Future<Map<String, String>> readOverrides(File file) async {
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
    values['CONFIG_${match[1]}'] = match[2]!.trim();
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

Future<void> build(Options options, Log log) async {
  final source = Directory(options.source!);
  final patches = Directory(options.patches).absolute;
  final overrides = await readOverrides(File(options.config));
  if (!await File('${source.path}/Makefile').exists()) {
    throw BuildFailure('Source Makefile not found: ${source.path}');
  }
  if (!await patches.exists()) {
    throw BuildFailure('Patch directory not found: ${patches.path}');
  }
  final sourcePath = await source.resolveSymbolicLinks();
  final output = Directory(options.output).absolute;
  await output.create(recursive: true);
  final outputPath = await output.resolveSymbolicLinks();
  if (sourcePath == outputPath) {
    throw BuildFailure('--output must differ from --source');
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
  final runner = Runner(log);
  await applyPatches(patches, sourcePath, runner);
  final makeArgs = [
    '-C',
    sourcePath,
    'O=$outputPath',
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

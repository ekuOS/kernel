import 'dart:io';

import '../build.dart' as builder;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> rejects(Future<void> Function() action, String message) async {
  try {
    await action();
  } on builder.BuildFailure {
    return;
  }
  throw StateError(message);
}

Future<void> main(List<String> args) async {
  // This Dart helper stands in for Kconfig's dependency resolution in the fixture.
  if (args.firstOrNull == '--normalize') {
    final config = File('${args[1]}/.config');
    await config.writeAsString(
      (await config.readAsString()).replaceAll(
        'CONFIG_UNAVAILABLE=y',
        '# CONFIG_UNAVAILABLE is not set',
      ),
    );
    return;
  }

  final root = await Directory.systemTemp.createTemp('ekuos-build-test-');
  final script = File.fromUri(Platform.script.resolve('../build.dart')).path;
  final helper = Platform.script.toFilePath();
  var count = 0;
  Future<void> test(String name, Future<void> Function() body) async {
    await body();
    count++;
    stdout.writeln('PASS $name');
  }

  try {
    final overrides = File('${root.path}/overrides.txt');
    await test(
      'streamed CRLF input, comments, strings, duplicates and disabled symbols',
      () async {
        await overrides.writeAsString(
          '# comment\r\n\r\nFOO=m\r\nCONFIG_FOO=y\r\n'
          'NAME="hello = world"\r\nOFF=n\r\n# CONFIG_OTHER is not set\r\n',
        );
        final values = await builder.readOverrides(overrides);
        check(
          values.length == 4 &&
              values['CONFIG_FOO'] == 'y' &&
              values['CONFIG_NAME'] == '"hello = world"' &&
              values['CONFIG_OFF'] == 'n' &&
              values['CONFIG_OTHER'] == 'n',
          'Incorrect parsing: $values',
        );
        final config = File('${root.path}/.config');
        await config.writeAsString(
          '# heading\nCONFIG_FOO=n\nCONFIG_FOO=m\nCONFIG_KEEP=42\n',
        );
        await builder.mergeConfig(config, values);
        final merged = await config.readAsString();
        check(
          merged.contains('CONFIG_KEEP=42') &&
              merged.contains('# CONFIG_OFF is not set') &&
              'CONFIG_FOO='.allMatches(merged).length == 1,
          'Merge lost defaults or duplicated an override',
        );
      },
    );
    await test('invalid input reports the line and fails', () async {
      await overrides.writeAsString('# header\nINVALID\n');
      try {
        await builder.readOverrides(overrides);
        throw StateError('Invalid input accepted');
      } on builder.BuildFailure catch (error) {
        check(error.message.contains(':2:'), 'Missing line number');
      }
    });
    await test(
      'CLI rejects missing values, bad jobs and make variable injection',
      () async {
        for (final args in [
          <String>[],
          ['--source'],
          ['--source', 'x', '--jobs', '0'],
          ['--source', 'x', '--target', 'CC=anything'],
          ['--unknown'],
        ]) {
          await rejects(() async {
            builder.Options.parse(args);
          }, 'Accepted $args');
        }
        check(builder.Options.parse(['--help']).help, 'Help requires a source');
      },
    );

    final source = await Directory('${root.path}/linux').create();
    final patches = await Directory('${root.path}/patches').create();
    final output = '${root.path}/out';
    await File('${source.path}/hello.c')
        .writeAsString('int main(void) { return 0; }\n');
    await File('${source.path}/version.txt').writeAsString('before\n');
    await File('${source.path}/defaults')
        .writeAsString('CONFIG_FOO=n\nCONFIG_KEEP=42\nCONFIG_NAME="default"\n');
    await File('${source.path}/Makefile').writeAsString('''
.PHONY: all defconfig olddefconfig fail
all:
\t\$(CC) hello.c -o \$(O)/kernel-demo
defconfig:
\tcp defaults \$(O)/.config
olddefconfig:
\t${Platform.resolvedExecutable} $helper --normalize \$(O)
fail:
\t${Platform.resolvedExecutable} missing-file.dart
''');
    await File('${patches.path}/002-version.diff').writeAsString('''
--- a/version.txt
+++ b/version.txt
@@ -1 +1 @@
-before
+after
''');
    await File('${patches.path}/001-main.patch').writeAsString('''
--- a/hello.c
+++ b/hello.c
@@ -1 +1 @@
-int main(void) { return 0; }
+int main(void) { return 7; }
''');
    await overrides.writeAsString('FOO=y\nNAME="custom"\n');
    Future<ProcessResult> run([List<String> extra = const []]) => Process.run(
      Platform.resolvedExecutable,
      [
        script,
        '--source',
        source.path,
        '--output',
        output,
        '--config',
        overrides.path,
        '--patches',
        patches.path,
        '--jobs',
        '2',
        '--no-color',
        ...extra,
      ],
      environment: {'NO_COLOR': '1'},
    );

    await test(
      'patch order, default merge, streamed logs and actual C compilation',
      () async {
        final result = await run();
        check(result.exitCode == 0, '${result.stdout}\n${result.stderr}');
        final log = result.stdout as String;
        check(
          log.indexOf('Applied: ${patches.path}/001-main.patch') <
              log.indexOf('Applied: ${patches.path}/002-version.diff'),
          'Wrong patch order',
        );
        check(
          log.contains('[OK]') && !log.contains('\x1b['),
          'Incorrect logging',
        );
        final values = await builder.readOverrides(File('$output/.config'));
        check(
          values['CONFIG_FOO'] == 'y' &&
              values['CONFIG_KEEP'] == '42' &&
              values['CONFIG_NAME'] == '"custom"',
          'Incorrect final config',
        );
        check(
          (await Process.run('$output/kernel-demo', [])).exitCode == 7,
          'Compiled code did not contain patch',
        );
      },
    );
    await test('already applied patches are skipped on a second run', () async {
      final result = await run();
      check(
        result.exitCode == 0 &&
            result.stdout.toString().contains('Already applied:'),
        '${result.stdout}\n${result.stderr}',
      );
    });
    await test('Kconfig mismatch stops before compilation', () async {
      await File('$output/kernel-demo').delete();
      await overrides.writeAsString('UNAVAILABLE=y\n');
      final result = await run();
      check(
        result.exitCode != 0 &&
            result.stderr.toString().contains('CONFIG_UNAVAILABLE') &&
            !await File('$output/kernel-demo').exists(),
        'Compiled despite mismatch',
      );
      await overrides.writeAsString('FOO=y\n');
    });
    await test('make failure propagates as a nonzero exit', () async {
      final result = await run(['--target', 'fail']);
      check(
        result.exitCode != 0 &&
            result.stderr.toString().contains('make failed'),
        'Make failure was ignored',
      );
    });
    await test('bad patch stops before configuration or compilation', () async {
      await File('${patches.path}/003-broken.patch').writeAsString('''
--- a/version.txt
+++ b/version.txt
@@ -1 +1 @@
-nonexistent
+broken
''');
      await File('$output/.config').delete();
      final result = await run();
      check(
        result.exitCode != 0 &&
            result.stderr.toString().contains('Patch check failed') &&
            !await File('$output/.config').exists(),
        'Continued after a bad patch',
      );
    });
    stdout.writeln('$count tests passed');
  } finally {
    await root.delete(recursive: true);
  }
}

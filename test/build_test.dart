import 'dart:convert';
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
    await test('stable release selection sorts numeric versions and excludes prereleases', () async {
      final tag = builder.latestStableTag('''
aaaa refs/tags/v7.9.99
bbbb refs/tags/v7.10
cccc refs/tags/v7.10.2
dddd refs/tags/v7.10.10
eeee refs/tags/v8.0-rc1
ffff refs/tags/v7.11-rc9
1111 refs/tags/v7.10.11-test
2222 refs/tags/v7.10.11^{}
3333 refs/heads/v99.0
''');
      check(tag == 'v7.10.10', 'Selected an older or prerelease tag: $tag');
      check(
        builder.latestStableTag('aaaa refs/tags/v8.0\n') == 'v8.0',
        'Formal major release was rejected',
      );
      await rejects(() async {
        builder.latestStableTag('aaaa refs/tags/v9.0-rc1\n');
      }, 'Prerelease-only repository was accepted');
    });
    await test(
      'profile selects LLVM without adding a Kconfig symbol',
      () async {
        await overrides.writeAsString('LLVM=1\nFOO=y\n');
        final variables = <String, String>{};
        final values = await builder.readOverrides(
          overrides,
          buildVariables: variables,
        );
        check(
          variables['LLVM'] == '1' &&
              values.length == 1 &&
              values['CONFIG_FOO'] == 'y',
          'LLVM was treated as a Kconfig symbol',
        );
        await overrides.writeAsString('LLVM=invalid\n');
        await rejects(() async {
          await builder.readOverrides(overrides, buildVariables: {});
        }, 'Invalid LLVM setting accepted');
      },
    );
    await test(
      'CLI rejects missing values, bad jobs and make variable injection',
      () async {
        for (final args in [
          ['--source'],
          ['--source', 'x', '--jobs', '0'],
          ['--source', 'x', '--target', 'CC=anything'],
          ['--unknown'],
          ['--flavor', 'invalid'],
        ]) {
          await rejects(() async {
            builder.Options.parse(args);
          }, 'Accepted $args');
        }
        check(builder.Options.parse(['--help']).help, 'Help requires a source');
        check(
          builder.Options.parse([]).source == 'linux',
          'Wrong default source',
        );
        check(
          builder.Options.parse([]).jobs == Platform.numberOfProcessors,
          'Default parallelism does not match the processor count',
        );
        check(
          builder.Options.parse([]).flavor == 'both' &&
              builder.Options.parse([]).config == 'eku.conf',
          'Wrong flavor/profile defaults',
        );
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
\tcp \$(O)/kernel-demo \$(O)/vmlinux
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
        '--flavor',
        'custom',
        '--source',
        source.path,
        '--output',
        output,
        '--artifacts',
        '${root.path}/export',
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
    await test(
      'exports images, resolved config, profile and build manifest',
      () async {
        final result = await run(['--llvm']);
        check(result.exitCode == 0, '${result.stdout}\n${result.stderr}');
        final destination = '${root.path}/export';
        check(
          (await Process.run('$destination/vmlinux', [])).exitCode == 7,
          'Exported image differs from compiled image',
        );
        check(
          await File('$destination/.config').readAsString() ==
              await File('$output/.config').readAsString(),
          'Wrong exported configuration',
        );
        check(
          await File('$destination/build-profile.conf').readAsString() ==
              await overrides.readAsString(),
          'Wrong exported profile',
        );
        final manifest = jsonDecode(
          await File('$destination/build-info.json').readAsString(),
        ) as Map<String, dynamic>;
        check(
          manifest['makeVariables']['LLVM'] == '1',
          'Toolchain is missing from manifest',
        );
        check(
          manifest['jobs'] == 2 && manifest['signedModules'] == 0,
          'Incorrect parallelism or signing metadata',
        );
        check(
          'LLVM=1'.allMatches(result.stdout.toString()).length == 3,
          'LLVM was not passed to every make invocation',
        );
      },
    );
    await test(
      'artifact directory must not overlap source or build tree',
      () async {
        for (final path in [source.path, output, '${source.path}/nested']) {
          final result = await run(['--artifacts', path]);
          check(
            result.exitCode != 0 &&
                result.stderr.toString().contains('must not overlap'),
            'Unsafe artifact directory accepted: $path',
          );
        }
      },
    );
    await test(
      'module export follows modules.order and ignores stale modules',
      () async {
        final moduleBuild = await Directory('${root.path}/module-build')
            .create();
        await File('${moduleBuild.path}/.config')
            .writeAsString('CONFIG_MODULES=y\n');
        final module = File('${moduleBuild.path}/kernel/example.ko');
        await module.parent.create(recursive: true);
        await module.writeAsString('built module');
        await File('${moduleBuild.path}/kernel/stale.ko')
            .writeAsString('stale');
        await File('${moduleBuild.path}/modules.order')
            .writeAsString('kernel/example.o\n');
        final certs = await Directory('${moduleBuild.path}/certs').create();
        await File('${certs.path}/signing_key.pem')
            .writeAsString('private key');
        await File('${certs.path}/signing_key.x509')
            .writeAsString('public certificate');
        final destination = '${root.path}/module-export';
        await builder.copyArtifacts(
          moduleBuild.path,
          destination,
          builder.Options()..config = overrides.path,
          {},
          builder.Log(noColor: true),
        );
        check(
          await File('$destination/modules/kernel/example.ko').readAsString() ==
                  'built module' &&
              !await File('$destination/modules/kernel/stale.ko').exists(),
          'Incorrect module export',
        );
        check(
          await File('$destination/signing_key.x509').readAsString() ==
                  'public certificate' &&
              !await File('$destination/signing_key.pem').exists() &&
              !await File('$destination/certs/signing_key.pem').exists(),
          'Signing key export must include only the public certificate',
        );
      },
    );
    await test(
      'both flavors use independent releases, configs, outputs and metadata',
      () async {
        final base = '${root.path}/dual-build';
        final destination = '${root.path}/dual-export';
        final result = await run([
          '--flavor',
          'both',
          '--output',
          base,
          '--artifacts',
          destination,
        ]);
        check(result.exitCode == 0, '${result.stdout}\n${result.stderr}');
        for (final flavor in ['se', 'aa']) {
          final package = 'linux-eku-$flavor';
          final values = await builder.readOverrides(
            File('$destination/$package/.config'),
          );
          check(
            values['CONFIG_LOCALVERSION'] == '"-r1-eku-$flavor"',
            'Release names collide',
          );
          check(
            values['CONFIG_SECURITY_SELINUX'] == (flavor == 'se' ? 'y' : 'n') &&
                values['CONFIG_SECURITY_APPARMOR'] ==
                    (flavor == 'aa' ? 'y' : 'n'),
            'Exclusive LSM selection is incorrect',
          );
          final metadata = jsonDecode(
            await File('$destination/$package/build-info.json').readAsString(),
          ) as Map<String, dynamic>;
          check(
            metadata['flavor'] == flavor && metadata['package'] == package,
            'Flavor metadata is missing',
          );
          final exportedProfile = await builder.readOverrides(
            File('$destination/$package/build-profile.conf'),
            buildVariables: {},
          );
          check(
            exportedProfile['CONFIG_LOCALVERSION'] ==
                values['CONFIG_LOCALVERSION'],
            'Exported profile does not include flavor overrides',
          );
          check(
            await File('$base/$package/vmlinux').exists() &&
                await File('$destination/$package/vmlinux').exists(),
            'Missing flavor image',
          );
        }
        check(
          'Generating defaults:'.allMatches(result.stdout.toString()).length ==
                  2 &&
              'Applied:'.allMatches(result.stdout.toString()).isEmpty &&
              'Already applied:'.allMatches(result.stdout.toString()).length ==
                  2,
          'Unexpected flavor execution or repeated patch application',
        );
      },
    );
    await test('a selected flavor builds only that flavor', () async {
      final base = '${root.path}/aa-only-build';
      final destination = '${root.path}/aa-only-export';
      final result = await run([
        '--flavor',
        'aa',
        '--output',
        base,
        '--artifacts',
        destination,
      ]);
      check(
        result.exitCode == 0 &&
            await File('$destination/linux-eku-aa/vmlinux').exists() &&
            !await Directory('$destination/linux-eku-se').exists(),
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
    final upstream = await Directory('${root.path}/upstream').create();
    for (final name in ['Makefile', 'defaults']) {
      await File('${source.path}/$name').copy('${upstream.path}/$name');
    }
    await File('${upstream.path}/hello.c')
        .writeAsString('int main(void) { return 0; }\n');
    await File('${upstream.path}/version.txt').writeAsString('before\n');
    Future<void> git(List<String> args) async {
      final result = await Process.run('git', [
        '-C',
        upstream.path,
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ]);
      check(result.exitCode == 0, 'Fixture Git failure: ${result.stderr}');
    }

    await git(['init', '-b', 'main']);
    await git(['add', '.']);
    await git(['commit', '-m', 'Initial fixture']);
    await git(['tag', 'v7.9']);
    await File('${upstream.path}/latest.txt').writeAsString('latest commit\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'Latest fixture']);
    await git(['tag', 'v7.10.2']);
    await git(['tag', '-a', '--no-sign', '-m', 'Stable fixture', 'v7.10.10']);
    await File('${upstream.path}/candidate.txt')
        .writeAsString('release candidate\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'Unreleased candidate']);
    await git(['tag', 'v7.11-rc1']);
    final latestClone = '${root.path}/clone-latest';
    final taggedClone = '${root.path}/clone-tag';
    List<String> cloneArgs(String path) => [
      '--repo',
      upstream.uri.toString(),
      '--source',
      path,
      '--output',
      '$path-out',
      '--artifacts',
      '$path-artifacts',
    ];
    await test(
      'clone the latest stable tag instead of release-candidate HEAD',
      () async {
        final result = await run(cloneArgs(latestClone));
        check(result.exitCode == 0, '${result.stdout}\n${result.stderr}');
        check(
          await File('$latestClone/latest.txt').exists() &&
              !await File('$latestClone/candidate.txt').exists(),
          'Did not clone the latest stable release',
        );
        final metadata = jsonDecode(
          await File('$latestClone-artifacts/build-info.json').readAsString(),
        ) as Map<String, dynamic>;
        check(
          metadata['tag'] == 'v7.10.10',
          'Resolved release tag is missing from metadata',
        );
        check(
          (await Process.run('$latestClone-out/kernel-demo', [])).exitCode == 7,
          'Cloned source was not patched and compiled',
        );
        final shallow = await Process.run('git', [
          '-C',
          latestClone,
          'rev-parse',
          '--is-shallow-repository',
        ]);
        check(
          shallow.stdout.toString().trim() == 'true',
          'Clone was not shallow',
        );
      },
    );
    await test(
      'both flavors share one clone and one patch application',
      () async {
        final path = '${root.path}/clone-dual';
        final result = await run([...cloneArgs(path), '--flavor', 'both']);
        final output = result.stdout.toString();
        check(result.exitCode == 0, '$output\n${result.stderr}');
        check(
          'Cloning tag v7.10.10'.allMatches(output).length == 1 &&
              'Applied:'.allMatches(output).length == 2,
          'Source preparation repeated for each flavor',
        );
        for (final flavor in ['se', 'aa']) {
          check(
            (await Process.run(
                  '$path-artifacts/linux-eku-$flavor/vmlinux',
                  [],
                )).exitCode ==
                7,
            'Flavor $flavor did not compile the patched source',
          );
        }
      },
    );
    await test(
      'clone and reuse an explicitly selected older release tag',
      () async {
        final args = [...cloneArgs(taggedClone), '--tag', 'v7.9'];
        for (var i = 0; i < 2; i++) {
          final result = await run(args);
          check(result.exitCode == 0, '${result.stdout}\n${result.stderr}');
          check(
            result.stdout.toString().contains('Verified tag v7.9'),
            'Tag was not verified',
          );
        }
        check(
          !await File('$taggedClone/latest.txt').exists(),
          'Cloned wrong revision',
        );
        check(
          await File('$taggedClone-out/kernel-demo').exists(),
          'Tag was not built',
        );
      },
    );
    await test(
      'tag mismatch preserves the existing checkout and stops',
      () async {
        final result = await run([...cloneArgs(latestClone), '--tag', 'v7.9']);
        check(
          result.exitCode != 0 &&
              result.stderr.toString().contains('does not match tag'),
          'Tag mismatch ignored',
        );
        check(
          await File('$latestClone/latest.txt').exists(),
          'Existing checkout changed',
        );
      },
    );
    await test('explicit release-candidate tags remain supported', () async {
      final path = '${root.path}/clone-rc';
      final result = await run([...cloneArgs(path), '--tag', 'v7.11-rc1']);
      check(
        result.exitCode == 0 && await File('$path/candidate.txt').exists(),
        '${result.stdout}\n${result.stderr}',
      );
    });
    await test('no stable tags fails without falling back to HEAD', () async {
      final bare = '${root.path}/no-stable.git';
      await git(['init', '--bare', bare]);
      final path = '${root.path}/clone-no-stable';
      final result = await run([...cloneArgs(path), '--repo', bare]);
      check(
        result.exitCode != 0 &&
            result.stderr.toString().contains('No stable release tags') &&
            !await Directory(path).exists(),
        'Missing stable release did not stop cloning',
      );
    });
    await test('a branch name is not accepted as an exact tag', () async {
      final path = '${root.path}/clone-branch';
      final result = await run([...cloneArgs(path), '--tag', 'main']);
      check(
        result.exitCode != 0 && !await File('$path-out/.config').exists(),
        'Branch accepted as tag',
      );
    });
    await test(
      'invalid and nonexistent tags fail before compilation',
      () async {
        for (final tag in ['../invalid', 'missing-tag']) {
          final path = '${root.path}/clone-invalid';
          final result = await run([...cloneArgs(path), '--tag', tag]);
          check(
            result.exitCode != 0 && !await File('$path-out/.config').exists(),
            'Invalid tag accepted: $tag',
          );
        }
      },
    );
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

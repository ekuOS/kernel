import 'dart:io';

import '../build.dart' as builder;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final source = await Directory.systemTemp.createTemp('ekuos-wx-config-');
  final kconfig = File('${source.path}/mm/Kconfig.debug');
  await kconfig.parent.create();
  final log = builder.Log(noColor: true);
  var count = 0;
  Future<void> test(String name, Future<void> Function() body) async {
    await body();
    count++;
    stdout.writeln('PASS $name');
  }

  builder.BuildProfile profile(Map<String, String> values) =>
      builder.BuildProfile(values, {'LLVM': '1'}, 'original profile');
  try {
    await test(
      'Linux 7.3 DEBUG_WX replaces an unavailable CHECK_WX request',
      () async {
        await kconfig.writeAsString(
          'config ARCH_HAS_DEBUG_WX\n\tbool\n\nconfig DEBUG_WX\n\tbool "Check W+X"\n',
        );
        final original = profile({
          'CONFIG_CHECK_WX': 'y',
          'CONFIG_STRICT_KERNEL_RWX': 'y',
        });
        final resolved = await original.forSource(source.path, log);
        check(
          resolved.overrides['CONFIG_DEBUG_WX'] == 'y' &&
              !resolved.overrides.containsKey('CONFIG_CHECK_WX') &&
              resolved.overrides['CONFIG_STRICT_KERNEL_RWX'] == 'y',
          'Alias lost hardening settings',
        );
        check(
          original.overrides['CONFIG_CHECK_WX'] == 'y',
          'Input profile was modified',
        );
        final exported = File('${source.path}/effective.conf');
        await exported.writeAsString(resolved.text);
        final variables = <String, String>{};
        final settings = await builder.readOverrides(
          exported,
          buildVariables: variables,
        );
        check(
          settings['CONFIG_DEBUG_WX'] == 'y' &&
              !settings.containsKey('CONFIG_CHECK_WX') &&
              variables['LLVM'] == '1',
          'Exported effective profile uses the wrong symbol',
        );
      },
    );
    await test(
      'Linux 7.4 CHECK_WX replaces an unavailable DEBUG_WX request',
      () async {
        await kconfig.writeAsString('config CHECK_WX\n\tbool "Check W+X"\n');
        final resolved = await profile({'CONFIG_DEBUG_WX': 'y'})
            .forSource(source.path, log);
        check(
          resolved.overrides['CONFIG_CHECK_WX'] == 'y' &&
              !resolved.overrides.containsKey('CONFIG_DEBUG_WX'),
          'New symbol was not selected',
        );
      },
    );
    await test(
      'already supported symbols preserve the profile unchanged',
      () async {
        final original = profile({'CONFIG_CHECK_WX': 'y'});
        check(
          identical(await original.forSource(source.path, log), original),
          'Supported profile was rewritten',
        );
      },
    );
    await test('a disabled setting stays disabled when translated', () async {
      final resolved = await profile({'CONFIG_DEBUG_WX': 'n'})
          .forSource(source.path, log);
      check(
        resolved.overrides['CONFIG_CHECK_WX'] == 'n',
        'Disabled setting changed value',
      );
    });
    await test(
      'conflicting alias values fail instead of silently choosing one',
      () async {
        var rejected = false;
        try {
          await profile({'CONFIG_DEBUG_WX': 'y', 'CONFIG_CHECK_WX': 'n'})
              .forSource(source.path, log);
        } on builder.BuildFailure {
          rejected = true;
        }
        check(rejected, 'Conflicting requests accepted');
        final same = await profile({
          'CONFIG_DEBUG_WX': 'y',
          'CONFIG_CHECK_WX': 'y',
        }).forSource(source.path, log);
        check(
          same.overrides.length == 1 &&
              same.overrides['CONFIG_CHECK_WX'] == 'y',
          'Equivalent aliases were not consolidated',
        );
      },
    );
    await test('references, comments and architecture capability names are not definitions', () async {
      await kconfig.writeAsString(
        'config ARCH_HAS_DEBUG_WX\n\tbool\n# config DEBUG_WX\nselect CHECK_WX\n',
      );
      final original = profile({'CONFIG_CHECK_WX': 'y', 'CONFIG_UNKNOWN': 'y'});
      check(
        identical(await original.forSource(source.path, log), original),
        'Unrelated text triggered alias mapping',
      );
    });
    await test(
      'unknown or ambiguous source definitions keep strict validation intact',
      () async {
        await kconfig.writeAsString(
          'config DEBUG_WX\n\tbool\nconfig CHECK_WX\n\tbool\n',
        );
        final original = profile({
          'CONFIG_DEBUG_WX': 'y',
          'CONFIG_UNKNOWN': 'y',
        });
        check(
          identical(await original.forSource(source.path, log), original),
          'Ambiguous definitions guessed a mapping',
        );
        await kconfig.delete();
        check(
          identical(await original.forSource(source.path, log), original) &&
              original.overrides.containsKey('CONFIG_UNKNOWN'),
          'Unavailable settings were silently discarded',
        );
      },
    );
    stdout.writeln('$count profile compatibility tests passed');
  } finally {
    await source.delete(recursive: true);
  }
}

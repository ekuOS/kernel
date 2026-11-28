import 'dart:convert';
import 'dart:io';

import '../../build.dart'
    show BuildFailure, Log, Runner, microvisorRepository, microvisorRevision;
import '../../test/verify_kernel.dart' show sameFile;

const project = '/input';
const defaultBinhost = 'amd64/23.0/llvm/systemd';
final binhost = Platform.environment['BINHOST_PATH'] ?? defaultBinhost;
final output = '/output/$binhost';
final distfiles = '$output/distfiles';
const overlay = '/var/db/repos/ekuos-kernel';
final profile = switch (binhost) {
  'amd64/23.0/multilib/systemd' => 'default/linux/amd64/23.0/systemd',
  defaultBinhost => 'default/linux/amd64/23.0/llvm/systemd',
  _ => throw BuildFailure('Unsupported kernel binhost path: $binhost'),
};
const flavors = ['se', 'aa'];
final runner = Runner(Log(noColor: true));

Future<String> capture(
  String command,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(command, args, environment: environment);
  if (result.exitCode != 0) {
    throw BuildFailure('$command failed: ${result.stdout}${result.stderr}');
  }
  return (result.stdout as String).trimRight();
}

void check(bool ok, String message) {
  if (!ok) throw BuildFailure(message);
}

Future<String> release() async {
  final line = await File('$project/packaging/gentoo/linux.sha256')
      .readAsString();
  final match = RegExp(r'^[0-9a-f]{64}  linux-(\d+\.\d+\.\d+)\.tar\.xz$')
      .firstMatch(line.trimRight());
  check(match != null, 'Invalid linux.sha256');
  return match![1]!;
}

Future<String> manifestEntry(String name) async {
  final file = File('$distfiles/$name');
  Future<String> digest(String cmd) async =>
      (await capture(cmd, [file.path])).split(' ').first;
  return 'DIST $name ${await file.length()} '
      'BLAKE2B ${await digest('b2sum')} SHA512 ${await digest('sha512sum')}';
}

Future<void> write(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('$text\n');
}

Future<void> prepareSources(String version) async {
  await Directory(distfiles).create(recursive: true);
  final linux = 'linux-$version.tar.xz';
  final tooling = 'ekuos-kernel-$version';
  await runner.run('curl', [
    '--fail',
    '--location',
    '--connect-timeout',
    '20',
    '--retry',
    '3',
    'https://cdn.kernel.org/pub/linux/kernel/v${version.split('.').first}.x/$linux',
    '--output',
    '$distfiles/$linux',
  ]);
  await runner.run('sha256sum', [
    '--check',
    '$project/packaging/gentoo/linux.sha256',
  ], cwd: distfiles);
  final staging = await Directory.systemTemp.createTemp('ekuos-sources-');
  try {
    final root = '${staging.path}/$tooling';
    await Directory('$root/test').create(recursive: true);
    await runner.run('cp', [
      '-a',
      for (final name in [
        'LICENSE',
        'build.dart',
        'eku.conf',
        'patches',
        'profiles',
      ])
        '$project/$name',
      root,
    ]);
    await File('$project/test/verify_kernel.dart')
        .copy('$root/test/verify_kernel.dart');
    // Portage's compile phase has no network access. Ship the pinned Git
    // commit so the builder can clone it inside the sandbox.
    final microvisor = '${staging.path}/microvisor';
    await runner.run('git', [
      'clone',
      '--no-checkout',
      '--',
      microvisorRepository,
      microvisor,
    ]);
    await runner.run('git', [
      '-C',
      microvisor,
      'branch',
      'ekuos-build',
      microvisorRevision,
    ]);
    await runner.run('git', [
      '-C',
      microvisor,
      'bundle',
      'create',
      '$root/microvisor.bundle',
      'ekuos-build',
    ]);
    await runner.run('tar', [
      '-C',
      staging.path,
      '-czf',
      '$distfiles/$tooling.tar.gz',
      tooling,
    ]);
  } finally {
    await staging.delete(recursive: true);
  }

  await runner.run('cp', ['-R', '$project/packaging/gentoo/overlay', overlay]);
  final eclass = File('$overlay/eclass/ekuos-kernel.eclass');
  final source = await eclass.readAsString();
  await eclass.writeAsString(source.replaceFirst(defaultBinhost, binhost));
  final manifest = [
    await manifestEntry('$tooling.tar.gz'),
    await manifestEntry(linux),
  ].join('\n');
  for (final flavor in flavors) {
    final path = '$overlay/sys-kernel/linux-eku-$flavor';
    check(
      await File('$path/linux-eku-$flavor-$version.ebuild').exists(),
      'Missing linux-eku-$flavor-$version ebuild',
    );
    await write('$path/Manifest', manifest);
  }
  await runner.run('tar', [
    '-C',
    overlay,
    '-czf',
    '$output/overlay.tar.gz',
    '.',
  ]);
}

Future<void> emerge(List<String> args, Map<String, String> env) async {
  final child = await Process.start(
    'emerge',
    ['--oneshot', ...args],
    environment: env,
    mode: ProcessStartMode.inheritStdio,
  );
  final status = await child.exitCode;
  check(status == 0, 'emerge failed (exit $status): ${args.join(' ')}');
}

Future<void> verifyInstalled(String version, String flavor) async {
  final release = '$version-eku-$flavor';
  final modules = '/usr/lib/modules/$release';
  final reference = '/var/tmp/ekuos-verified-$flavor';
  for (final (source, target) in [
    ('bzImage', 'vmlinuz-$release'),
    ('.config', 'config-$release'),
    ('System.map', 'System.map-$release'),
  ]) {
    await sameFile('$reference/$source', '/boot/$target');
  }
  final config = (await File('/boot/config-$release').readAsLines()).toSet();
  for (final option in [
    'BLK_DEV_NVME',
    'VMD',
    'SATA_AHCI',
    'USB_STORAGE',
    'VIRTIO_BLK',
    'SCSI_VIRTIO',
    'EXT4_FS',
    'FS_ENCRYPTION',
    'CRYPTO_CTS',
    'CRYPTO_XTS',
    'BTRFS_FS',
    'VFAT_FS',
    'EFI_STUB',
    'DRM_EFIDRM',
    'DRM_FBDEV_EMULATION',
    'FRAMEBUFFER_CONSOLE',
    'BLK_DEV_INITRD',
    'IA32_EMULATION',
  ]) {
    check(
      config.contains('CONFIG_$option=y'),
      '$release requires CONFIG_$option=y',
    );
  }
  check(
    await File('$modules/modules.dep.bin').length() > 0,
    'Missing module dependency index',
  );
  check(!await Link('$modules/build').exists(), 'Unexpected build-tree link');
  final order = await File('$modules/modules.order').readAsLines();
  final expected = (await File('$reference/modules.order').readAsLines())
      .where((path) => path.isNotEmpty)
      .map((path) => 'kernel/${path.replaceFirst(RegExp(r'\.o$'), '.ko')}')
      .toList();
  check(
    expected.isNotEmpty && order.join('\n') == expected.join('\n'),
    'Installed modules.order differs from the verified build for $release',
  );
  for (final path in order) {
    await sameFile(
      '$modules/$path',
      '$reference/modules/${path.substring('kernel/'.length)}',
    );
    check(
      (await capture('modinfo', [
        '-F',
        'vermagic',
        '$modules/$path',
      ])).startsWith('$release '),
      'Wrong vermagic in $path',
    );
  }
}

Future<void> exportNativePayload(String version, String flavor) async {
  final release = '$version-eku-$flavor';
  await runner.run('tar', [
    '-C',
    '/',
    '-czf',
    '/native-output/linux-eku-$flavor-$version.tar.gz',
    'boot/vmlinuz-$release',
    'boot/config-$release',
    'boot/System.map-$release',
    'usr/lib/modules/$release',
  ]);
}

Future<void> build(String version) async {
  check(
    await Link('/etc/portage/make.profile').resolveSymbolicLinks() ==
            '/var/db/repos/gentoo/profiles/$profile' &&
        await capture('portageq', ['envvar', 'CHOST']) == 'x86_64-pc-linux-gnu',
    'Gentoo stage profile or CHOST does not match the binhost',
  );
  final atoms = [
    for (final flavor in flavors) '=sys-kernel/linux-eku-$flavor-$version',
  ];
  await prepareSources(version);
  await write(
    '/etc/portage/repos.conf/ekuos-kernel.conf',
    '[ekuos-kernel]\nlocation = $overlay\nauto-sync = no',
  );
  await write(
    '/etc/portage/package.accept_keywords/ekuos-kernel',
    atoms.map((atom) => '$atom ~amd64').join('\n'),
  );
  await write(
    '/etc/portage/package.use/ekuos-kernel',
    'dev-lang/rust-bin rust-src\ndev-lang/rust rust-src',
  );
  final env = {
    'MAKEOPTS': '-j${Platform.numberOfProcessors}',
    // Keep the verified artifact bundle until after the binary installs.
    'FEATURES': 'keepwork -getbinpkg -binpkg-signing -binpkg-request-signature',
    'BINPKG_FORMAT': 'gpkg',
    'DISTDIR': distfiles,
    'PKGDIR': output,
  };
  // Use the official binhost for dependencies, but do not mix them into ours.
  await emerge(
    ['--onlydeps', '--getbinpkg', ...atoms],
    {'MAKEOPTS': env['MAKEOPTS']!},
  );
  final rootPath = RegExp(
    r"^export ROOTPATH='([^']+)'$",
    multiLine: true,
  ).firstMatch(await File('/etc/profile.env').readAsString())?.group(1);
  check(rootPath != null, 'Cannot read Gentoo toolchain PATH');
  env['PATH'] = rootPath!;
  for (final flavor in flavors) {
    final atom = '=sys-kernel/linux-eku-$flavor-$version';
    await emerge(['--buildpkgonly', atom], env);
    // Preserve an independent copy across Portage build-directory cleanup.
    final work = '/var/tmp/portage/sys-kernel/linux-eku-$flavor-$version/work';
    final source = '$work/out/linux-eku-$flavor';
    final reference = '/var/tmp/ekuos-verified-$flavor';
    await Directory(reference).create();
    await runner.run('cp', [
      '-a',
      for (final name in [
        'bzImage',
        'System.map',
        '.config',
        'modules.order',
        'modules',
      ])
        '$source/$name',
      reference,
    ]);
    await emerge(['--usepkgonly', '--binpkg-respect-use=y', atom], env);
  }
  for (final flavor in flavors) {
    await verifyInstalled(version, flavor);
    if (await Directory('/native-output').exists()) {
      await exportNativePayload(version, flavor);
    }
    stdout.writeln('Verified installed linux-eku-$flavor-$version');
  }
}

Future<void> importSigningKey(Directory home) async {
  final input = await stdin.transform(utf8.decoder).join();
  final boundary = input.indexOf('\n');
  check(
    boundary >= 0 &&
        input
            .substring(boundary + 1)
            .trimLeft()
            .startsWith('-----BEGIN PGP PRIVATE KEY BLOCK-----'),
    'Expected a passphrase line followed by an armored private key',
  );
  if (boundary > 0) {
    final passphrase = '${home.path}/passphrase';
    await write(passphrase, input.substring(0, boundary));
    await runner.run('chmod', ['600', passphrase]);
    await write(
      '${home.path}/gpg.conf',
      'pinentry-mode loopback\npassphrase-file $passphrase',
    );
  }
  final process = await Process.start('gpg', [
    '--batch',
    '--homedir',
    home.path,
    '--import',
  ]);
  // Never print import diagnostics that may contain private input.
  final drained = Future.wait([
    process.stdout.drain<void>(),
    process.stderr.drain<void>(),
  ]);
  process.stdin.write(input.substring(boundary + 1));
  await process.stdin.close();
  await drained;
  check(await process.exitCode == 0, 'Could not import binhost signing key');
}

Future<void> sign(String version) async {
  final scratch = await Directory.systemTemp.createTemp('ekuos-signing-');
  final signHome = Directory('${scratch.path}/sign');
  final verifyHome = '${scratch.path}/verify';
  try {
    await runner.run('chmod', ['755', scratch.path]);
    await runner.run('install', ['-d', '-m700', signHome.path, verifyHome]);
    await Directory('/run/lock').create(recursive: true);
    await importSigningKey(signHome);
    final listing = await capture('gpg', [
      '--homedir',
      signHome.path,
      '--batch',
      '--with-colons',
      '--list-secret-keys',
    ]);
    final fingerprints = RegExp(
      r'^sec:[^\n]*\nfpr:(?:[^:\n]*:){8}([^:\n]+):',
      multiLine: true,
    ).allMatches(listing);
    check(fingerprints.length == 1, 'Expected one secret signing key');
    final fingerprint = fingerprints.single[1]!;
    final publicKey = '$output/signing-key.asc';
    await write(
      publicKey,
      await capture('gpg', [
        '--homedir',
        signHome.path,
        '--batch',
        '--armor',
        '--export',
        fingerprint,
      ]),
    );
    await write('$output/signing-key.fingerprint', fingerprint);
    final trust = '${scratch.path}/ownertrust';
    await write(trust, '$fingerprint:6:');
    for (final args in [
      ['--import', publicKey],
      ['--import-ownertrust', trust],
      ['--check-trustdb'],
    ]) {
      await runner.run('gpg', ['--homedir', verifyHome, '--batch', ...args]);
    }
    await runner.run('chmod', ['-R', 'a+rX', verifyHome]);
    await runner.run('chmod', ['755', verifyHome]);
    final env = {
      'PKGDIR': output,
      'BINPKG_FORMAT': 'gpkg',
      'BINPKG_GPG_SIGNING_GPG_HOME': signHome.path,
      'BINPKG_GPG_VERIFY_GPG_HOME': verifyHome,
      'BINPKG_GPG_SIGNING_KEY': fingerprint,
      'FEATURES': 'binpkg-request-signature compress-index',
    };
    final paths = <String>[];
    for (final flavor in flavors) {
      final pn = 'linux-eku-$flavor';
      final packages = await Directory('$output/sys-kernel/$pn')
          .list(followLinks: false)
          .where(
            (f) =>
                f is File &&
                RegExp('^$pn-${RegExp.escape(version)}-\\d+\\.gpkg\\.tar\$')
                    .hasMatch(f.uri.pathSegments.last),
          )
          .toList();
      check(packages.length == 1, 'Expected one $pn GPKG');
      final path = packages.single.path;
      paths.add(path.substring(output.length + 1));
      await capture('gpkg-sign', ['--allow-unsigned', path], environment: env);
      await runner.run('chmod', ['a+r', path]);
    }
    // Discard the unsigned digests and let Portage verify/reindex the packages.
    for (final name in ['Packages', 'Packages.gz']) {
      final file = File('$output/$name');
      if (await file.exists()) await file.delete();
    }
    for (final operation in ['--fix', '--check']) {
      stdout.writeln(
        await capture('emaint', ['binhost', operation], environment: env),
      );
    }
    final index = await File('$output/Packages').readAsString();
    check(
      await capture('gzip', ['-dc', '$output/Packages.gz']) ==
          index.trimRight(),
      'Packages.gz does not match Packages',
    );
    final records = index.trimRight().split(RegExp(r'\n\n+'));
    check(
      records.length == 3 && records.first.split('\n').contains('PACKAGES: 2'),
      'Expected two indexed packages',
    );
    for (var i = 0; i < flavors.length; i++) {
      final fields = [
        'CPV: sys-kernel/linux-eku-${flavors[i]}-$version',
        'SLOT: $version',
        'REPO: ekuos-kernel',
        'PATH: ${paths[i]}',
      ];
      check(
        records.skip(1).any((r) => fields.every(r.split('\n').contains)),
        'Incomplete Packages record for ${paths[i]}',
      );
    }
    final sums = '$output/SHA256SUMS';
    final sumResult = await Process.run('sha256sum', [
      'Packages',
      'Packages.gz',
      'overlay.tar.gz',
      'distfiles/linux-$version.tar.xz',
      'distfiles/ekuos-kernel-$version.tar.gz',
      ...paths,
    ], workingDirectory: output);
    check(
      sumResult.exitCode == 0,
      'Could not hash publication: ${sumResult.stderr}',
    );
    await write(sums, (sumResult.stdout as String).trimRight());
    await runner.run('gpg', [
      '--homedir',
      signHome.path,
      '--batch',
      '--yes',
      '--local-user',
      fingerprint,
      '--armor',
      '--detach-sign',
      sums,
    ]);
    await runner.run('gpg', [
      '--homedir',
      verifyHome,
      '--batch',
      '--verify',
      '$sums.asc',
      sums,
    ]);
    await runner.run('chmod', ['-R', 'a+rX', output]);
  } finally {
    if (await signHome.exists()) {
      await Process.run('gpgconf', [
        '--homedir',
        signHome.path,
        '--kill',
        'all',
      ]);
    }
    await scratch.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  try {
    // Reject unknown paths in the offline signing container as well.
    check(profile.isNotEmpty, 'Expected a supported Gentoo profile');
    switch (args.singleOrNull) {
      case 'build':
        await build(await release());
      case 'sign':
        await sign(await release());
      default:
        throw BuildFailure('Usage: binhost.dart build|sign');
    }
  } on Object catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}

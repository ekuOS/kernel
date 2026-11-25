import 'dart:io';

import '../../build.dart' show BuildFailure, Log, Runner;

final runner = Runner(Log(noColor: true));
const flavors = ['se', 'aa'];

Future<File> write(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  return file.writeAsString(text);
}

Future<String> capture(String command, List<String> args, {String? cwd}) async {
  final result = await Process.run(command, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw BuildFailure('$command failed: ${result.stderr}');
  }
  return result.stdout as String;
}

Future<void> deb(
  String root,
  String output,
  String flavor,
  String version,
) async {
  final release = '$version-eku-$flavor';
  final image = 'linux-image-$version-eku';
  final modules = Directory('$root/usr/lib/modules/$release');
  // Debian kmod and initramfs-tools use /lib/modules. On merged-/usr
  // systems this resolves to the same on-disk location as /usr/lib/modules.
  await Directory('$root/lib/modules').create(recursive: true);
  await modules.rename('$root/lib/modules/$release');
  await Directory('$root/usr').delete(recursive: true);
  await write('$root/DEBIAN/control', '''
Package: $image
Version: $version-1
Architecture: amd64
Maintainer: ekuOS <kernel@ekuos.github.io>
Section: kernel
Priority: optional
Depends: kmod, initramfs-tools | dracut
Provides: linux-image
Description: Hardened ekuOS Linux kernel ($flavor)
''');
  for (final phase in ['preinst', 'postinst', 'prerm', 'postrm']) {
    final depmod = phase == 'postinst'
        ? 'if [ "\$1" = configure ]; then /sbin/depmod $release; fi\n'
        : '';
    final hook = await write('$root/DEBIAN/$phase', '''
#!/bin/sh
set -e
export DEB_MAINT_PARAMS="\$*" INITRD=Yes
${depmod}for dir in /etc/kernel/$phase.d /usr/share/kernel/$phase.d; do
    [ -d "\$dir" ] || continue
    run-parts --exit-on-error --arg=$release --arg=/boot/vmlinuz-$release "\$dir"
done
''');
    await runner.run('chmod', ['755', hook.path]);
  }
  await runner.run('dpkg-deb', ['--root-owner-group', '--build', root, output]);
  final meta = await Directory.systemTemp.createTemp('ekuos-deb-meta-');
  try {
    await runner.run('chmod', ['755', meta.path]);
    await write('${meta.path}/DEBIAN/control', '''
Package: linux-image-eku
Version: $version-1
Architecture: amd64
Maintainer: ekuOS <kernel@ekuos.github.io>
Section: kernel
Priority: optional
Depends: $image (= $version-1)
Provides: linux-image-generic, linux-image-amd64
Description: Tracks the ekuOS Linux kernel ($flavor)
''');
    await runner.run('dpkg-deb', [
      '--root-owner-group',
      '--build',
      meta.path,
      output,
    ]);
  } finally {
    await meta.delete(recursive: true);
  }
}

Future<void> rpm(
  String root,
  String output,
  String flavor,
  String version,
) async {
  final release = '$version-eku-$flavor';
  final modules = '$root/usr/lib/modules/$release';
  for (final (source, target) in [
    ('vmlinuz-$release', 'vmlinuz'),
    ('System.map-$release', 'System.map'),
    ('config-$release', 'config'),
  ]) {
    await File('$root/boot/$source').rename('$modules/$target');
  }
  final top = await Directory.systemTemp.createTemp('ekuos-rpm-');
  try {
    final spec = await write('${top.path}/kernel.spec', '''
%global __os_install_post %{nil}
%global _build_id_links none
Name: kernel-eku
Version: $version
Release: 1
Summary: Hardened ekuOS Linux kernel ($flavor)
License: GPL-2.0-only
BuildArch: x86_64
AutoReqProv: no
Requires: kmod, dracut, systemd
Provides: installonlypkg(kernel)
Provides: kernel = %{version}-%{release}
Provides: kernel-core = %{version}-%{release}
Provides: kernel-modules = %{version}-%{release}
%description
Hardened ekuOS Linux kernel, installable alongside the distribution kernel.

%install
mkdir -p "%{buildroot}/usr/lib/modules"
cp -a "$modules" "%{buildroot}/usr/lib/modules/"

%posttrans
/usr/bin/kernel-install add $release /usr/lib/modules/$release/vmlinuz

%preun
/usr/bin/kernel-install remove $release

%files
%defattr(-,root,root,-)
/usr/lib/modules/$release
''');
    await runner.run('rpmbuild', [
      '--define',
      '_topdir ${top.path}',
      '--define',
      '_rpmdir $output',
      '-bb',
      spec.path,
    ]);
  } finally {
    await top.delete(recursive: true);
  }
}

Future<void> pacman(
  String root,
  String output,
  String flavor,
  String version,
) async {
  final release = '$version-eku-$flavor';
  final name = 'linux-eku-$flavor';
  final modules = '$root/usr/lib/modules/$release';
  await File('$root/boot/vmlinuz-$release').rename('$modules/vmlinuz');
  await Directory('$root/boot').delete(recursive: true);
  await write('$modules/pkgbase', '$name\n');
  await write('$root/.PKGINFO', '''
pkgname = $name
pkgbase = $name
pkgver = $version-1
pkgdesc = Hardened ekuOS Linux kernel ($flavor)
url = https://github.com/ekuOS/kernel
builddate = ${DateTime.now().millisecondsSinceEpoch ~/ 1000}
size = ${(await capture('du', ['-sb', '$root/usr'])).split(RegExp(r'\s+')).first}
arch = x86_64
license = GPL-2.0-only
depend = coreutils
depend = kmod
depend = mkinitcpio
''');
  await runner.run('bsdtar', [
    '--format=mtree',
    '--options=!all,type,uid,gid,mode,time,size,sha256,link',
    '--uid',
    '0',
    '--gid',
    '0',
    '-czf',
    '$root/.MTREE',
    '-C',
    root,
    '.PKGINFO',
    'usr',
  ]);
  await runner.run('tar', [
    '--zstd',
    '--owner=0',
    '--group=0',
    '-cf',
    '$output/$name-$version-1-x86_64.pkg.tar.zst',
    '-C',
    root,
    '.PKGINFO',
    '.MTREE',
    'usr',
  ]);
}

Future<void> build(String input, String site) async {
  for (final (format, selected) in [
    ('apt', ['aa']),
    ('dnf', ['se']),
    ('pacman', flavors),
  ]) {
    final output = await Directory('$site/$format').create(recursive: true);
    for (final flavor in selected) {
      final matches = await Directory(input)
          .list()
          .where(
            (file) => RegExp(
              '^linux-eku-$flavor-[0-9]+\\.[0-9]+\\.[0-9]+\\.tar\\.gz\$',
            ).hasMatch(file.uri.pathSegments.last),
          )
          .toList();
      if (matches.length != 1)
        throw BuildFailure('Expected one payload for $flavor');
      final version = matches.single.uri.pathSegments.last
          .substring('linux-eku-$flavor-'.length)
          .split('.tar.gz')
          .first;
      final root = await Directory.systemTemp.createTemp(
        'ekuos-kernel-payload-',
      );
      try {
        await runner.run('chmod', ['755', root.path]);
        await runner.run('tar', ['-xzf', matches.single.path, '-C', root.path]);
        switch (format) {
          case 'apt':
            await deb(root.path, output.absolute.path, flavor, version);
          case 'dnf':
            await rpm(root.path, output.absolute.path, flavor, version);
          case 'pacman':
            await pacman(root.path, output.absolute.path, flavor, version);
        }
      } finally {
        await root.delete(recursive: true);
      }
    }
  }
}

Future<void> publish(String site) async {
  String secret(String name) => Platform.environment[name] ?? '';
  final key = secret('BINHOST_GPG_PRIVATE_KEY');
  final passphrase = secret('BINHOST_GPG_PASSPHRASE');
  if (key.isEmpty || passphrase.contains(RegExp(r'[\r\n]'))) {
    throw BuildFailure(
      'Expected a signing key and optional single-line passphrase',
    );
  }
  final home = await Directory.systemTemp.createTemp('ekuos-native-sign-');
  try {
    await runner.run('chmod', ['700', home.path]);
    final passFile = await write('${home.path}/passphrase', '$passphrase\n');
    await runner.run('chmod', ['600', passFile.path]);
    await write('${home.path}/gpg.conf', '''
batch
pinentry-mode loopback
${passphrase.isEmpty ? '' : 'passphrase-file ${passFile.path}'}
''');
    Future<String> gpg(List<String> args) =>
        capture('gpg', ['--homedir', home.path, ...args]);
    final import = await Process.start('gpg', [
      '--homedir',
      home.path,
      '--import',
    ]);
    final drained = Future.wait([
      import.stdout.drain<void>(),
      import.stderr.drain<void>(),
    ]);
    import.stdin.write(key);
    await import.stdin.close();
    await drained;
    if (await import.exitCode != 0)
      throw BuildFailure('Could not import signing key');
    final keys = await gpg(['--with-colons', '--list-secret-keys']);
    final fingerprints = RegExp(
      r'^sec:[^\n]*\nfpr:(?:[^:\n]*:){8}([^:\n]+):',
      multiLine: true,
    ).allMatches(keys).toList();
    if (fingerprints.length != 1)
      throw BuildFailure('Expected one secret signing key');
    final fingerprint = fingerprints.single[1]!;
    await gpg(['--output', '$site/signing-key.gpg', '--export', fingerprint]);
    await gpg([
      '--armor',
      '--output',
      '$site/signing-key.asc',
      '--export',
      fingerprint,
    ]);
    Future<void> sign(String path, {bool armor = false, String? target}) async {
      await gpg([
        '--local-user',
        fingerprint,
        if (armor) '--armor',
        if (target != null) ...['--output', target],
        '--detach-sign',
        path,
      ]);
      await gpg([
        '--verify',
        target ?? '$path${armor ? '.asc' : '.sig'}',
        path,
      ]);
    }

    final apt = '$site/apt';
    await write(
      '$apt/Packages',
      await capture('apt-ftparchive', ['packages', '.'], cwd: apt),
    );
    await write(
      '$apt/Release',
      await capture('apt-ftparchive', [
        '-o',
        'APT::FTPArchive::Release::Origin=ekuOS',
        '-o',
        'APT::FTPArchive::Release::Architectures=amd64',
        'release',
        '.',
      ], cwd: apt),
    );
    await gpg([
      '--local-user',
      fingerprint,
      '--clearsign',
      '--output',
      '$apt/InRelease',
      '$apt/Release',
    ]);
    await sign('$apt/Release', armor: true, target: '$apt/Release.gpg');

    final dnf = '$site/dnf';
    final rpms = await Directory(dnf)
        .list(recursive: true)
        .where((f) => f.path.endsWith('.rpm'))
        .toList();
    if (rpms.length != 1) throw BuildFailure('Expected one SELinux RPM');
    final rpmdb = '${home.path}/rpmdb';
    await Directory(rpmdb).create();
    await runner.run('rpm', [
      '--dbpath',
      rpmdb,
      '--import',
      '$site/signing-key.asc',
    ]);
    for (final rpm in rpms) {
      await runner.run('rpmsign', [
        '--define',
        '_gpg_name $fingerprint',
        '--define',
        '_gpg_path ${home.path}',
        '--define',
        '__gpg /usr/bin/gpg',
        '--addsign',
        rpm.path,
      ]);
      final signature = await capture('rpmkeys', [
        '--dbpath',
        rpmdb,
        '--checksig',
        rpm.path,
      ]);
      if (!signature.contains('signatures OK')) {
        throw BuildFailure('RPM signature missing: $signature');
      }
    }
    await runner.run('createrepo_c', [dnf]);
    await sign('$dnf/repodata/repomd.xml', armor: true);

    final arch = '$site/pacman/x86_64';
    await Directory(arch).create();
    final packages = await Directory('$site/pacman')
        .list()
        .where((f) => f.path.endsWith('.pkg.tar.zst'))
        .toList();
    if (packages.length != 2)
      throw BuildFailure('Expected two pacman packages');
    for (final pkg in packages.cast<File>()) {
      final dest = await pkg.rename('$arch/${pkg.uri.pathSegments.last}');
      await capture('pacman', ['--config', '/dev/null', '-Qip', dest.path]);
      await sign(dest.path);
    }
    await runner.run('repo-add', [
      'ekuos.db.tar.gz',
      for (final pkg in packages) pkg.uri.pathSegments.last,
    ], cwd: arch);
    for (final index in ['db', 'files']) {
      // GitHub Pages artifacts may not contain symlinks.
      await Link('$arch/ekuos.$index').delete();
      await File('$arch/ekuos.$index.tar.gz').rename('$arch/ekuos.$index');
      await sign('$arch/ekuos.$index');
    }
  } finally {
    await Process.run('gpgconf', ['--homedir', home.path, '--kill', 'all']);
    await home.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length == 3 && args[0] == 'build') {
      await build(args[1], args[2]);
    } else if (args.length == 2 && args[0] == 'publish') {
      await publish(Directory(args[1]).absolute.path);
    } else {
      throw BuildFailure(
        'Usage: repositories.dart build INPUT SITE | publish SITE',
      );
    }
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../build.dart' as builder;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> sameFile(String a, String b) async {
  final left = await File(a).open();
  final right = await File(b).open();
  try {
    check(
      await left.length() == await right.length(),
      'Size mismatch: $a / $b',
    );
    while (true) {
      final bytes = await left.read(65536);
      if (bytes.isEmpty) break;
      check(
        sameBytes(bytes, await right.read(bytes.length)),
        'Content mismatch: $a / $b',
      );
    }
  } finally {
    await left.close();
    await right.close();
  }
}

Future<String> run(String command, List<String> args) async {
  final result = await Process.run(command, args);
  check(result.exitCode == 0, '$command failed: ${result.stderr}');
  return result.stdout as String;
}

/// Optional integration check against a real ekuOS kernel build.
/// Requires OpenSSL and GNU readelf in PATH; performs no installation or boot.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    for (final flavor in ['se', 'aa']) {
      await main([
        'build/linux-eku-$flavor',
        'out/linux-eku-$flavor',
        'out/linux-eku-$flavor/build-profile.conf',
      ]);
    }
    return;
  }
  if (args.length > 3) {
    stderr.writeln(
      'Usage: dart run test/verify_kernel.dart [BUILD [OUT [PROFILE]]]',
    );
    exitCode = 1;
    return;
  }
  final build = args[0];
  final out = args.length > 1 ? args[1] : 'out';
  final profile = args.length > 2 ? args[2] : '$out/build-profile.conf';
  final temporary = await Directory.systemTemp.createTemp('ekuos-verify-');
  try {
    final expected = await builder.readOverrides(
      File(profile),
      buildVariables: {},
    );
    final actual = await builder.readOverrides(File('$out/.config'));
    for (final item in expected.entries) {
      check(actual[item.key] == item.value, 'Override mismatch: ${item.key}');
    }
    check(
      actual['CONFIG_CC_IS_CLANG'] == 'y' && actual['CONFIG_LD_IS_LLD'] == 'y',
      'Build did not use Clang/LLD',
    );
    check(
      actual['CONFIG_CFI'] == 'y' &&
          actual['CONFIG_CFI_PERMISSIVE'] == 'n' &&
          actual['CONFIG_MODULE_SIG_FORCE'] == 'y',
      'CFI/signature enforcement missing',
    );

    final metadata = jsonDecode(
      await File('$out/build-info.json').readAsString(),
    ) as Map<String, dynamic>;
    check(
      actual['CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY'] == 'y' &&
          actual['CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY'] == 'n',
      'Confidentiality lockdown is not the default',
    );
    final flavor = metadata['flavor'];
    if (flavor == 'se' || flavor == 'aa') {
      check(
        (await File(
          '$out/kernel.release',
        ).readAsString()).trim().endsWith('-eku-$flavor'),
        'Kernel release does not match flavor $flavor',
      );
      final lsm = (jsonDecode(actual['CONFIG_LSM']!) as String).split(',');
      check(
        actual['CONFIG_LOCALVERSION'] == '"-eku-$flavor"' &&
            actual['CONFIG_SECURITY_SELINUX'] == (flavor == 'se' ? 'y' : 'n') &&
            actual['CONFIG_SECURITY_APPARMOR'] ==
                (flavor == 'aa' ? 'y' : 'n') &&
            lsm.contains(flavor == 'se' ? 'selinux' : 'apparmor') &&
            !lsm.contains(flavor == 'se' ? 'apparmor' : 'selinux'),
        'Incorrect exclusive LSM selection for $flavor',
      );
    }
    final files = metadata['files'] as List<dynamic>;
    for (final entry in files.cast<Map<String, dynamic>>()) {
      final path = entry['path'] as String;
      check(
        !path.startsWith('/') && !path.split('/').contains('..'),
        'Invalid artifact path',
      );
      check(
        await File('$out/$path').length() == entry['bytes'],
        'Manifest size mismatch: $path',
      );
    }
    for (final name in ['vmlinux', 'System.map', '.config']) {
      await sameFile('$build/$name', '$out/$name');
    }
    await sameFile('$build/arch/x86/boot/bzImage', '$out/bzImage');
    await sameFile(profile, '$out/build-profile.conf');
    await sameFile('$build/certs/signing_key.x509', '$out/signing_key.x509');
    check(
      !await File('$out/signing_key.pem').exists() &&
          !await File('$out/certs/signing_key.pem').exists(),
      'Private signing key was exported',
    );

    final sections = await run('readelf', ['-SW', '$out/vmlinux']);
    check(
      sections.contains('__kcfi_traps') && sections.contains('.ibt_endbr_seal'),
      'Kernel ELF is missing kCFI/IBT instrumentation',
    );

    final certificate = '${temporary.path}/certificate.pem';
    await run('openssl', [
      'x509',
      '-inform',
      'DER',
      '-in',
      '$out/signing_key.x509',
      '-out',
      certificate,
    ]);
    final magic = ascii.encode('~Module signature appended~\n');
    var modules = 0;
    for (final line in await File('$build/modules.order').readAsLines()) {
      if (line.trim().isEmpty) continue;
      final module = line.trim().replaceFirst(RegExp(r'\.o$'), '.ko');
      final signed = await File('$out/modules/$module').readAsBytes();
      check(
        signed.length >= magic.length + 12 &&
            sameBytes(signed.sublist(signed.length - magic.length), magic),
        'Missing module signature: $module',
      );
      final trailer = signed.length - magic.length - 12;
      final signatureLength = ByteData.sublistView(signed)
          .getUint32(trailer + 8, Endian.big);
      final signatureStart = trailer - signatureLength;
      check(
        signatureStart > 0 && signed[trailer + 2] == 2,
        'Invalid PKCS#7 trailer: $module',
      );
      final payload = Uint8List.sublistView(signed, 0, signatureStart);
      check(
        sameBytes(payload, await File('$build/$module').readAsBytes()),
        'Signed payload differs from compiled module: $module',
      );
      final signatureFile = File('${temporary.path}/signature.der');
      final payloadFile = File('${temporary.path}/payload');
      await signatureFile.writeAsBytes(signed.sublist(signatureStart, trailer));
      await payloadFile.writeAsBytes(payload);
      // Verify the detached signature using only the exported build certificate.
      // Certificate chain validation is unnecessary for this generated key.
      await run('openssl', [
        'cms',
        '-verify',
        '-binary',
        '-inform',
        'DER',
        '-in',
        signatureFile.path,
        '-content',
        payloadFile.path,
        '-nointern',
        '-certfile',
        certificate,
        '-noverify',
        '-out',
        '/dev/null',
      ]);
      modules++;
    }
    check(
      modules > 0 && modules == metadata['signedModules'],
      'Signed module count mismatch',
    );
    stdout.writeln(
      'Verified ${metadata['package'] ?? 'custom'}: ${expected.length} overrides, ${files.length} artifacts, '
      '$modules module signatures, and kernel kCFI/IBT sections '
      '(build used ${metadata['jobs']} parallel jobs).',
    );
  } on Object catch (error) {
    stderr.writeln('Verification failed: $error');
    exitCode = 1;
  } finally {
    await temporary.delete(recursive: true);
  }
}

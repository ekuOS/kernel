import 'dart:io';

import '../../build.dart'
    show BuildFailure, Log, Runner, microvisorRepository, microvisorRevision;

String requiredEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) throw BuildFailure('Missing $name');
  return value;
}

Future<void> makeMicrovisorBundle(String bundle) async {
  final runner = Runner(Log(noColor: true));
  final scratch = await Directory.systemTemp.createTemp('ekuos-microvisor-');
  try {
    final checkout = '${scratch.path}/upstream';
    await runner.run('git', [
      'clone',
      '--no-checkout',
      '--',
      microvisorRepository,
      checkout,
    ]);
    await runner.run('git', [
      'update-ref',
      'refs/heads/ekuos-build',
      microvisorRevision,
    ], cwd: checkout);
    await runner.run('git', [
      'bundle',
      'create',
      bundle,
      'refs/heads/ekuos-build',
    ], cwd: checkout);
  } finally {
    await scratch.delete(recursive: true);
  }
}

Future<void> runContainer({required bool sign}) async {
  final workspace = requiredEnv('GITHUB_WORKSPACE');
  final temp = requiredEnv('RUNNER_TEMP');
  final output = Directory('$temp/binhost');
  final dart = await File(Platform.resolvedExecutable).resolveSymbolicLinks();
  final sdk = File(dart).parent.parent.path;
  final bundle = '$temp/microvisor.bundle';
  final args = [
    'run',
    '--rm',
    '-e',
    'BINHOST_PATH',
    if (sign) ...['-i', '--network=none'],
    '-v',
    '$workspace:/input:ro',
    '-v',
    '${output.path}:/output',
    '-v',
    '$temp/ekuos-binhost:/usr/local/bin/ekuos-binhost:ro',
    if (!sign) ...[
      '-v',
      '$sdk:/opt/dart-sdk:ro',
      '-v',
      '$bundle:/microvisor.bundle:ro',
    ],
    if (!sign && Platform.environment['EXPORT_NATIVE_PAYLOAD'] == 'true') ...[
      '-v',
      '$temp/native-input:/native-output',
    ],
    'ekuos-kernel-binhost',
    '/usr/local/bin/ekuos-binhost',
    sign ? 'sign' : 'build',
  ];
  if (!sign) {
    // The stage image only gets Git after Portage installs build dependencies.
    await makeMicrovisorBundle(bundle);
    await output.create();
    if (Platform.environment['EXPORT_NATIVE_PAYLOAD'] == 'true') {
      await Directory('$temp/native-input').create();
    }
    final process = await Process.start(
      'docker',
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
    return;
  }

  final key = Platform.environment['BINHOST_GPG_PRIVATE_KEY'] ?? '';
  if (key.isEmpty) {
    throw BuildFailure(
      'Set the BINHOST_GPG_PRIVATE_KEY Actions secret before publishing.',
    );
  }
  final passphrase = Platform.environment['BINHOST_GPG_PASSPHRASE'] ?? '';
  if (passphrase.contains('\n') || passphrase.contains('\r')) {
    throw BuildFailure('BINHOST_GPG_PASSPHRASE must be a single line.');
  }
  // Keep both secrets out of the Docker command line and child environment.
  final env = Map<String, String>.of(Platform.environment)
    ..remove('BINHOST_GPG_PRIVATE_KEY')
    ..remove('BINHOST_GPG_PASSPHRASE');
  final process = await Process.start(
    'docker',
    args,
    environment: env,
    includeParentEnvironment: false,
  );
  final logs = Future.wait([
    stdout.addStream(process.stdout),
    stderr.addStream(process.stderr),
  ]);
  process.stdin.write('$passphrase\n$key\n');
  await process.stdin.close();
  await logs;
  exitCode = await process.exitCode;
}

Future<void> main(List<String> args) async {
  try {
    switch (args.singleOrNull) {
      case 'build':
        await runContainer(sign: false);
      case 'sign':
        await runContainer(sign: true);
      default:
        throw BuildFailure('Usage: ci.dart build|sign');
    }
  } on Exception catch (error) {
    stderr.writeln('::error::$error');
    exitCode = 1;
  }
}

import 'dart:convert';
import 'dart:io';

const locales = ['en', 'ja', 'zh-CN'];
const pages = ['index', 'installation', 'boot'];

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

List<String> examples(String source) => RegExp(
  r'^```[^\n]*\n[\s\S]*?^```',
  multiLine: true,
).allMatches(source).map((match) => match[0]!).toList();

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.path;
  final base = (Platform.environment['DOCS_BASE_PATH'] ?? '').replaceFirst(
    RegExp(r'/$'),
    '',
  );
  Future<String> read(String name) => File('$root/$name').readAsString();
  final reserved = [
    'amd64',
    'apt',
    'dnf',
    'pacman',
    'signing-key.asc',
    'signing-key.gpg',
  ];
  for (final entry in reserved) {
    check(
      await FileSystemEntity.type('$root/dist/$entry') ==
          FileSystemEntityType.notFound,
      'Docs would overwrite a package repository path: $entry',
    );
  }
  check(
    (await read('dist/index.html')).contains('url=$base/en'),
    'Missing site root redirect',
  );
  final search = jsonDecode(await read('dist/api/search.json')) as Map;
  final translations = search['raw'] as Map;
  for (final locale in locales) {
    final meta = jsonDecode(await read('content/$locale/meta.json')) as Map;
    check(
      jsonEncode(meta['pages']) == jsonEncode(pages),
      '$locale: sidebar order',
    );
    check(translations.containsKey(locale), '$locale: missing search index');
    for (final page in pages) {
      final source = await read('content/$locale/$page.mdx');
      final blocks = examples(source);
      check(
        jsonEncode(blocks) ==
            jsonEncode(examples(await read('content/en/$page.mdx'))),
        '$locale/$page: command examples differ from English',
      );
      final pagePath = page == 'index' ? locale : '$locale/$page';
      final html = await read('dist/$pagePath/index.html');
      check(
        html.contains('lang="$locale"'),
        '$pagePath: wrong document language',
      );
      check(
        html.contains('id="nd-notebook-layout"'),
        '$pagePath: wrong layout',
      );
      check(html.contains('$base/api/search.json'), '$pagePath: broken search');
      check(
        RegExp(r'<figure\b').allMatches(html).length == blocks.length,
        '$pagePath: missing or duplicate highlighted code blocks',
      );
      for (final match in RegExp(
        r'<(?:a|link|script|img)\b[^>]*\b(?:href|src)="(/[^"#?]*)',
      ).allMatches(html)) {
        final href = match[1]!;
        check(href.startsWith('$base/'), '$pagePath: broken base in $href');
        final path = href.substring(base.length);
        check(
          await File('$root/dist$path').exists() ||
              await File('$root/dist$path/index.html').exists(),
          '$pagePath: unresolved asset or page $href',
        );
      }
    }
  }
  stdout.writeln('Documentation routes, examples and Pages paths verified.');
}

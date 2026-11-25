# ekuOS Kernel documentation

The Pages site uses Astro and Fumapress with English, Japanese and Simplified
Chinese content in `content/`. Keep the command examples identical across
languages.

Use Node.js 24, pnpm 10.33.0 and the Dart SDK:

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm types:check
pnpm build
dart run verify.dart
```

CI builds with `DOCS_SITE_URL=https://ekuos.github.io` and
`DOCS_BASE_PATH=/kernel`; set both for the same deployment links locally.
The Pages workflow combines `dist/` with the signed package repositories.

# Gentoo kernel binhost

See the [installation guide](https://ekuos.github.io/kernel/en/installation)
for the LLVM/systemd and multilib/systemd profiles, overlay verification and
Portage configuration.

## Publish

Before pushing, select **GitHub Actions** in **Settings → Pages** and allow
`main` in the `github-pages` environment if restricted. In **Settings →
Secrets and variables → Actions**, set `BINHOST_GPG_PRIVATE_KEY` to one
dedicated ASCII-armored OpenPGP private key. If protected, set
`BINHOST_GPG_PASSPHRASE` to its single-line passphrase.

Pushes to `main` publish after the build and install checks pass. A manual
run with `publish` unchecked only builds and tests. To change Linux versions,
update `linux.sha256` and rename both ebuilds. Source builds require Dart at
`/opt/dart-sdk`; published build inputs are in `distfiles/`.

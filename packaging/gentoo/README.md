# Gentoo kernel binhost

The binhost publishes signed `sys-kernel/linux-eku-se` and `sys-kernel/linux-eku-aa`
GPKGs for Gentoo `default/linux/amd64/23.0/no-multilib/systemd`. Both use the same
`eku.conf` as standalone builds and can be installed together.

## Configure Portage

Download `signing-key.asc` from the `sync-uri` below. Compare its full
fingerprint (`gpg --show-keys --fingerprint signing-key.asc`) with the value
provided by the maintainer **through a separate trusted channel**. If it
matches, set `fingerprint` to that value and import the key:

```sh
sudo getuto
sudo gpg --homedir /etc/portage/gnupg --import signing-key.asc
printf '%s:6:\n' "$fingerprint" |
  sudo gpg --homedir /etc/portage/gnupg --import-ownertrust
sudo gpg --homedir /etc/portage/gnupg --batch --check-trustdb
```

Download `overlay.tar.gz`, `SHA256SUMS` and `SHA256SUMS.asc` from the same publication. Verify them before extracting the overlay:

```sh
sudo gpg --homedir /etc/portage/gnupg --assert-signer "$fingerprint" \
  --verify SHA256SUMS.asc SHA256SUMS &&
  grep '  overlay\.tar\.gz$' SHA256SUMS | sha256sum --check -
```

If verification succeeds, extract `overlay.tar.gz` into a dedicated directory, such as `/var/db/repos/ekuos-kernel`. Add `/etc/portage/repos.conf/ekuos-kernel.conf`:

```ini
[ekuos-kernel]
location = /var/db/repos/ekuos-kernel
auto-sync = no
```

Add this entry to `/etc/portage/binrepos.conf` (or a file under that directory):

```ini
[ekuos-kernel]
priority = 9999
sync-uri = https://ekuos.github.io/kernel/amd64/23.0/no-multilib/systemd/
verify-signature = true
```

Add the flavor(s) you need to `/etc/portage/package.accept_keywords` (or a file inside it):

```text
sys-kernel/linux-eku-se::ekuos-kernel ~amd64
sys-kernel/linux-eku-aa::ekuos-kernel ~amd64
```

Mount `/boot` first if it is a separate filesystem. Preview the install, checking that Portage selects the `ekuos-kernel` binary:

```sh
sudo emerge --pretend --verbose --getbinpkg --usepkgonly --binpkg-respect-use=y \
  sys-kernel/linux-eku-se::ekuos-kernel
```

Replace `--pretend --verbose` with `--ask` to install, or select
`sys-kernel/linux-eku-aa::ekuos-kernel` for AppArmor. Set up the initramfs,
bootloader, UEFI Secure Boot signing and userspace LSM policy separately as
needed. Keep a known-good boot entry. Replace the verified overlay on updates;
use `--reinstall-atoms` if replacing an already installed version.

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

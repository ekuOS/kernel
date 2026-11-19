# Gentoo kernel binhost

The binhost publishes `sys-kernel/linux-eku-se` and `sys-kernel/linux-eku-aa` as signed GPKGs for Gentoo `default/linux/amd64/23.0/no-multilib/systemd` (`x86_64-pc-linux-gnu`). The initial release is Linux 7.3.5. The two flavors can be installed together; each upstream kernel version uses a separate Portage slot and distinct `/boot` and `/usr/lib/modules` paths. The published repository contains only the current version of each flavor.

CI builds with the repository's Dart builder and Clang/LLD. It verifies the configured hardening and module signatures, installs both binary packages in the disposable Gentoo container, and checks the installed kernel and module files. Only then does a fresh offline container sign the GPKGs and rebuild the `Packages` index. Neither these checks nor the Portage install boot the kernel. The OpenPGP key authenticates the packages; each kernel uses its own generated key to sign its modules.

## Before pushing

1. In **Settings → Pages → Build and deployment → Source**, select **GitHub Actions**. If the `github-pages` environment has deployment branch rules, allow `main`.
2. Generate a dedicated OpenPGP signing key and record its full fingerprint in a trusted place separate from Pages:

   ```sh
   gpg --quick-generate-key 'ekuOS kernel binhost' ed25519 sign 1y
   gpg --list-secret-keys --fingerprint 'ekuOS kernel binhost'
   ```

3. Under **Settings → Secrets and variables → Actions**, add a repository secret named `BINHOST_GPG_PRIVATE_KEY` containing **one ASCII-armored private key**. Or set `fingerprint` to the full fingerprint and run:

   ```sh
   gpg --armor --export-secret-keys "$fingerprint" |
     gh secret set BINHOST_GPG_PRIVATE_KEY --repo ekuOS/kernel
   ```

4. If the key is protected by a passphrase, add `BINHOST_GPG_PASSPHRASE` as a repository secret (one line, no line break). Leave it unset otherwise.

No Actions variables or custom deploy token are required. Pushes to `main` build and publish. Once the workflow is registered on the default branch, **Run workflow** with `publish` unchecked runs the build and install checks without secrets, including on other branches. Manual publishing is only allowed from `main`.

## Configure Portage

Use the actual Pages deployment URL plus `amd64/23.0/no-multilib/systemd/`; the default URL is shown below. Portage also needs the small matching source overlay for package metadata.

Download `signing-key.asc`, run `gpg --show-keys --fingerprint signing-key.asc`, and compare with the full fingerprint provided by the maintainer **through a separate trusted channel**. Only if it matches, set `fingerprint` to that value and configure Portage to trust the key:

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

Replace `--pretend --verbose` with `--ask` to install, or select `sys-kernel/linux-eku-aa::ekuos-kernel` for AppArmor. The package installs a versioned kernel image, config, `System.map` and signed modules. It does not generate an initramfs, change your bootloader, sign the image for UEFI Secure Boot, or install an LSM policy. Prepare those separately as needed and keep a known-good boot entry for rollback.

## Updating the published packages

When changing Linux versions, update `linux.sha256` using the upstream release checksum and rename both ebuilds to match. Update the two dated Gentoo container tags together. Run a build-only dispatch before publishing. Replace the client overlay with the verified `overlay.tar.gz` when updating, so its Manifests match the published distfiles. When rebuilding the same version, existing installs are not upgraded automatically; use `--reinstall-atoms` if you need the replacement. Reinstall the package as a unit so that the kernel and its modules use the same signing key.

The publication includes the upstream Linux tarball and exact ekuOS build inputs in `distfiles/` along with the overlay and its Portage Manifests. Building from source, unlike installing the GPKG, requires a Dart SDK at `/opt/dart-sdk`.

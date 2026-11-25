# APT, DNF and pacman

Packages are built for x86-64 from the same verified kernels as the Gentoo
binhost. APT ships AppArmor; DNF ships SELinux; pacman offers both. Install
ekuOS explicitly to use it instead of your distribution kernel; installation does **not**
erase that kernel or disable its updates. Keep a working boot entry for
rollback. These packages do not provide distribution kernel ABI compatibility,
headers, external-module signing keys, firmware, or Secure Boot signatures.

Get [`signing-key.asc`](https://ekuos.github.io/kernel/signing-key.asc) and
compare its full fingerprint with a trusted fingerprint from the maintainer
before configuring any of these repositories.

## Debian and Ubuntu (APT)

Install the keyring and set the APT source:

```sh
sudo install -Dm644 signing-key.asc /etc/apt/keyrings/ekuos.asc
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/ekuos.asc] https://ekuos.github.io/kernel/apt/ /' |
  sudo tee /etc/apt/sources.list.d/ekuos.list
sudo apt update
sudo apt install linux-image-eku
```

The AppArmor metapackage tracks the versioned
ekuOS image and can satisfy `linux-image-amd64` or `linux-image-generic`
dependencies. The image invokes standard Debian kernel hooks for initramfs
and bootloader updates.

## Fedora (DNF)

Install the verified public key at `/etc/pki/rpm-gpg/RPM-GPG-KEY-ekuos` and
create `/etc/yum.repos.d/ekuos.repo`:

```ini
[ekuos]
name=ekuOS kernels
baseurl=https://ekuos.github.io/kernel/dnf/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ekuos
```

Run `sudo dnf install kernel-eku` for SELinux. The RPM provides
the kernel capabilities and uses Fedora's install-only policy and
`kernel-install` hooks. It does not obsolete the vendor kernel. Other RPM
distributions with different boot hooks are not assumed to be compatible.

## Arch Linux (pacman)

Set `fingerprint` to the verified fingerprint, then run:

```sh
sudo pacman-key --add signing-key.asc
sudo pacman-key --lsign-key "$fingerprint"
```

Add to `/etc/pacman.conf`:

```ini
[ekuos]
SigLevel = Required
Server = https://ekuos.github.io/kernel/pacman/$arch
```

Run `sudo pacman -Syu linux-eku-se` (or `linux-eku-aa`). The package uses the
standard `mkinitcpio` hooks; configure your bootloader to use the resulting
image and initramfs if it does not pick them up automatically.

Before rebooting on any distribution, check that the new initramfs and boot
entry exist, and that the appropriate userspace security policy is installed.
Mount `/boot` and the EFI System Partition as required by your boot setup.

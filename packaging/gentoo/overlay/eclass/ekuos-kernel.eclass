# @ECLASS: ekuos-kernel.eclass
# @SUPPORTED_EAPIS: 8

inherit multiprocessing

HOMEPAGE="https://github.com/ekuOS/kernel"
SRC_URI="
	https://cdn.kernel.org/pub/linux/kernel/v$(ver_cut 1).x/linux-${PV}.tar.xz
	https://ekuos.github.io/kernel/amd64/23.0/llvm/systemd/distfiles/ekuos-kernel-${PVR}.tar.gz
"
S="${WORKDIR}/linux-${PV}"
LICENSE="GPL-2"
SLOT="${PV}"
KEYWORDS="~amd64"
# Stripping a kernel module after signing invalidates its signature.
RESTRICT="mirror strip"
QA_PREBUILT="usr/lib/modules/*"
BDEPEND="
	>=llvm-core/clang-22
	>=llvm-core/lld-22
	>=llvm-core/llvm-22
	app-alternatives/bc
	dev-libs/elfutils
	dev-libs/openssl
	dev-vcs/git
	sys-apps/kmod
	sys-devel/bison
	sys-devel/flex
	virtual/pkgconfig
"
RDEPEND="sys-apps/kmod"

ekuos-kernel_src_compile() {
	local flavor=${PN#linux-eku-}
	local tooling="${WORKDIR}/ekuos-kernel-${PVR}"
	local dart=/opt/dart-sdk/bin/dart
	[[ -x ${dart} ]] || die "Install the Dart SDK at /opt/dart-sdk (source builds only)"
	# The builder owns kernel configuration and flags. Do not inherit make
	# settings that could override its Kbuild configuration or parallelism.
	unset KCONFIG_CONFIG MAKEFLAGS
	# Use the same checked-in eku.conf as a standalone build, then apply the
	# selected flavor's overrides.
	"${dart}" "${tooling}/build.dart" --arch x86_64 --source "${S}" \
		--flavor "${flavor}" --config "${tooling}/eku.conf" \
		--patches "${tooling}/patches" --output "${WORKDIR}/build" \
		--artifacts "${WORKDIR}/out" --jobs "$(makeopts_jobs)" || die
	"${dart}" "${tooling}/test/verify_kernel.dart" \
		"${WORKDIR}/build/${PN}" "${WORKDIR}/out/${PN}" || die
}

ekuos-kernel_src_install() {
	local build="${WORKDIR}/build/${PN}" out="${WORKDIR}/out/${PN}"
	local release module moddir
	read -r release < "${out}/kernel.release" || die
	[[ ${release} == "${PV}-eku-${PN#linux-eku-}" ]] || die "Unexpected kernel release: ${release}"
	moddir="${ED}/usr/lib/modules/${release}"
	# Kbuild lays out the modules and their metadata, and signs the modules
	# using the same build key. No build tree or private key is installed.
	emake O="${build}" ARCH=x86_64 LLVM=1 MODLIB="${moddir}" \
		DEPMOD=true modules_install
	rm "${moddir}/build" || die
	while IFS= read -r module; do
		[[ -n ${module} ]] || continue
		module=${module%.o}.ko
		cmp "${moddir}/kernel/${module}" "${out}/modules/${module}" || die
	done < "${build}/modules.order"
	depmod -b "${ED}" -m /usr/lib/modules -F "${out}/System.map" "${release}" || die

	insinto /boot
	newins "${out}/bzImage" "vmlinuz-${release}"
	newins "${out}/System.map" "System.map-${release}"
	newins "${out}/.config" "config-${release}"
	dodoc "${out}/build-profile.conf" "${out}/build-info.json" "${out}/signing_key.x509"
}

EXPORT_FUNCTIONS src_compile src_install

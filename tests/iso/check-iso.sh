#!/usr/bin/env bash
# Structural checks of a built Mainuan ISO (no boot needed).
#
#   tests/iso/check-iso.sh <image.iso> [workdir]
#
# Needs: xorriso, squashfs-tools (unsquashfs), coreutils, file.
# Exit status 0 only when every check passes.
set -uo pipefail

iso="${1:?usage: check-iso.sh <image.iso> [workdir]}"
work="${2:-$(mktemp -d)}"
mkdir -p "${work}"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@" > /dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }

# 1. Boot records: BIOS (El Torito) and UEFI (EFI system partition image).
report="$(xorriso -indev "${iso}" -report_el_torito plain 2>/dev/null)"
grep -q 'El Torito boot img :   1  BIOS' <<< "${report}" && pass "El Torito BIOS boot image" || fail "El Torito BIOS boot image"
grep -q 'El Torito boot img :   2  UEFI' <<< "${report}" && pass "El Torito UEFI boot image" || fail "El Torito UEFI boot image"
xorriso -indev "${iso}" -report_system_area plain 2>/dev/null | grep -q 'MBR partition' \
  && pass "hybrid MBR (USB boot)" || fail "hybrid MBR (USB boot)"

# 2. Files needed by GRUB, casper and the installer.
listing="$(xorriso -indev "${iso}" -find / -type f 2>/dev/null | tr -d "'")"
for path in /casper/vmlinuz /casper/initrd /casper/filesystem.squashfs /casper/filesystem.manifest \
            /EFI/BOOT/BOOTX64.efi /boot/grub/bios.img /isolinux/grub.cfg /.disk/info /md5sum.txt /Mainuan; do
  grep -qx "${path}" <<< "${listing}" && pass "file ${path}" || fail "file ${path}"
done

# 3. Extract the image and verify md5sum.txt (every file of the ISO tree).
extract="${work}/tree"
rm -rf "${extract}"
mkdir -p "${extract}"
if osirrox -indev "${iso}" -extract / "${extract}" > /dev/null 2>&1; then
  chmod -R u+w "${extract}"
  (cd "${extract}" && md5sum --check --quiet md5sum.txt) && pass "md5sum.txt matches" || fail "md5sum.txt matches"
else
  fail "extract ISO tree"
fi

cfg="${extract}/isolinux/grub.cfg"
grep -q 'boot=casper' "${cfg}" && pass "GRUB entry boots casper" || fail "GRUB entry boots casper"
grep -q 'serial --unit=0' "${cfg}" && pass "GRUB serial mirror" || fail "GRUB serial mirror"
file -b "${extract}/casper/vmlinuz" | grep -q 'Linux kernel x86 boot executable' \
  && pass "casper/vmlinuz is a Linux kernel" || fail "casper/vmlinuz is a Linux kernel"
kernel_version="$(file -b "${extract}/casper/vmlinuz" | sed -n 's/.*version \([^ ]*\).*/\1/p')"

# 4. Root filesystem contents.
squash="${extract}/casper/filesystem.squashfs"
sq() { unsquashfs -cat "${squash}" "$1" 2>/dev/null; }

os_release="$(sq usr/lib/os-release)"
grep -qx 'NAME="Mainuan"' <<< "${os_release}" && pass "os-release NAME=Mainuan" || fail "os-release NAME=Mainuan"
grep -qx 'ID=mainuan' <<< "${os_release}" && pass "os-release ID=mainuan" || fail "os-release ID=mainuan"
grep -qx 'UBUNTU_CODENAME=resolute' <<< "${os_release}" && pass "os-release based on resolute" || fail "os-release based on resolute"

status="$(sq var/lib/dpkg/status)"
installed() { awk -v p="$1" '$0=="Package: "p{f=1;next} /^Package: /{f=0} f&&/^Status: install ok installed/{ok=1} END{exit !ok}' <<< "${status}"; }
for package in casper calamares sddm plasma-workspace kwin-wayland plasma-desktop grub-efi-amd64-signed shim-signed \
               mainuan-welcome deb-manager-gui instalador-de-fontes system-upgrade mainuan-gestao-drivers \
               painel-de-controle mainuan-grub-editor mainuan-flatpak-install-gui mainuan-install-appimage \
               mainuan-atualizador-recursos pkg-manager-gui onlyoffice-desktopeditors firefox \
               mainuan-wallpapers mainuan-icon-themes mainuan-plasma-themes mainuan-desktop-defaults \
               mainuan-user-avatar \
               language-pack-pt; do
  installed "${package}" && pass "package ${package} installed" || fail "package ${package} installed"
done
installed "linux-image-${kernel_version}" && pass "kernel ${kernel_version} matches the installed linux-image" \
  || fail "kernel ${kernel_version} matches the installed linux-image"

grep -q '^Architecture-Variant: amd64v[2-9]' <<< "${status}" \
  && fail "x86-64 baseline (no amd64v3 package variants)" || pass "x86-64 baseline (no amd64v3 package variants)"

contents="$(unsquashfs -lc "${squash}" 2>/dev/null | sed 's|^squashfs-root||')"
for path in /etc/calamares/settings.conf /etc/calamares/branding/vendor/branding.desc \
            /etc/xdg/kcm-about-distrorc /usr/share/plasma/avatars/logoMainuan.png; do
  grep -qx "${path}" <<< "${contents}" && pass "rootfs ${path}" || fail "rootfs ${path}"
done
for path in /mita-i.debian-packages /usr/lib/electron; do
  grep -q "^${path}" <<< "${contents}" && fail "no build leftover ${path}" || pass "no build leftover ${path}"
done
grep -q '^/tmp/.' <<< "${contents}" && fail "empty /tmp" || pass "empty /tmp"
grep -q '^/etc/apt/sources.list.d/cdrom.sources$' <<< "${contents}" && fail "no cdrom APT source" || pass "no cdrom APT source"

branding="$(sq etc/calamares/branding/vendor/branding.desc)"
grep -q 'productName: *Mainuan' <<< "${branding}" && pass "Calamares branding" || fail "Calamares branding"

echo
if [ "${failures}" -eq 0 ]; then
  echo "All ISO checks passed."
else
  echo "${failures} ISO check(s) failed."
fi
[ -n "${2:-}" ] || rm -rf "${work}"
exit $((failures > 0))

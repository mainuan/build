#!/usr/bin/env bash
# Structural checks of a built Mainuan ISO (no boot needed).
#
#   tests/iso/check-iso.sh <image.iso> [workdir]
#
# Needs: xorriso, squashfs-tools (unsquashfs), coreutils, file, apt (apt-get check), dpkg (version comparison).
# Exit status 0 only when every check passes.
set -uo pipefail

iso="${1:?usage: check-iso.sh <image.iso> [workdir]}"
work="${2:-$(mktemp -d)}"
mkdir -p "${work}" || { echo "cannot create work directory ${work}"; exit 2; }
[ -w "${work}" ] || { echo "work directory ${work} is not writable"; exit 2; }

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
            /EFI/BOOT/BOOTX64.efi /boot/grub/bios.img /boot/grub/unicode.pf2 /isolinux/grub.cfg /.disk/info /md5sum.txt /Mainuan; do
  grep -qx "${path}" <<< "${listing}" && pass "file ${path}" || fail "file ${path}"
done

# 3. Extract the image and verify md5sum.txt (every file of the ISO tree).
extract="${work}/tree"
rm -rf "${extract}"
mkdir -p "${extract}"
if osirrox -indev "${iso}" -extract / "${extract}" > "${work}/osirrox.log" 2>&1; then
  chmod -R u+w "${extract}"
  (cd "${extract}" && md5sum --check --quiet md5sum.txt) && pass "md5sum.txt matches" || fail "md5sum.txt matches"
else
  fail "extract ISO tree"
  tail -20 "${work}/osirrox.log"
fi

# 3b. UEFI Secure Boot chain inside the EFI boot image.
esp="${extract}/EFI/BOOT/BOOTX64.efi"
if [ -f "${esp}" ] && command -v mcopy > /dev/null; then
  for efi in bootx64.efi grubx64.efi mmx64.efi; do
    mcopy -n -i "${esp}" "::efi/boot/${efi}" "${work}/${efi}" 2> /dev/null && pass "EFI image has ${efi}" || fail "EFI image has ${efi}"
  done
  grep -aq 'Microsoft Corporation UEFI CA' "${work}/bootx64.efi" 2> /dev/null \
    && pass "shim signed by the Microsoft UEFI CA" || fail "shim signed by the Microsoft UEFI CA"
  grep -aq 'Canonical' "${work}/grubx64.efi" 2> /dev/null \
    && pass "GRUB signed by Canonical" || fail "GRUB signed by Canonical"
else
  fail "EFI boot image readable (mtools)"
fi
[ -f "${extract}/boot/grub/grub.cfg" ] && pass "file /boot/grub/grub.cfg (signed GRUB)" || fail "file /boot/grub/grub.cfg (signed GRUB)"

cfg="${extract}/isolinux/grub.cfg"
grep -q 'boot=casper' "${cfg}" && pass "GRUB entry boots casper" || fail "GRUB entry boots casper"
grep -q 'serial --unit=0' "${cfg}" && pass "GRUB serial mirror" || fail "GRUB serial mirror"
# Live menu with the Mainuan GRUB theme (fonts loaded before "set theme").
grep -q 'set theme=/boot/grub/themes/mainuan/theme.txt' "${cfg}" && pass "Live GRUB uses the Mainuan theme" \
  || fail "Live GRUB uses the Mainuan theme"
theme_ok=1
for font in $(grep -o '"Noto Sans[^"]*"' "${extract}/boot/grub/themes/mainuan/theme.txt" 2>/dev/null | sort -u | tr -d '"' | tr 'A-Z ' 'a-z_'); do
  [ -s "${extract}/boot/grub/themes/mainuan/${font}.pf2" ] && grep -q "loadfont /boot/grub/themes/mainuan/${font}.pf2" "${cfg}" || theme_ok=0
done
[ -s "${extract}/boot/grub/themes/mainuan/theme.txt" ] && [ "${theme_ok}" = 1 ] \
  && pass "Live GRUB theme fonts present and loaded" || fail "Live GRUB theme fonts present and loaded"
grep -q -- '--class mainuan' "${cfg}" && pass "Live GRUB entries carry the mainuan class (icon)" \
  || fail "Live GRUB entries carry the mainuan class (icon)"
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
# The identity files are diverted, so an update of base-files or
# kubuntu-settings-desktop does not bring "Ubuntu"/"Kubuntu" back.
diversions="$(sq var/lib/dpkg/diversions)"
undiverted=""
for f in /etc/xdg/kcm-about-distrorc /etc/issue /etc/issue.net /etc/lsb-release /usr/lib/os-release; do
  grep -qxF -A2 "${f}" <<< "${diversions}" && grep -A2 -xF "${f}" <<< "${diversions}" | grep -qxF "${f}.distrib" \
    || undiverted+=" ${f}"
done
[ -z "${undiverted}" ] && pass "identity files diverted (base-files updates keep Mainuan)" \
  || fail "identity files not diverted:${undiverted}"
# The "Next" wallpaper links (symlinks.lst) are diverted and their package
# copies path-excluded, so a plasma-workspace-wallpapers update keeps them.
next=/usr/share/wallpapers/Next/contents/images/5120x2880.png
next_link="$(unsquashfs -lls "${squash}" "${next#/}" 2>/dev/null | grep -o '\-> .*')"
symlink_cfg="$(sq etc/dpkg/dpkg.cfg.d/mainuan-symlinks)"
[[ "${next_link}" == "-> /usr/share/wallpapers/01ciano.png" ]] \
  && grep -A1 -xF "${next}" <<< "${diversions}" | grep -qxF "${next}.distrib" \
  && grep -qxF "path-exclude=${next}.distrib" <<< "${symlink_cfg}" \
  && pass "Next wallpaper link diverted (package updates keep the Mainuan wallpaper)" \
  || fail "Next wallpaper link diverted: ${next_link:-no link}"

status="$(sq var/lib/dpkg/status)"
installed() { awk -v p="$1" '$0=="Package: "p{f=1;next} /^Package: /{f=0} f&&/^Status: install ok installed/{ok=1} END{exit !ok}' <<< "${status}"; }
for package in casper calamares sddm plasma-workspace kwin-wayland plasma-desktop grub-efi-amd64-signed shim-signed \
               mainuan-welcome deb-manager-gui instalador-de-fontes system-upgrade mainuan-gestao-drivers \
               painel-de-controle mainuan-flatpak-install-gui mainuan-install-appimage \
               mainuan-atualizador-recursos pkg-manager-gui onlyoffice-desktopeditors firefox \
               mainuan-wallpapers mainuan-icon-themes mainuan-plasma-themes mainuan-desktop-defaults mainuan-grub-theme mainuan-plasma-splash \
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

context="$(sq etc/calamares/modules/before_bootloader_context.conf)"
grep -q 'cdrom' <<< "${context}" && fail "Calamares UEFI step does not need a repository on the medium" \
  || pass "Calamares UEFI step does not need a repository on the medium"
locale_conf="$(sq etc/calamares/modules/locale.conf)"
grep -qx 'zone: "Sao_Paulo"' <<< "${locale_conf}" && pass "Calamares default zone Sao_Paulo" || fail "Calamares default zone Sao_Paulo"

# Mainuan identity on the login screen and the boot splash.
sddm_conf="$(sq etc/sddm.conf.d/30-mainuan.conf)"
grep -qx 'Current=breeze' <<< "${sddm_conf}" && pass "SDDM theme Breeze (Mainuan)" || fail "SDDM theme Breeze (Mainuan)"
grep -qx 'background=/usr/share/wallpapers/01ciano.png' <<< "$(sq usr/share/sddm/themes/breeze/theme.conf.user)" \
  && pass "SDDM Mainuan background" || fail "SDDM Mainuan background"
plymouth_default="$(unsquashfs -lls "${squash}" etc/alternatives/default.plymouth 2>/dev/null | grep -o '\-> .*')"
grep -q 'themes/mainuan/mainuan.plymouth' <<< "${plymouth_default}" && pass "Plymouth default theme mainuan" \
  || fail "Plymouth default theme mainuan (${plymouth_default})"

text_default="$(unsquashfs -lls "${squash}" etc/alternatives/text.plymouth 2>/dev/null | grep -o '\-> .*')"
grep -q 'mainuan-text' <<< "${text_default}" && pass "Plymouth text theme mainuan-text" || fail "Plymouth text theme mainuan-text (${text_default})"
anim="$(unsquashfs -lls "${squash}" usr/share/plymouth/themes/mainuan/throbber-0001.png 2>/dev/null | tail -1)"
[[ "${anim}" == -* ]] && pass "Plymouth animation is a regular file (reaches the initramfs)" \
  || fail "Plymouth animation is a regular file (reaches the initramfs)"
wm_mainuan="$(sq usr/share/plymouth/themes/mainuan/watermark.png | sha256sum | cut -d' ' -f1)"
wm_spinner="$(sq usr/share/plymouth/themes/spinner/watermark.png | sha256sum | cut -d' ' -f1)"
[[ -n "$(sq usr/share/plymouth/themes/mainuan/watermark.png | head -c 8)" && "${wm_mainuan}" != "${wm_spinner}" ]] \
  && pass "Plymouth watermark is the Mainuan logo (not Spinner/Ubuntu)" \
  || fail "Plymouth watermark is the Mainuan logo (not Spinner/Ubuntu)"
face="$(unsquashfs -lls "${squash}" usr/share/sddm/themes/breeze/faces/.face.icon 2>/dev/null | grep -o '\-> .*')"
grep -q 'plasma/avatars/kubuntu-bug.png' <<< "${face}" && pass "SDDM default face is the Mainuan logo" \
  || fail "SDDM default face is the Mainuan logo (${face})"

throbbers="$(unsquashfs -l "${squash}" 'usr/share/plymouth/themes/mainuan/' 2>/dev/null | grep -c 'mainuan/throbber-[0-9]*\.png$')"
[ "${throbbers}" = 48 ] && pass "Plymouth ring animation (48 frames)" || fail "Plymouth ring animation (48 frames, found ${throbbers})"
grep -qx 'ExecStart=-/usr/bin/plymouth quit --retain-splash' \
  <<< "$(sq usr/lib/systemd/system/plymouth-quit.service.d/50-mainuan-retain-splash.conf)" \
  && pass "Plymouth keeps the last frame until SDDM" || fail "Plymouth keeps the last frame until SDDM"
# Installed system: GRUB theme (copied to /boot) and its options.
[ -n "$(sq boot/grub/themes/mainuan/theme.txt)" ] && pass "GRUB theme in /boot/grub/themes/mainuan" \
  || fail "GRUB theme in /boot/grub/themes/mainuan"
grep -q 'GRUB_THEME=/boot/grub/themes/mainuan/theme.txt' <<< "$(sq etc/default/grub.d/60-mainuan-theme.cfg)" \
  && pass "GRUB theme enabled in /etc/default/grub.d" || fail "GRUB theme enabled in /etc/default/grub.d"
# Mainuan global theme with the Plasma splash, the system default.
[ -n "$(sq usr/share/plasma/look-and-feel/org.mainuan.desktop/contents/splash/Splash.qml)" ] \
  && pass "Plasma splash (global theme org.mainuan.desktop)" || fail "Plasma splash (global theme org.mainuan.desktop)"
grep -qx 'LookAndFeelPackage=org.mainuan.desktop' <<< "$(sq etc/xdg/kdeglobals)" \
  && pass "Mainuan global theme is the system default" || fail "Mainuan global theme is the system default"

# --- Clean image (data/base/exclude-paths.lst) -------------------------------
listing_sq="$(unsquashfs -l "${squash}" 2>/dev/null | sed 's|^squashfs-root||')"
excluded_left=""
for path in $(sed 's|#.*||' "$(dirname "$0")/../../data/base/exclude-paths.lst" | xargs); do
  grep -qx "${path}" <<< "${listing_sq}" && excluded_left+=" ${path}"
done
[ -z "${excluded_left}" ] && pass "Excluded wallpapers, styles, global themes and color schemes absent" \
  || fail "Excluded paths still present:${excluded_left}"
grep -q '^path-exclude=/usr/share/wallpapers/Altai$' <<< "$(sq etc/dpkg/dpkg.cfg.d/mainuan-exclude-paths)" \
  && pass "dpkg path-exclude keeps them out on updates" || fail "dpkg path-exclude keeps them out on updates"
[ -n "$(sq usr/share/plasma/desktoptheme/default/metadata.json)" ] \
  && pass "Default Plasma style (fallback) kept" || fail "Default Plasma style (fallback) kept"
grep -qx '/etc/apt/sources.list.bak' <<< "${listing_sq}" && fail "No /etc/apt/sources.list.bak" || pass "No /etc/apt/sources.list.bak"

# --- Menu ---------------------------------------------------------------------
grep -qx 'NoDisplay=true' <<< "$(sq usr/local/share/applications/org.kubuntu.driver-manager.desktop)" \
  && pass "Kubuntu Driver Manager hidden from the menu" || fail "Kubuntu Driver Manager hidden from the menu"
ark="$(sq usr/local/share/applications/org.kde.ark.desktop)"
grep -qx 'Name\[en\]=Archive Manager' <<< "${ark}" && grep -qx 'Name\[es\]=Gestor de archivos comprimidos' <<< "${ark}" \
  && pass "Reorganized menu names translated (reorganize-apps.yaml)" \
  || fail "Reorganized menu names translated (reorganize-apps.yaml)"
# Languages without a variant get the app's own translation, never Portuguese:
# base Name in English, Name[it] from KDE, no Name[pt_BR] hiding Name[pt].
desktop_entry() { awk '/^\[Desktop Entry\]/{s=1;next} /^\[/{s=0} s' <<< "$1"; }
ark_main="$(desktop_entry "${ark}")"
spectacle_main="$(desktop_entry "$(sq usr/local/share/applications/org.kde.spectacle.desktop)")"
! grep -qx 'Name=Compactador de arquivos' <<< "${ark_main}" \
  && grep -q '^Name\[it\]=' <<< "${ark_main}" && ! grep -qx 'Name\[it\]=Compactador de arquivos' <<< "${ark_main}" \
  && ! grep -q '^Name\[pt_BR\]=' <<< "${ark_main}" && grep -qx 'Name\[pt\]=Compactador de arquivos' <<< "${ark_main}" \
  && grep -qx 'Name\[en\]=Screenshot' <<< "${spectacle_main}" && ! grep -qx 'Name=Captura de tela' <<< "${spectacle_main}" \
  && pass "Menu names in languages without a variant are not Portuguese" \
  || fail "Menu names in languages without a variant are not Portuguese"
installer="$(sq usr/share/applications/kubuntu-calamares.desktop)"
grep -qx 'Name=Install System' <<< "${installer}" && grep -qx 'Name\[pt_BR\]=Instalar o Sistema' <<< "${installer}" \
  && pass "Installer launcher translated" || fail "Installer launcher translated"

# --- Panel: Mainuan logo on the launcher, Laetum Control Center ------------------
grep -qx '/usr/share/icons/hicolor/scalable/apps/mainuan.svg' <<< "${listing_sq}" \
  && pass "Mainuan icon in the hicolor theme" || fail "Mainuan icon in the hicolor theme"
applets="$(sq etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc)"
grep -qx 'icon=mainuan' <<< "${applets}" && pass "Application launcher uses the Mainuan logo" \
  || fail "Application launcher uses the Mainuan logo"
grep -qx 'plugin=local.laetum.controlcenter' <<< "${applets}" && ! grep -q 'KdeControlStation' <<< "${applets}" \
  && pass "Panel uses Laetum Control Center" || fail "Panel uses Laetum Control Center"

# --- Translations of the Mainuan applications -------------------------------------
missing_mo=""
for domain in mainuan-welcome mainuan-atualizador-recursos mainuan-gestao-drivers system-upgrade painel-controle \
              mainuan-flatpak-install-gui mainuan-install-appimage pkg-manager-gui deb-manager-gui instalador-de-fontes; do
  grep -q "/usr/share/locale/pt_BR/LC_MESSAGES/${domain}.mo$\|/LC_MESSAGES/${domain}.mo$" <<< "${listing_sq}" || missing_mo+=" ${domain}"
done
[ -z "${missing_mo}" ] && pass "Mainuan applications ship their catalogs" || fail "Catalogs missing:${missing_mo}"

# --- Calamares ----------------------------------------------------------------------
grep -q '^    - name: "Mainuan"$' <<< "$(sq etc/calamares/modules/partition.conf)" && \
  ! grep -q 'System_Root' <<< "$(sq etc/calamares/modules/partition.conf)" \
  && pass "Calamares root partition named Mainuan" || fail "Calamares root partition named Mainuan"
grep -q 'plasma-discover-notifier' <<< "$(sq etc/calamares/modules/packages.conf)" \
  && pass "Calamares removes plasma-discover-notifier from the target" \
  || fail "Calamares removes plasma-discover-notifier from the target"
# Removed from the image by remove-base-packages.lst; Discover itself stays.
settings="$(sq etc/calamares/settings.conf)"
grep -qx '  - shellprocess@sync' <<< "$settings" \
  && grep -A1 -x '  - shellprocess@sync' <<< "$settings" | grep -qx '  - umount' \
  && grep -q 'sync' <<< "$(sq etc/calamares/modules/shellprocess_sync.conf)" \
  && pass "Calamares flushes the target before unmounting it" \
  || fail "Calamares flushes the target before unmounting it"

! installed plasma-discover-notifier && installed plasma-discover \
  && pass "plasma-discover-notifier removed, Discover kept" || fail "plasma-discover-notifier removed, Discover kept"
# --- Packages: dependencies and firmware updates ------------------------------
# Every package fully installed, and APT finds every dependency satisfied
# (apt-get check on the image's dpkg status, offline, without the host's
# packages or sources).
unfinished="$(awk '/^Package: /{p=$2} /^Status: /{if ($4 != "installed" && $4 != "config-files" && $4 != "not-installed") print p" ("$4")"}' <<< "${status}" | xargs)"
[ -z "${unfinished}" ] && pass "No half-installed or unconfigured package" || fail "Packages not fully installed: ${unfinished}"
aptroot="${work}/apt"
rm -rf "${aptroot}"
mkdir -p "${aptroot}/lists/partial" "${aptroot}/cache/archives/partial" "${aptroot}/etc/apt.conf.d" \
         "${aptroot}/etc/preferences.d" "${aptroot}/etc/sources.list.d"
printf '%s\n' "${status}" > "${aptroot}/status"
apt-get -o Dir::State::status="${aptroot}/status" -o Dir::State::Lists="${aptroot}/lists" \
        -o Dir::Cache="${aptroot}/cache" -o Dir::Etc="${aptroot}/etc" -o Dir::Etc::SourceList=/dev/null \
        -o Dir::Etc::SourceParts="${aptroot}/etc/sources.list.d" -o APT::Architecture=amd64 \
        -o APT::Architectures=amd64 -o Debug::NoLocking=1 check > "${work}/apt-check.log" 2>&1 \
  && pass "apt-get check: dependencies of the installed packages satisfied" \
  || { fail "apt-get check: dependencies of the installed packages satisfied"; tail -20 "${work}/apt-check.log"; }
# libflashrom1, libftdi1-2 and libjcat1 were left behind by fwupd 2.1.1 of the
# base image; fwupd 2.1.6 uses none of them (data/base/remove-orphan-packages.lst).
# Firmware updates stay: fwupd, its refresh timer and the Discover backend.
orphans_left=""
for package in libflashrom1 libftdi1-2 libjcat1; do
  installed "${package}" && orphans_left+=" ${package}"
done
[ -z "${orphans_left}" ] && pass "libflashrom1, libftdi1-2 and libjcat1 removed" \
  || fail "Orphan libraries still installed:${orphans_left}"
fwupd_missing=""
for package in fwupd libfwupd3 fwupd-signed plasma-discover plasma-discover-backend-fwupd; do
  installed "${package}" || fwupd_missing+=" ${package}"
done
[ -z "${fwupd_missing}" ] && pass "fwupd, fwupd-signed and the Discover fwupd backend kept" \
  || fail "Firmware update packages missing:${fwupd_missing}"
grep -qx '/etc/systemd/system/timers.target.wants/fwupd-refresh.timer' <<< "${listing_sq}" \
  && grep -qx '/usr/lib/systemd/system/fwupd.service' <<< "${listing_sq}" \
  && pass "fwupd.service present, fwupd-refresh.timer enabled" \
  || fail "fwupd.service present, fwupd-refresh.timer enabled"

grep -q 'qsTr' <<< "$(sq etc/calamares/branding/vendor/show.qml)" \
  && pass "Calamares slideshow with translatable text" || fail "Calamares slideshow with translatable text"
qm_count="$(grep -c '^/etc/calamares/branding/vendor/lang/calamares-vendor_.*\.qm$' <<< "${listing_sq}")"
[ "${qm_count}" -ge 33 ] && pass "Calamares slideshow translations (${qm_count})" \
  || fail "Calamares slideshow translations (${qm_count})"
# Catalogs with the lost %N placeholders fixed, read by Calamares before the
# copies built into it (pt_BR summary said "Configure timezone para 1").
sq usr/share/calamares/lang/calamares_pt_BR.qm \
  | python3 -c "import sys; d=sys.stdin.buffer.read(); sys.exit(not ('Definir o fuso horário para %1.'.encode('utf-16-be') in d and 'Configure timezone para 1'.encode('utf-16-be') not in d))" \
  && pass "Calamares pt_BR translation fixed (time zone, keyboard)" \
  || fail "Calamares pt_BR translation fixed (time zone, keyboard)"

branding="$(sq etc/calamares/branding/vendor/branding.desc)"
grep -q 'productName: *Mainuan' <<< "${branding}" && pass "Calamares branding" || fail "Calamares branding"

# ---- UX mission (docs/ux) regression gates ----
# Control Center: the grey header band is off by default.
laetum_xml="$(sq usr/share/plasma/plasmoids/local.laetum.controlcenter/contents/config/main.xml)"
python3 -c "import re,sys; t=sys.stdin.read(); sys.exit(not re.search(r'name=\"showHeader\" type=\"Bool\">\s*<default>false</default>', t))" <<< "${laetum_xml}" \
  && pass "Laetum Control Center opens without the header (showHeader=false)" \
  || fail "Laetum Control Center opens without the header (showHeader=false)"
# Tray icons: the panel gear follows the colour scheme (no fixed grey).
gear="$(sq usr/share/icons/kora-cyan/apps/symbolic/preferences-system-symbolic.svg)"
grep -Eq 'fill(:|=")currentColor' <<< "${gear}" && grep -q 'ColorScheme-Text' <<< "${gear}" \
  && ! grep -Eq 'fill:rgb\(2[0-9][0-9],' <<< "${gear}" \
  && pass "kora-cyan symbolic gear is recolourable" || fail "kora-cyan symbolic gear is recolourable"
# News: an empty or disabled announcement never opens a window; 0.4.0 or later.
version_of() { awk -v p="$1" '$0=="Package: "p{f=1;next} /^Package: /{f=0} f&&/^Version: /{print $2; exit}' <<< "${status}"; }
at_least() { local v; v="$(version_of "$1")"; [ -n "${v}" ] && dpkg --compare-versions "${v}" ge "$2"; }
installed mainuan-atualizador-recursos && at_least mainuan-atualizador-recursos 0.4.0 \
  && pass "Feature updater with explicit announcements (>= 0.4.0)" \
  || fail "Feature updater with explicit announcements (>= 0.4.0)"
# Identity: official files, restore service enabled, /etc/skel/.face regular.
for path in /usr/share/mainuan/identity/manifest.json /usr/share/mainuan/identity/checksums.sha256 \
            /usr/share/mainuan/identity/avatars/cyan.svg /usr/share/mainuan/identity/logo/mainuan-logo.svg \
            /usr/libexec/mainuan-identity/mainuan-identity-restore; do
  grep -qxF "${path}" <<< "${listing_sq}" || fail "missing ${path}"
done
grep -qx '/etc/systemd/system/multi-user.target.wants/mainuan-identity-restore.service' <<< "${listing_sq}" \
  && pass "mainuan-identity-restore.service enabled" || fail "mainuan-identity-restore.service enabled"
skel_face="$(unsquashfs -lls "${squash}" etc/skel/.face 2>/dev/null | grep 'etc/skel/.face$')"
[[ "${skel_face}" == -rw-r--r--\ root/root* ]] \
  && pass "/etc/skel/.face is a regular root file (Welcome accepts it)" \
  || fail "/etc/skel/.face is a regular root file: ${skel_face:-missing}"
# Welcome: the Mainuan logo on every layout launcher and official links (1.1.1+).
installed mainuan-welcome && at_least mainuan-welcome 1.1.2 \
  && pass "Mainuan Welcome >= 1.1.2" || fail "Mainuan Welcome >= 1.1.2"
grep -qx '/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/mainuan-launcher-icon-2.js' <<< "${listing_sq}" \
  && pass "launcher logo update script for existing accounts" || fail "launcher logo update script for existing accounts"

echo
if [ "${failures}" -eq 0 ]; then
  echo "All ISO checks passed."
else
  echo "${failures} ISO check(s) failed."
fi
[ -n "${2:-}" ] || rm -rf "${work}"
exit $((failures > 0))

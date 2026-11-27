#!/usr/bin/env bash
#
#  Build process functions
#
#-----------------------------------------------------------------------------------------------------------------------------------------
#
#  To extend the script place function on appropriate place based on the following boilerplate:
#
#  function function-template {
#    show-header "Name of step"
#    # Function body here, ${variant_data_dir} holds the variant
#    # lists disrectory
#  }
#
#
#  Note: Functions are executed in the order of declaration.
#
#-----------------------------------------------------------------------------------------------------------------------------------------
function check-build-dependencies {
  show-header "Check for build dependencies..."

  declare -A commandMap=(
    [mmd]="dosfstools"
    [mcopy]="mtools"
    [grub-mkstandalone]="grub-common"
    [osirrox]="xorriso"
    [unsquashfs]="squashfs-tools"
    [wget]="wget"
    [rsync]="rsync"
    [git]="git"
    [bsdtar]="libarchive-tools"
    [mksquashfs]="squashfs-tools"
    [gpg]="gnupg"
    [gpgv]="gpgv"
    [sha256sum]="coreutils"
  )



  local missing=()

  for cmd in "${!commandMap[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=(${commandMap[${cmd}]})
  done

  for pkg in grub-pc grub-efi-amd64-bin; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=(${pkg})
    fi
  done

  missing=($(printf "%s\n" "${missing[@]}" | sort -u))

  if [ ${#missing[@]} -gt 0 ]; then
    apt update
    apt install "${missing[@]}" -y
    return
  fi
  echo "All build dependencies are already installed."
}

function download-image {
    show-header "Download and verify the base ISO image"

    mkdir -p base iso
    : > iso/components.sha256
    local iso="base/${flavour}.iso"

    if [ -f "${url}" ]; then
      cp "${url}" "${iso}"
    elif [ ! -f "${iso}" ] || ! echo "${base_iso_sha256}  ${iso}" | sha256sum --check --status; then
      local release_dir="${base_iso_url%/*}"

      echo "  - Verifying the signature of ${release_dir}/SHA256SUMS"
      rm -f base/SHA256SUMS base/SHA256SUMS.gpg
      wget --quiet -O base/SHA256SUMS     "${release_dir}/SHA256SUMS"
      wget --quiet -O base/SHA256SUMS.gpg "${release_dir}/SHA256SUMS.gpg"

      local gnupghome
      gnupghome="$(mktemp -d)"
      gpg --homedir "${gnupghome}" --batch --quiet --keyserver hkps://keyserver.ubuntu.com \
          --recv-keys "${base_iso_signing_key}"
      gpg --homedir "${gnupghome}" --batch --export "${base_iso_signing_key}" > "${gnupghome}/ubuntu-cdimage.gpg"
      gpgv --keyring "${gnupghome}/ubuntu-cdimage.gpg" base/SHA256SUMS.gpg base/SHA256SUMS
      rm -rf "${gnupghome}"

      # The pinned checksum must be the one Ubuntu signed for this file name.
      grep -qx "${base_iso_sha256} \*${base_iso_url##*/}" base/SHA256SUMS

      echo "  - Downloading ${base_iso_url}"
      wget --quiet --show-progress --progress=dot:giga -c "${base_iso_url}" -O "${iso}"
    fi

    echo "  - Checking SHA-256 of ${iso}"
    echo "${base_iso_sha256}  ${iso}" | sha256sum --check
}

function extract-image {
    show-header "Extract image"

    (
      cd base
      if [ ! -f "filesystem.squashfs" ]; then
        osirrox -indev "${flavour}.iso" -extract /casper .
        rm -f filesystem.manifest
        rm -f filesystem.size
        rm -f filesystem.manifest-minimal-remove
        rm -f filesystem.manifest-remove
        rm -f filesystem.squashfs.gpg
      fi
    )

    unsquashfs -d chroot -f base/filesystem.squashfs

    (
      cd "chroot"

      if [ -d "bin.usr-is-merged" ]; then
        rm -rf bin.usr-is-merged lib.usr-is-merged sbin.usr-is-merged
      fi

      if [ -f "etc/apt/sources.list.d/cdrom.sources" ]; then
        rm -rf "etc/apt/sources.list.d/cdrom.sources"
      fi
    )
}

function mount-virtual-fs {
    show-header "Initialize virtual FS"

    mkdir -p chroot/{dev/pts,run,proc,sys}

    --bind-mount
}

function prepare-base-image {
    show-header "Prepare base image" 

    # Fix permissions to /var/lib/apt/lists
    chroot "chroot" mkdir -p /var/lib/apt/lists
    chroot "chroot" chown -R _apt:root /var/lib/apt/lists

    # Fix init.rc
    chroot "chroot" mkdir -p /etc/rc.d
    chroot "chroot" ln -s ../init.d /etc/rc.d/init.d

    # Keyboard layout
    sed -i "s/us/${keyboard}/g" "chroot/etc/default/keyboard"

    # Set locale to pt_BR
    chroot "chroot" sh -c "echo 'grub-pc grub-pc/install_devices_empty   boolean true'                  | debconf-set-selections"
    chroot "chroot" sh -c "echo 'locales locales/locales_to_be_generated multiselect pt_BR.UTF-8 UTF-8' | debconf-set-selections"
    chroot "chroot" sh -c "echo 'locales locales/default_environment_locale select pt_BR.UTF-8'         | debconf-set-selections"
    chroot "chroot" sh -c "echo 'debconf debconf/frontend select Noninteractive'                        | debconf-set-selections"

    # x86-64 baseline: never install amd64v3 package variants, even when the
    # build host's CPU supports them (the ISO must boot on older machines).
    # Removed again in cleanup-system-image, so installed systems keep APT's
    # per-machine default.
    # Downloads are retried (Launchpad PPAs answer 503 now and then), and a
    # repository index that cannot be fetched is an error, not a warning that
    # would leave the image built from stale indexes.
    cat > "chroot/etc/apt/apt.conf.d/99mainuan-build-baseline" <<'APT'
#clear APT::Architecture-Variants;
APT::Architecture-Variants "";
Acquire::Retries "5";
Acquire::Retries::Delay::Maximum "60";
APT::Update::Error-Mode "any";
APT

    # Regenerate vmlinuz and force casper
    local kernel=$(chroot chroot dpkg-query -W -f='${Package}\n' 'linux-image-*-generic' | head -n1)
    chroot-apt-update
    chroot-apt-get install --reinstall --allow-downgrades -y casper ${kernel}
    if [ -f "chroot/usr/share/initramfs-tools/scripts/casper-bottom/41apt_build_cache_cdrom" ]; then
      rm "chroot/usr/share/initramfs-tools/scripts/casper-bottom/41apt_build_cache_cdrom";
    fi
}

function remove-base-packages {
    show-header "Remove base packages" 

    # Remove snaps only to reduce ISO size, snaps are friends :)
    rm -rf chroot/var/lib/snapd chroot/snap chroot/var/snap chroot/usr/lib/snapd
    mkdir -p chroot/var/lib/snapd chroot/var/snap chroot/usr/lib/snapd
    find chroot/etc/systemd -name "*snap*" -delete
    find chroot/etc/systemd -type d -name "*snap*" -exec rm -r {} +
    # udev rules written by snapd for each installed snap (not owned by any
    # package); they call /usr/lib/snapd/snap-device-helper, removed above, and
    # filled the journal with errors on every device event.
    rm -f chroot/etc/udev/rules.d/*snap*.rules

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/remove-base-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No packages to remove"
      return
    fi
    chroot "chroot" apt autoremove --purge $(sed "s|#.*||g" "${variant_data_dir}/remove-base-packages.lst" | xargs) -y   
}

function setup-anti-breakage {
    show-header "Prevent the user from accidentally breakage the system"
    return

    if grep -q "Package: system-anti-breakage" chroot/var/lib/dpkg/status; then
      echo "Anti-breakage system already installed."
      return
    fi

    local depends=$(chroot "chroot" dpkg-query -l | grep  '^ii ' | cut -d' ' -f3 | cut -d: -f1 | xargs | sed 's| |, |g')
    mkdir -p "chroot/system-anti-breakage/DEBIAN"
    (
      echo "Package: system-anti-breakage"
      echo "Version: 1.0"
      echo "Architecture: all"
      echo "Maintainer: Natanael Barbosa Santos"
      echo "Depends: ${depends}"
      echo "Priority: required"
      echo "Essential: yes"
      echo "Description: Prevent entire system from breaking"
    ) > "chroot/system-anti-breakage/DEBIAN/control"

    chroot "chroot" dpkg-deb --build /system-anti-breakage
    chroot "chroot" dpkg -i /system-anti-breakage.deb

    rm -rf "chroot/system-anti-breakage/"
    rm -rf "chroot/system-anti-breakage.deb"
}

function launchpad-repositories {
    show-header "Launchpad repositories" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/launchpad-repositories.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No PPAs to add"
      return
    fi
    echo "  - Checking for add-apt-repository"
    if [ ! -f "chroot/usr/bin/add-apt-repository" ]; then
        echo
        echo "PPA support not installed, installing..."
        echo
        chroot-apt-get install -y software-properties-common
        echo
    fi

    echo "  - Adding PPAs"
    echo
    set -f
    for repo in $(sed "s|#.*||g" "${variant_data_dir}/launchpad-repositories.lst" | xargs); do
        echo "    - ${repo}"
        echo
        # Launchpad drops connections now and then (SSLEOFError): retry.
        local attempt
        for attempt in 1 2 3; do
            chroot "chroot" add-apt-repository "${repo}" -y && break
            [ "${attempt}" -lt 3 ] || return 1
            echo "    add-apt-repository failed (attempt ${attempt}); retrying in $((attempt * 20)) s"
            sleep $((attempt * 20))
        done
        echo
    done
    set +f

    chroot-apt-update
}

function git-dot-files {
    show-header "GIT dot Files"

    local list="${variant_data_dir}/git-dot-files.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No git repositories to clone"
        return 0
    fi

    # Line format (every source is pinned):
    #   <repository>.git <commit-sha1>  > <target>
    #   <archive-url>    <sha256>       > <target>
    local line left target source pin workdir
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ "${line}" == *">"* ]] || continue
        left="${line%%>*}"
        target="$(echo "${line#*>}" | xargs)"
        read -r source pin <<< "${left}"

        workdir="$(mktemp -d -p "${PWD}/chroot/")"

        echo "  - '${source}' (${pin}) -> '${target}'"

        if [[ "${source}" == *.git ]]; then
          if [[ ! "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
            echo "Repository ${source} must be pinned to a full commit hash"
            return 1
          fi
          git -C "${workdir}" init --quiet
          git -C "${workdir}" fetch --quiet --depth 1 "${source}" "${pin}"
          git -C "${workdir}" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
          test "$(git -C "${workdir}" rev-parse HEAD)" = "${pin}"
          echo "${pin}  ${source}" >> "${PWD}/iso/components.sha256"
          rm -rf "${workdir}/.git"
        else
          if [[ ! "${pin}" =~ ^[0-9a-f]{64}$ ]]; then
            echo "Archive ${source} must be pinned to its SHA-256"
            return 1
          fi
          wget --quiet -O "${workdir}.archive" "${source}"
          echo "${pin}  ${workdir}.archive" | sha256sum --check --quiet
          echo "${pin}  ${source##*/}" >> "${PWD}/iso/components.sha256"
          bsdtar -xzf "${workdir}.archive" -C "${workdir}"
          rm -f "${workdir}.archive"
        fi

        (
          cd "${workdir}"
          if [ ! -d "${workdir}/rootfs" ]; then
            mkdir -p "${workdir}/rootfs/${target}"
            find . -mindepth 1 -maxdepth 1 ! -name rootfs -exec mv -t "${workdir}/rootfs/${target}" -- {} +
          fi

          cd "${workdir}/rootfs"
          find . -type d -exec mkdir -p ../../{} \;
          find . \( -type f -o -type l \) -exec cp -a {} ../../{} \;
        )

        rm -rf "${workdir}"
    done < "${list}"
    echo "  - Finished..."
}

function pkexec-sudo-white-list {
    show-header "PolicyKit Exec 'sudo' whitelist"

    local list="${variant_data_dir}/pkexec-sudo-white-list.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No items in whitelist"
        return 0
    fi

    mkdir -p "chroot/etc/polkit-1/rules.d"

    {
      echo 'polkit.addRule(function(action, subject) {'
      echo '  if (!subject.isInGroup("sudo")) return polkit.Result.NO;'
      echo '  if (action.id != "org.freedesktop.policykit.exec") return polkit.Result.NO;'
      echo ''
      echo '  var allowed = ['
      for executable in $(sed "s|#.*||g" "${variant_data_dir}/pkexec-sudo-white-list.lst" | xargs); do
        echo "    '${executable}',"
      done
      echo '  ];'
      echo ''
      echo '  if (allowed.indexOf(action.lookup("program")) >= 0) return polkit.Result.YES;'
      echo ''
      echo '  return polkit.Result.NO;'
      echo '});'
    } > "chroot/etc/polkit-1/rules.d/50-pkexec-sudo-white-list.rules"
}

function pin-packages {
    show-header "Pin packages to use specific repositories" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/pin-packages.yaml" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No packages to pin"
      return
    fi
    IFS=$'\n'
    echo -n > "chroot/etc/apt/preferences.d/mitai"
    for line in $(sed "s|#.*||g" "${variant_data_dir}/pin-packages.yaml"); do
      IFS=$' '
      package=$(echo $line     | cut -d':' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      origin=$(echo $line | cut -d':' -f 2 | cut -d'|' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      (
        echo "Package: ${package}";
        echo "Pin: release o=${origin}";
        echo "Pin-Priority: 999";
        echo "";
        echo "Package: ${package}";
        echo "Pin: release o=Ubuntu";
        echo "Pin-Priority: -1";
        echo ;
      ) >> "chroot/etc/apt/preferences.d/mitai"
    done
    IFS=$' '
    chroot-apt-update
}

function upgrade-base-packages {
    show-header "Upgrade the base system (security and bug-fix updates)"

    # The base image is a point release: without this step the ISO shipped
    # hundreds of pending updates, most of them security updates. Runs after
    # the PPAs and pins are in place, before the Mainuan packages.
    chroot-apt-update
    chroot-apt-get full-upgrade -y --allow-downgrades \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    echo "  - Pending updates after upgrade: $(chroot chroot apt-get -s full-upgrade | grep -c '^Inst ' || true)"

    # A kernel update installs a new ABI next to the old one: keep only the
    # kernel /boot/vmlinuz points to (the one that boots the ISO).
    local current old_kernels=()
    current="$(readlink chroot/boot/vmlinuz)"; current="${current#vmlinuz-}"
    local current_version="${current%-generic}"   # e.g. 7.0.0-43
    while read -r package; do
      case "${package}" in
        *"-${current_version}" | *"-${current_version}-"*) ;;
        *) old_kernels+=("${package}") ;;
      esac
    done < <({ chroot chroot dpkg-query -W -f='${Package} ${Status}\n' \
               'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null || true; } \
             | awk '$NF == "installed" {print $1}')
    if [ "${#old_kernels[@]}" -gt 0 ]; then
      echo "  - Removing kernels other than ${current}: ${old_kernels[*]}"
      chroot-apt-get purge -y "${old_kernels[@]}"
    fi
}

function install-deb-packages {
    show-header "Install Debian packages outside repositories"

    local list="${variant_data_dir}/install-deb-packages.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
      echo "No Debian packages to install"
      return 0
    fi

    rm -rf "chroot/mita-i.debian-packages"
    mkdir -p "chroot/mita-i.debian-packages"

    echo "  - Downloading and verifying packages"
    echo
    local package_url package_sha256 extra file
    while read -r package_url package_sha256 extra; do
      [ -n "${package_url}" ] || continue
      if [ ! "${ALLOW_INSECURE_PACKAGES}" = "allow_insecure" ]; then
        if [[ ! "${package_sha256}" =~ ^[0-9a-f]{64}$ ]] || [ -n "${extra}" ]; then
          echo "Each line of ${list##*/} needs: <url> <sha256> (${package_url})"
          return 1
        fi
      fi
      file="chroot/mita-i.debian-packages/${package_url##*/}"
      echo "    - ${package_url##*/}"
      wget --quiet -O "${file}" "${package_url}"
      if [ ! "${ALLOW_INSECURE_PACKAGES}" = "allow_insecure" ]; then
        echo "${package_sha256}  ${file}" | sha256sum --check --quiet
        echo "${package_sha256}  ${package_url##*/}" >> "${PWD}/iso/components.sha256"
      else
        if ! echo "${package_sha256}  ${file}" | sha256sum --check --quiet; then
          package_sha256=$(sha256sum "${file}" | awk '{print $1}')
          echo "${package_sha256}  ${package_url##*/}" >> "${PWD}/iso/components.insecure.sha256"
          echo "${package_sha256}  ${package_url##*/}" >> "${PWD}/iso/components.sha256"
        else
          echo "${package_sha256}  ${package_url##*/}" >> "${PWD}/iso/components.sha256"
        fi
      fi     
    done < <(sed 's|#.*||' "${list}")
    echo

    echo "  - Installing packages"
    echo
    local debs=()
    for file in chroot/mita-i.debian-packages/*.deb; do
      debs+=("${file#chroot}")
    done
    chroot-apt-get install -y "${debs[@]}"
    echo

    echo "  - Remove .deb files"
    rm -rf "chroot/mita-i.debian-packages"
    echo
}

function install-apt-packages {
    show-header "Install extra packages" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/install-apt-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No packages to install"
      return
    fi
    chroot "chroot" apt purge firefox -y
    # shellcheck disable=SC2046
    chroot-apt-get install --reinstall -y $(sed "s|#.*||g" "${variant_data_dir}/install-apt-packages.lst" | xargs)
}

function install-flatpak-packages {
    show-header "Install Flatpak packages" 

    echo "  - Checking for flatpak"
    if [ ! -f "chroot/usr/bin/flatpak" ]; then
        echo
        echo "Flatpak, not found, skipping..."
        echo
        return
    fi
    echo "  - Setup Flathub"
    echo
    echo "Fixing TSL issues with Flathub SSL on chroot..."
    chroot-apt-get install --reinstall --allow-downgrades -y ca-certificates
    echo
    chroot "chroot" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    echo
    if [ "$(sed 's|#.*||g' "${variant_data_dir}/install-flapak-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No Flatpak packages to install"
      return
    fi
    echo "  - Installing packages"
    echo
    chroot "chroot" flatpak install $(sed "s|#.*||g" "${variant_data_dir}/install-flapak-packages.lst" | xargs) -y
    echo
}

function install-appimage-packages {
    show-header "Install AppImage packages" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/install-appimage-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No AppImage packages to install"
      return
    fi
    echo "  - Checking for Mita-i-appimage-installer"
    if [ ! -f "chroot/usr/bin/mita-i-appimage-installer" ]; then
        echo
        echo "Mita-i-appimage-installer, not found skipping..."
        echo
        return
    fi

    echo "  - Installing packages"
    echo
    chroot "chroot" mita-i-appimage-installer fetch $(sed "s|#.*||g" "${variant_data_dir}/install-appimage-packages.lst" | xargs) -y
    echo
}

function install-snap-packages {
    show-header "Install Snaps packages" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/install-snap-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No Snap packages to install"
      return
    fi
    echo "  - Checking for snapd"
    echo
    if [ ! -f "chroot/usr/bin/snap" ]; then
        echo
        echo "Snap support not found; skipping Snap installation."
        echo
        return 0
    fi
    echo "  - Installing packages"
    echo
    chroot "chroot" snap install $(sed "s|#.*||g" "${variant_data_dir}/install-snap-packages.lst" | xargs) -y
    echo
}

function setup-calamares {
    show-header "Setup Calamares" 

    echo "  - Checking for Calamares"
    if [ ! -f "chroot/etc/calamares/settings.conf" ]; then
        echo
        echo "Calamares, not found skipping..."
        echo
        return
    fi

    # LibreOffice is removed from the image, and libreoffice-l10n-$LOCALE would
    # pull it back in: keep these entries disabled.
    echo "  - Disable Libre Office reinstallation"
    sed -i 's|^      - libreoffice-help-|#      - libreoffice-help-|' "chroot/etc/calamares/modules/packages.conf"
    sed -i 's|^      - libreoffice-l10n-|#      - libreoffice-l10n-|' "chroot/etc/calamares/modules/packages.conf"

    # Hunspell dictionaries stay enabled: Calamares installs hunspell-$LOCALE with
    # try_install, so an offline installation simply skips it, and users of
    # other languages get spell checking (KDE Sonnet) in their language.

    echo "  - Default time zone (used when GeoIP has no answer): ${timezone}"
    if [ ! -f "chroot/usr/share/zoneinfo/${timezone}" ]; then
      echo "Unknown time zone '${timezone}' in distro.ini"
      return 1
    fi
    local locale_conf="chroot/etc/calamares/modules/locale.conf"
    local tz_region="${timezone%%/*}" tz_zone="${timezone#*/}"
    if grep -q '^region:' "${locale_conf}"; then
      sed -i "s|^region:.*|region: \"${tz_region}\"|" "${locale_conf}"
    else
      echo "region: \"${tz_region}\"" >> "${locale_conf}"
    fi
    if grep -q '^zone:' "${locale_conf}"; then
      sed -i "s|^zone:.*|zone: \"${tz_zone}\"|" "${locale_conf}"
    else
      echo "zone: \"${tz_zone}\"" >> "${locale_conf}"
    fi

    # Kubuntu installs grub-efi-amd64-signed and shim-signed for UEFI from the
    # APT repository on its own medium (cdrom.sources + /pool). This image has
    # no such repository (cdrom.sources is removed in extract-image) and ships
    # both packages already installed, so the UEFI install failed at
    # "cp /etc/apt/sources.list.d/cdrom.sources". Check them instead.
    echo "  - UEFI bootloader packages come from the image itself"
    for package in grub-efi-amd64-signed shim-signed; do
      chroot chroot dpkg-query -W -f='${Status}\n' "${package}" | grep -qx 'install ok installed' || {
        echo "${package} must be installed in the image"; return 1; }
    done
    cat > "chroot/etc/calamares/modules/before_bootloader_context.conf" <<'CONF'
# Mainuan: the signed EFI bootloader packages are part of the image (there
# is no package repository on the medium); only check that they are there.
---
firmwareType:
    bios:    "-/bin/true"
    "*":
        -    command: "dpkg -s grub-efi-amd64-signed | grep -qx 'Status: install ok installed'"
             timeout: 10
        -    command: "dpkg -s shim-signed | grep -qx 'Status: install ok installed'"
             timeout: 10
CONF

    echo "  - Disable Internet check"
    sed -i 's|^        - internet|#        - internet|' "chroot/etc/calamares/modules/welcome.conf"

    echo "  - Donate button only with a donation link"
    sed -i "s|^showDonateUrl: .*|showDonateUrl: ${donate:-false}|" "chroot/etc/calamares/modules/welcome.conf"

    echo "  - Removing \"Customize\" section"
    sed -i 's|^  - pkgselect|#  - pkgselect|' "chroot/etc/calamares/settings.conf"

    echo "  - Disabling \"Automirror\" section"
    sed -i 's|^  - automirror|#  - automirror|' "chroot/etc/calamares/settings.conf"

    echo "  - Disabling \"shellprocess@rmcdrom\" section"
    sed -i 's|^  - shellprocess@rmcdrom|#  - shellprocess@rmcdrom|' "chroot/etc/calamares/settings.conf"

    # GPT partition names shown by the installer and by file managers
    # (Dolphin "Devices"). fstab, GRUB and the initramfs use UUIDs, so the
    # names do not take part in booting.
    echo "  - Change partitions name"
    sed -i -E 's|^    - name: "(kubuntu_boot\|System_Boot)"|    - name: "Mainuan_Boot"|' "chroot/etc/calamares/modules/partition.conf"
    sed -i -E 's|^    - name: "(kubuntu_2604\|System_Root)"|    - name: "Mainuan"|' "chroot/etc/calamares/modules/partition.conf"
    grep -q '^    - name: "Mainuan"$' "chroot/etc/calamares/modules/partition.conf" || {
      echo "partition.conf: root partition name not found"; return 1; }

    # Remove the Discover update notifier from the installed system only: the
    # packages module runs in the target after the bootloader, never in the
    # live session. Mainuan has its own update alert (system-upgrade).
    # plasma-discover only recommends it, so Discover itself stays.
    echo "  - Remove plasma-discover-notifier from the installed system"
    if ! grep -q 'plasma-discover-notifier' "chroot/etc/calamares/modules/packages.conf"; then
      cat >> "chroot/etc/calamares/modules/packages.conf" <<'CONF'
  - try_remove:
      - plasma-discover-notifier
CONF
    fi

    # The umount module gives each umount 10 s (fixed in Calamares 3.3).
    # On a slow disk the root still has gigabytes of dirty pages there, the
    # umount times out and the installer reports "Could not unmount the root
    # of the target system", although the installation is complete. Flushing
    # first, with its own generous timeout, makes the umount immediate.
    echo "  - Flush the target before unmounting it"
    cat > "chroot/etc/calamares/modules/shellprocess_sync.conf" <<'CONF'
---
dontChroot: true
timeout: 900
script:
    - "sync -f ${ROOT}"
    - "sync"
CONF
    if ! grep -q 'shellprocess@sync' "chroot/etc/calamares/settings.conf"; then
      sed -i 's|^instances:$|instances:\n- id:       sync\n  module:   shellprocess\n  config:   shellprocess_sync.conf\n|' \
        "chroot/etc/calamares/settings.conf"
      sed -i 's|^  - umount$|  - shellprocess@sync\n  - umount|' "chroot/etc/calamares/settings.conf"
    fi
    grep -qx '  - shellprocess@sync' "chroot/etc/calamares/settings.conf" \
      && grep -q 'config:   shellprocess_sync.conf' "chroot/etc/calamares/settings.conf" || {
      echo "settings.conf: sync step not added"; return 1; }

    echo "  - Change name of branding directory"
    sed -i 's|^branding:.*|branding: vendor|' "chroot/etc/calamares/settings.conf"
    mkdir -p "chroot/etc/calamares/branding/vendor"
    echo "---
componentName: vendor

windowExpanding:    fullscreen

strings:
    productName:         ${name}
    shortProductName:    ${name}
    version:             ${system_version}
    shortVersion:        ${system_version}
    versionedName:       ${name}
    shortVersionedName:  ${name} ${system_version}
    bootloaderEntryName: ${name}
    productUrl:          ${website}
    supportUrl:          ${contact}
$( [ -n "${donate}" ] && echo "    donateUrl:           ${donate}" )
    releaseNotesUrl:     ${release}
    knownIssuesUrl:      ${issues}

images:
    productLogo:         \"logo.png\"
    productIcon:         \"icon.png\"
    productWelcome:      \"welcome.png\"

slideshow:               \"show.qml\"

slideshowAPI:            1

style:
   SidebarBackground:        \"#292C30\"
   SidebarText:              \"#FFFFFF\"
   SidebarTextCurrent:       \"#FFFFFF\"
   SidebarBackgroundCurrent: \"#44464A\"

" > "chroot/etc/calamares/branding/vendor/branding.desc"

    # "Install System" in every language the live session can use (the
    # Kubuntu names say "Kubuntu"); translations in data/base/installer-name.lst.
    echo "  - Fix installer name"
    local launcher names
    names="$(sed 's|#.*||' "${variant_data_dir}/installer-name.lst" | grep '=')"
    for launcher in chroot/usr/share/applications/*calamares*.desktop; do
      sed -i -E '/^(Name|GenericName|Comment)(\[[^]]*\])?=/d' "${launcher}"
      if [[ "${launcher}" == *oem* ]]; then
        sed -i "/^\[Desktop Entry\]/a $(echo "${names}" | sed 's|$| (OEM)|' | sed ':a;N;$!ba;s/\n/\\n/g')" "${launcher}"
      else
        sed -i "/^\[Desktop Entry\]/a $(echo "${names}" | sed ':a;N;$!ba;s/\n/\\n/g')" "${launcher}"
      fi
      grep -q '^Name=Install System' "${launcher}" || { echo "${launcher}: name not set"; return 1; }
    done


    # Slideshow: QML with translated text, shipped by mainuan-desktop-defaults
    # (etc/calamares/branding/vendor/show.qml and lang/*.qm).
    echo "  - Slideshow"
    for file in show.qml lang/calamares-vendor_pt_BR.qm; do
      [ -s "chroot/etc/calamares/branding/vendor/${file}" ] || {
        echo "Calamares branding: ${file} missing (mainuan-desktop-defaults)"; return 1; }
    done
}

function remove-orphan-packages {
    show-header "Remove packages left behind by the base upgrade"

    # data/base/remove-orphan-packages.lst: libraries only an older version of
    # a base package needed (fwupd 2.1.1 of the 26.04.1 image depended on
    # libflashrom1 and libjcat1; the 2.1.6 update uses neither). Runs after
    # every installation step, so nothing brings them back into the image.
    # They are removed only when nothing else goes with them: if a package
    # still depends on one, the build stops instead of taking that package
    # (fwupd, Discover...) out of the image.
    local list="${variant_data_dir}/remove-orphan-packages.lst"
    local wanted=() package
    if [ -f "${list}" ]; then
      for package in $(sed 's|#.*||' "${list}" | xargs); do
        if [ "$(chroot chroot dpkg-query -W -f='${Status}' "${package}" 2>/dev/null)" = "install ok installed" ]; then
          wanted+=("${package}")
        else
          echo "  - ${package} is not installed, skipping"
        fi
      done
    fi
    if [ "${#wanted[@]}" -eq 0 ]; then
      echo "No orphan packages to remove"
      return 0
    fi

    local removed extra
    removed="$(chroot chroot apt-get -s purge "${wanted[@]}" | awk '/^Purg /{print $2}' | sort)"
    extra="$(comm -23 <(echo "${removed}") <(printf '%s\n' "${wanted[@]}" | sort))"
    if [ -n "${extra}" ]; then
      echo "Removing ${wanted[*]} would also remove:"
      echo "${extra}" | sed 's|^|    |'
      echo "Something still depends on them: drop them from ${list##*/}."
      return 1
    fi
    echo "  - Purging ${wanted[*]}"
    chroot-apt-get purge -y "${wanted[@]}"
    chroot chroot apt-get check
}

function remove-packages-contents {
    show-header "Remove package contents" 

    mkdir -p chroot/etc/apt/preferences.d/

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/remove-packages-content.lst" | xargs)" = "" ]; then
      echo "No packages to remove contents"
      return
    fi

    for package in $(sed "s|#.*||g" "${variant_data_dir}/remove-packages-content.lst" | xargs); do
      echo "Removing '${package}' content"
      if [ ! -f "chroot/var/lib/dpkg/info/${package}.list" ]; then
        echo "  - ${package} is not installed, skipping"
        continue
      fi
      for file in $(cat "chroot/var/lib/dpkg/info/${package}.list"); do
        if [ -f "chroot/${file}" ] || [ -L "chroot/${file}" ]; then
          rm "chroot/${file}"
        fi
      done
      # Directories the package left empty (deepest first).
      for file in $(sort -r "chroot/var/lib/dpkg/info/${package}.list"); do
        if [ -d "chroot/${file}" ]; then
          rmdir --ignore-fail-on-non-empty "chroot/${file}" 2>/dev/null || true
        fi
      done

      echo "  - Regenerate list file"
      (
        echo "/."
        echo "/etc"
        echo "/etc/apt"
        echo "/etc/apt/preferences.d"
        echo "/etc/apt/preferences.d/${package}"
      ) > chroot/var/lib/dpkg/info/${package}.list
      echo "  - Pinning release"
      (
        echo "Package: ${package}"
        echo "Pin: release *"
        echo "Pin-Priority: -1"
      ) > chroot/etc/apt/preferences.d/${package}
      echo "  - Generating md5sum of '/etc/apt/preferences.d/${package}'"
      chroot chroot/ md5sum "etc/apt/preferences.d/${package}" > chroot/var/lib/dpkg/info/${package}.md5sums

      echo "  - Removing triggers"
      for trigger in conffiles postrm prerm postinst preinst shlibs triggers; do
        if [ -f "chroot/var/lib/dpkg/info/${package}.${trigger}" ]; then
          rm "chroot/var/lib/dpkg/info/${package}.${trigger}"
        fi
      done
    done 
    chroot chroot/ dpkg --clear-avail
    chroot-apt-update
}

function reorganize-menu {
    show-header "Clear the system image"

    echo "  - Hide apps from menu"
    mkdir -p chroot/usr/local/share/applications
    for file in $(sed "s|#.*||g" "${variant_data_dir}/hide-apps-from-menu.lst" | xargs); do
        if [ -f "chroot/usr/local/share/applications/${file}" ]; then
            rm "chroot/usr/local/share/applications/${file}"
        fi
        if [ ! -f "chroot/usr/share/applications/${file}" ]; then
            echo "    - ${file}: not installed, nothing to hide"
            continue
        fi
        cp "chroot/usr/share/applications/${file}" "chroot/usr/local/share/applications"
        sed -i 's|\[Desktop Entry]|[Desktop Entry]\nNoDisplay=true|g' \
            "chroot/usr/local/share/applications/${file}"
    done

    echo "  - Reorganize apps in menu"
    mkdir -p chroot/var/lib/semantic-ux/applications

    prev_file=""
    IFS=$'\n'
    for line in $(sed "s|#.*||g" "${variant_data_dir}/reorganize-apps.yaml"); do
        IFS=$' '

        raw_key=$(echo "$line" | cut -d':' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
        category=$(echo "$line" | cut -d':' -f 2 | cut -d'|' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
        name=$(echo "$line"    | cut -d':' -f 2 | cut -d'|' -f 2 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')

        # Separa o nome do arquivo da tag de idioma opcional: arquivo.desktop[pt_BR]
        file=$(echo "$raw_key" | sed 's/\[.*\]$//')
        lang=$(echo "$raw_key" | sed -n 's/.*\[\(.*\)\]$/\1/p')

        [ ! -f "chroot/usr/share/applications/${file}" ] && continue
        # Entries hidden above stay hidden.
        if sed 's|#.*||' "${variant_data_dir}/hide-apps-from-menu.lst" | grep -qx "${file}"; then
            continue
        fi

        # Copia do source apenas na primeira vez que o arquivo aparece
        if [ "${file}" != "${prev_file}" ]; then
            cp "chroot/usr/share/applications/${file}" "chroot/var/lib/semantic-ux/applications"
            prev_file="${file}"
        fi

        dest="chroot/var/lib/semantic-ux/applications/${file}"
        tmp="${dest}.tmp"

        if [ -z "${lang}" ]; then
            # Entrada padrão (sem idioma): atualiza Categories e Name base
            sed -i "s|^Categories=.*|Categories=${category}|g" "${dest}"

            case "${name}" in
                %GenericName)
                    # Remove Name[*]= e Comment[*]=; renomeia GenericName= para Name=
                    awk '
                        /^\[Desktop Entry\]/ { in_section=1; print; next }
                        /^\[/               { in_section=0 }
                        in_section && /^[[:space:]]*(Name|Comment)(\[.*\])?=/ { next }
                        in_section          { sub(/^[[:space:]]*GenericName/, "Name") }
                        { print }
                    ' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
                    ;;
                %Name)
                    # Remove GenericName[*]= e Comment[*]=; mantém Name[*]= existente
                    awk '
                        /^\[Desktop Entry\]/ { in_section=1; print; next }
                        /^\[/               { in_section=0 }
                        in_section && /^[[:space:]]*(GenericName|Comment)(\[.*\])?=/ { next }
                        { print }
                    ' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
                    ;;
                *)
                    # Nome descritivo fixo. As variantes por idioma (linhas
                    # arquivo.desktop[xx]) definem o texto de cada idioma; os
                    # idiomas sem variante usam a descrição traduzida do próprio
                    # aplicativo (GenericName[xx]) ou, sem ela, o Name[xx]
                    # original. Name= (base, sem idioma) recebe o GenericName em
                    # inglês, para que nenhum idioma sem variante caia no texto
                    # em português. Remove GenericName[*]= e Comment[*]=.
                    awk -v name="${name}" '
                        function key_of(line, field) {
                            line = substr(line, 1, index(line, "=") - 1)
                            sub("^[[:space:]]*" field, "", line)
                            return line
                        }
                        NR == FNR {
                            if ($0 ~ /^\[Desktop Entry\]/) { s = 1; next }
                            if ($0 ~ /^\[/) { s = 0; next }
                            if (s && $0 ~ /^[[:space:]]*GenericName(\[[^]]*\])?=/)
                                generic[key_of($0, "GenericName")] = substr($0, index($0, "=") + 1)
                            if (s && $0 ~ /^[[:space:]]*Name(\[[^]]*\])?=/) has[key_of($0, "Name")] = 1
                            next
                        }
                        /^\[Desktop Entry\]/ { in_section = 1; print; next }
                        /^\[/                { in_section = 0 }
                        in_section && /^[[:space:]]*(GenericName|Comment)(\[.*\])?=/ { next }
                        in_section && /^[[:space:]]*Name(\[[^]]*\])?=/ {
                            k = key_of($0, "Name")
                            if (k == "") {
                                print "Name=" (("" in generic) ? generic[""] : name)
                                # Idiomas que só têm GenericName[xx] ganham Name[xx].
                                for (g in generic) if (g != "" && !(g in has)) print "Name" g "=" generic[g]
                            } else if (k in generic) {
                                print "Name" k "=" generic[k]
                            } else {
                                print
                            }
                            next
                        }
                        { print }
                    ' "${dest}" "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
                    ;;
            esac
        else
            # Entrada localizada: insere ou substitui Name[lang]= logo após Name=.
            # Remove também as variantes regionais (Name[pt_BR] para [pt]),
            # que teriam prioridade sobre Name[pt] numa sessão pt_BR.
            awk -v lang="${lang}" -v name="${name}" '
                /^\[Desktop Entry\]/ { in_section=1; print; next }
                /^\[/               { in_section=0 }
                in_section && /^[[:space:]]*Name\[/ \
                    && $0 ~ ("^[[:space:]]*Name\\[" lang "([_@][^]]*)?\\]=") { next }
                { print }
                in_section && /^[[:space:]]*Name=/ { print "Name[" lang "]=" name }
            ' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
        fi

        cp "${dest}" "chroot/usr/local/share/applications"
    done
    IFS=$' '
}

function default-applications {
    show-header "Default applications for file types"

    local list="${variant_data_dir}/default-applications.lst"
    if [ ! -f "${list}" ] || ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
      echo "No default applications to set"
      return 0
    fi

    # System-wide defaults (XDG); user choices in ~/.config/mimeapps.list win.
    local file="chroot/etc/xdg/mimeapps.list" mime desktop
    touch "${file}"
    grep -q '^\[Default Applications\]' "${file}" || printf '[Default Applications]\n' >> "${file}"
    while IFS='=' read -r mime desktop; do
      mime="$(echo "${mime}" | xargs)"; desktop="$(echo "${desktop}" | xargs)"
      [ -n "${mime}" ] && [ -n "${desktop}" ] || continue
      if [ ! -f "chroot/usr/share/applications/${desktop}" ]; then
        echo "${desktop} is not installed (default for ${mime})"
        return 1
      fi
      sed -i "\|^${mime}=|d" "${file}"
      sed -i "/^\[Default Applications\]/a ${mime}=${desktop};" "${file}"
      echo "  - ${mime} -> ${desktop}"
    done < <(sed 's|#.*||' "${list}")
}

function apply-mitai-directory {
    show-header "Apply Mita'i OS root structure" 

    if [ "${system_dir}" = "" ]; then
      return
    fi

    (
      cd "chroot"

      echo "  - Create Mita'i base directory"
      mkdir -p "${system_dir}/versions/"
      mkdir -p "${system_dir}/shared/accounts"
      mkdir -p "${system_dir}/shared/flatpaks"
      mkdir -p applications
      mkdir -p containers

      for file in passwd shadow group gshadow login.defs; do
        cp "etc/${file}" "${system_dir}/shared/accounts"
      done

      echo "  - Merge /boot with /usr"
      if [ ! -L "boot" ]; then
        mv boot usr/grub
        ln -s usr/grub boot
      fi

      echo "  - Merge /var with /usr"
      if [ ! -L "var" ]; then
        mv var usr/state
        ln -s usr/state var
      fi

      echo "  - Merge /opt with applications/thirdparty"
      if [ ! -L "opt" ]; then
        mv opt applications/thirdparty
        ln -s applications/thirdparty opt
      fi

      echo "  - Merge Flatpak with /applications"
      if [ ! -L "${system_dir}/shared/flatpaks/runtime" ]; then
        mkdir -p "/${system_dir}/shared/flatpaks"
        ln -s "/${system_dir}/shared/flatpaks"  var/lib/flatpak
        ln -s /applications "${system_dir}/shared/flatpaks/app"
        ln -s /containers "${system_dir}/shared/flatpaks/runtime"
      fi

      echo "  - Move /usr to Mita'i OS directory"
      if [ ! -L "usr" ]; then
        mv usr "${system_dir}/versions/${system_version}"
        ln -s "${system_dir}/versions/${system_version}" usr
        ln -s /usr "${system_dir}/system"
        # /etc/resolv.conf é um link relativo
        ln -fs /run "${system_dir}/versions/${system_version}/run"
      fi
    )
}

function apply-mitai-root-ux {
    show-header "Apply Mita'i OS root UX"
    if [ "${system_dir}" = "" ]; then
      return
    fi
    (
      cd "chroot"

      echo "  - Merge /mnt with /media"
      if [ ! -L "mnt" ]; then
        mv mnt media/0-devices
        ln -s media/0-devices mnt
      fi

      echo "  - Rename /home as /users"
      if [ ! -L "home" ]; then
        mv home/ users
        ln -s users home
      fi

      echo "  - Merge /root with /users"
      if [ ! -L "root" ]; then
        mkdir -p home/root
        rm -rf root
        chown root:root home/root
        chmod 700 home/root
        ln -s home/root root
        chown root:root root
        chmod 700 root
      fi
    
      echo "  - Rename /tmp as /temp"
      if [ ! -L "tmp" ]; then
        mv tmp temp
        ln -s temp tmp
      fi

      echo "  - Populate Mita'i OS linux directory"
      mkdir -p "${system_dir}/linux/"
      if [ ! -L "${system_dir}/linux/processes" ]; then
        ln -fs /dev "${system_dir}/linux/devices"
        ln -fs /sys "${system_dir}/linux/kernel"
        ln -fs /run "${system_dir}/linux/runtime"
        ln -fs /proc "${system_dir}/linux/processes"
      fi

      # Generate the .hidden file
      (
        echo "bin"
        echo "boot"
        echo "dev"
        echo "etc"
        echo "home"
        echo "lib"
        echo "lib64"
        echo "mnt"
        echo "opt"
        echo "proc"
        echo "root"
        echo "rofs"
        echo "run"
        echo "sbin"
        echo "srv"
        echo "swapfile"
        echo "sys"
        echo "tmp"
        echo "usr"
        echo "var"
      ) > .hidden
    ) 
}

function remove-system-files {
    show-header "Removing system files"

    local list="${variant_data_dir}/remove-system-files.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No files to remove"
        return 0
    fi

    for f in $(sed "s|#.*||g" "${variant_data_dir}/remove-system-files.lst" | xargs); do
      if [ -f "chroot/${f}" ]; then
        rm -vf "chroot/${f}";
        continue;
      fi
      if [ -h "chroot/${f}" ]; then
        rm -vf "chroot/${f}";
        continue;
      fi
      if [ -d "chroot/${f}" ]; then
        rm -rfv "chroot/${f}";
        mkdir -p "chroot/${f}";
        continue;
      fi
    done

    sleep 5
}

function exclude-paths {
    show-header "Exclude paths (wallpapers, themes, color schemes)"

    # Kubuntu/KDE resources the Mainuan does not offer, listed in
    # exclude-paths.lst. dpkg path-exclude keeps package updates from bringing
    # them back; deleting /etc/dpkg/dpkg.cfg.d/mainuan-exclude-paths and
    # reinstalling the owner package restores them.
    local list="${variant_data_dir}/exclude-paths.lst" config pattern
    config="chroot/etc/dpkg/dpkg.cfg.d/mainuan-exclude-paths"
    {
      echo "# Mainuan: resources not shipped (build/data/base/exclude-paths.lst)."
      echo "# Remove this file and reinstall the owner package to restore them."
    } > "${config}"
    for pattern in $(sed 's|#.*||' "${list}" | xargs); do
      case "${pattern}" in
        /usr/share/plasma/desktoptheme/default|/usr/share/plasma/desktoptheme/default/*)
          echo "Refusing to exclude the default Plasma style (fallback of every theme)"; return 1 ;;
      esac
      echo "path-exclude=${pattern}" >> "${config}"
      echo "path-exclude=${pattern}/*" >> "${config}"
      # shellcheck disable=SC2086
      for path in chroot${pattern}; do
        [ -e "${path}" ] || [ -L "${path}" ] || continue
        echo "  - ${path#chroot}"
        rm -rf "${path}"
      done
    done
}

function create-symlinks {
    show-header "Symbolic links"

    local list="${variant_data_dir}/symlinks.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No symlinks to do"
        return 0
    fi

    set -f
    IFS=$'\n'
    for repo in $(sed "s|#.*||g" "${variant_data_dir}/symlinks.lst" ); do
        [ -z "${repo}" ] && continue;
        local origin=$(echo "${repo}" | sed 's| .*$||');
        local target=$(echo "${repo}" | sed 's|^.* ||');

        [ -z "${origin}" ] && continue;
        [ -z "${target}" ] && continue;

        echo "    - From '${origin}'";
        echo "    - To '${target}'";


        origin=$(chroot "chroot" readlink -f "${origin}");
        # -m: the target directory may not exist yet (created below).
        target=$(chroot "chroot" readlink -m "${target}");
        local target_dir=$(chroot "chroot" dirname "${target}");

        chroot "chroot" rm -rf "${target}";
        chroot "chroot" mkdir -p "${target_dir}";
        chroot "chroot" ln -fs "${origin}" "${target}";
        echo "    ======================================================='";
    done
    IFS=$' '
    set +f
    echo "  - Finished..."
}

function branding {
  show-header "Create branding files"
  # These files belong to base-files and kubuntu-settings-desktop. A local
  # dpkg diversion sends a later update of those packages to <file>.distrib
  # instead of turning the system back into "Ubuntu"/"Kubuntu". --no-rename:
  # base-files is Essential, and the Mainuan file is written right below.
  local f
  for f in /etc/xdg/kcm-about-distrorc /etc/issue /etc/issue.net /etc/lsb-release /usr/lib/os-release; do
    chroot "chroot" dpkg-divert --quiet --local --no-rename --divert "${f}.distrib" --add "${f}"
  done
  (
    echo "[General]"
    echo "LogoPath=${logo}"
    echo "Name=${name}"
    echo "UseOSReleaseVersion=false"
    echo "Version=${system_version} ${type}"
    echo "Website=${website}"
  ) > "chroot/etc/xdg/kcm-about-distrorc"

  (
    echo -E "${name} ${system_version} ${type} \n \l"
  ) > "chroot/etc/issue"

  (
    echo "${name} ${system_version} ${type}"
  ) > "chroot/etc/issue.net"

  (
    echo "DISTRIB_ID=${name}"
    echo "DISTRIB_RELEASE=${system_version}"
    echo "DISTRIB_CODENAME=${flavour_release}"
    echo "DISTRIB_DESCRIPTION=\"${name} ${system_version} ${type}\""
  ) > "chroot/etc/lsb-release"

  (
    echo "PRETTY_NAME=\"${name} ${system_version} ${type}\""
    echo "NAME=\"${name}\""
    echo "VERSION_ID=\"${system_version}\""
    echo "VERSION=\"${system_version} ${type} (${code_name})\""
    echo "VERSION_CODENAME=${flavour_release}"
    echo "ID=${id}"
    echo "ID_LIKE=debian"
    echo "HOME_URL=\"${website}\""
    echo "SUPPORT_URL=\"${help}\""
    echo "BUG_REPORT_URL=\"${issues}\""
    echo "PRIVACY_POLICY_URL=\"${privacy}\""
    echo "UBUNTU_CODENAME=${flavour_release}"
    echo "LOGO=${logo}"
  ) > "chroot/usr/lib/os-release"
}

function make-executable {
    show-header "Executables"

    local list="${variant_data_dir}/executables.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No files to make executable"
        return 0
    fi

    set -f
    IFS=$'\n'
    for f in $(sed "s|#.*||g" "${variant_data_dir}/executables.lst" ); do
        echo "    - chmod +x '${f}'";

        chroot "chroot" chmod +x "${f}";
    done
    IFS=$' '
    set +f
    echo "  - Finished..."
}

function cleanup-system-image {
    show-header "Clear the system image" 
    
    echo "  - Checking that no amd64v3 package variant was installed"
    if chroot "chroot" dpkg-query -W -f='${Package} ${Architecture-Variant}\n' | grep -E ' amd64v[2-9]$'; then
      echo "Package variants above require a newer CPU than x86-64 baseline"
      return 1
    fi
    rm -f "chroot/etc/apt/apt.conf.d/99mainuan-build-baseline"

    echo "  - Cleaning up APT"
    chroot "chroot" apt clean
    chroot "chroot" apt -q modernize-sources -y
    # modernize-sources keeps the old sources.list as sources.list.bak.
    rm -f "chroot/etc/apt/sources.list.bak"

    echo "  - Cleaning up logs"
    chroot "chroot" find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
}

function umount-virtual-fs {
    show-header "Finish virtual FS" 

    echo "RESUME=none"   > "chroot/etc/initramfs-tools/conf.d/resume"
    echo "FRAMEBUFFER=y" > "chroot/etc/initramfs-tools/conf.d/splash"

    --bind-umount

    # Cleanup history and cache
    rm -rf chroot/tmp/*
    rm -rf chroot/debian-packages    || true &> /dev/null
    rm -rf chroot/lib.usr-is-merged  || true &> /dev/null
    rm -rf chroot/sbin.usr-is-merged || true &> /dev/null
}

function write-manifests {
    show-header "Write package manifest and build information"

    local base_name
    base_name="$(iso-basename)"
    mkdir -p iso

    chroot chroot dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
      | sort > "iso/${base_name}.packages"
    cp "iso/${base_name}.packages" image/casper/filesystem.manifest

    {
      echo "name=${name}"
      echo "version=${system_version}${release_stage:+-${release_stage}}"
      echo "code_name=${code_name}"
      echo "architecture=amd64"
      echo "base_iso=${base_iso_url}"
      echo "base_iso_sha256=${base_iso_sha256}"
      echo "builder_commit=$(git -C "$(dirname "${script}")" rev-parse HEAD 2>/dev/null || echo unknown)"
      echo "build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # The kernel that boots the ISO is the one /boot/vmlinuz points to.
      local boot_kernel
      boot_kernel="$(readlink chroot/boot/vmlinuz)"; boot_kernel="${boot_kernel#vmlinuz-}"
      echo "kernel=${boot_kernel} ($(chroot chroot dpkg-query -W -f='${Version}' "linux-image-${boot_kernel}"))"
      echo "plasma=$(chroot chroot dpkg-query -W -f='${Version}' plasma-workspace)"
      echo "qt=$(chroot chroot dpkg-query -W -f='${Version}' libqt6core6t64)"
      echo "calamares=$(chroot chroot dpkg-query -W -f='${Version}' calamares)"
      echo "xorriso=$(xorriso -version 2>/dev/null | head -n1)"
      echo "squashfs_tools=$(dpkg-query -W -f='${Version}' squashfs-tools 2>/dev/null || echo unknown)"
    } > "iso/${base_name}.build-info"
    echo "  - $(wc -l < "iso/${base_name}.packages") packages"
    cat "iso/${base_name}.build-info"
}

function build-squashfs {
    show-header "Compress system image"

    --bind-umount &> /dev/null

    mkdir -pv image/{boot/grub,casper,isolinux,preseed}
    mksquashfs chroot image/casper/filesystem.squashfs -comp xz -noappend
}

function build-grub {
    show-header "Build GRUB image"

    cp --dereference chroot/boot/vmlinuz    image/casper/vmlinuz
    cp --dereference chroot/boot/initrd.img image/casper/initrd

    # Font for gfxterm: without it the "if loadfont" block below is skipped
    # and the Live menu stays in the firmware text console.
    if [[ -f chroot/usr/share/grub/unicode.pf2 ]]; then
        cp chroot/usr/share/grub/unicode.pf2 image/boot/grub/unicode.pf2
    else
        cp /usr/share/grub/unicode.pf2 image/boot/grub/unicode.pf2
    fi

    rm -rf image/boot/grub/themes
    if [[ -f chroot/usr/share/grub/themes/mainuan/theme.txt ]]; then
        mkdir -p image/boot/grub/themes
        cp -r chroot/usr/share/grub/themes/mainuan image/boot/grub/themes/mainuan
    fi

    (
        # --class picks the icon of the Mainuan GRUB theme.
        sed "s|#.*||g" "${variant_data_dir}/grub-entries.yaml"  | sed '/^$/d' | sed 's|^|menuentry |;s|$|\n  initrd /casper/initrd\n}\n|;s|:| --class mainuan --class os {\n  |'

        echo "menuentry \"Reboot\" --class restart {reboot}"
        echo "menuentry \"Shutdown\" --class shutdown {halt}"
        echo
    ) > image/boot/grub/loopback.cfg

    local escaped_user=$(printf '%s\n'           "$user"            | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_host=$(printf '%s\n'           "$host"            | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_name=$(printf '%s\n'           "$name"            | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_grub_name=$(printf '%s\n'      "$grub_name"       | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_splash=$(printf '%s\n'         "$splash"          | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_keyboard=$(printf '%s\n'       "$keyboard"        | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_base=$(printf '%s\n'           "$base"            | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_system_dir=$(printf '%s\n'     "$system_dir"      | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_system_version=$(printf '%s\n' "$system_version"  | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_flavour=$(printf '%s\n'        "$flavour"         | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_locale=$(printf '%s\n'         "$locale"          | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')
    local escaped_timezone=$(printf '%s\n'       "$timezone"        | sed -e 's/[\/&]/\\&/g;s/"/\\"/g')

    sed -i \
      -e "s/\${user}/$escaped_user/g"                     \
      -e "s/\${host}/$escaped_host/g"                     \
      -e "s/\${name}/$escaped_name/g"                     \
      -e "s/\${grub_name}/\"$escaped_grub_name\"/g"           \
      -e "s/\${splash}/$escaped_splash/g"                 \
      -e "s/\${keyboard}/$escaped_keyboard/g"             \
      -e "s/\${base}/$escaped_base/g"                     \
      -e "s/\${system_dir}/$escaped_system_dir/g"         \
      -e "s/\${system_version}/$escaped_system_version/g" \
      -e "s/\${flavour}/$escaped_flavour/g"               \
      -e "s/\${locale}/$escaped_locale/g"                 \
      -e "s/\${timezone}/$escaped_timezone/g"             \
      image/boot/grub/loopback.cfg

    (
        echo
        echo "search --set=root --file /${name}"
        echo "insmod all_video"
        echo "set default=\"0\""
        echo "set timeout=15"
        
        echo "if loadfont /boot/grub/unicode.pf2 ; then"
        echo "    insmod gfxmenu"
        echo "	insmod jpeg"
        echo "	insmod png"
        echo "	set gfxmode=auto"
        echo "	insmod efi_gop"
        echo "	insmod efi_uga"
        echo "	insmod gfxterm"
        echo "	terminal_output gfxterm"
        # Mainuan GRUB theme (package mainuan-grub-theme) when it is in the
        # image; without graphics GRUB keeps its text menu.
        if [[ -f image/boot/grub/themes/mainuan/theme.txt ]]; then
            echo "	set gfxmode=1920x1080,auto"
            for font in image/boot/grub/themes/mainuan/*.pf2; do
                echo "	loadfont /boot/grub/themes/mainuan/$(basename "$font")"
            done
            echo "	set theme=/boot/grub/themes/mainuan/theme.txt"
        fi
        echo "fi"
        # Mirror the menu on the first serial port when there is one
        # (headless machines, automated boot tests); harmless otherwise.
        echo "if serial --unit=0 --speed=115200 ; then"
        echo "    terminal_input --append serial"
        echo "    terminal_output --append serial"
        echo "fi"

        cat "image/boot/grub/loopback.cfg"
        echo
    ) > image/isolinux/grub.cfg

    (
        echo "#define DISKNAME   ${name}"
        echo "#define TYPE       binary"
        echo "#define TYPEbinary 1"
        echo "#define ARCH       amd64"
        echo "#define ARCHamd64  1"
        echo "#define DISKNUM    1"
        echo "#define DISKNUM1   1"
        echo "#define TOTALNUM   0"
        echo "#define TOTALNUM0  1"
    ) > "image/README.diskdefines"
    
    (
        cd image
        touch "${name}"

        # UEFI with Secure Boot: the signed chain of the verified base image
        # (shim signed by Microsoft, GRUB signed by Canonical). This GRUB
        # finds the medium by /.disk/info and reads /boot/grub/grub.cfg;
        # the kernel copied from the image is Ubuntu's signed kernel.
        local signed="${PWD}/../efi-signed"
        rm -rf "${signed}"
        mkdir -p "${signed}"
        osirrox -indev "../base/${flavour}.iso" -extract /EFI/boot "${signed}" > /dev/null
        chmod -R u+w "${signed}"
        for efi in bootx64.efi grubx64.efi mmx64.efi; do
          [ -s "${signed}/${efi}" ] || { echo "Missing ${efi} in the base image"; return 1; }
        done
        cp isolinux/grub.cfg boot/grub/grub.cfg

        (
            cd isolinux
            rm -f efiboot.img
            dd if=/dev/zero of=efiboot.img bs=1M count=10
            mkfs.vfat efiboot.img
            mmd -i efiboot.img efi efi/boot
            mcopy -i efiboot.img "${signed}/bootx64.efi" "${signed}/grubx64.efi" "${signed}/mmx64.efi" ::efi/boot/
        )
        
        grub-mkstandalone --format=i386-pc --output=isolinux/core.img                      \
          --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls serial terminfo all_video font gfxterm gfxmenu png jpeg test echo halt reboot"  \
          --modules="linux16 linux normal iso9660 biosdisk search" --locales="" --fonts="" \
          "boot/grub/grub.cfg=isolinux/grub.cfg"
          
        cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img
    )
}

function build-iso {
    show-header "Generate ISO image"

    local iso_name
    iso_name="$(iso-basename)"

    cd image

    mkdir -pv ".disk"
    echo "${name} ${system_version}${release_stage:+ ${release_stage^^}} \"${code_name}\" - amd64 ($(date -u +%Y%m%d))" > .disk/info

    # isolinux/bios.img is the El Torito BIOS image: xorriso writes the boot
    # info table into it (-boot-info-table), so its checksum would never match
    # and casper's "check disc for defects" would report the medium as broken.
    find . -type f ! -name md5sum.txt ! -path ./isolinux/bios.img -print0 | sort -z | xargs -0 md5sum > md5sum.txt
    mkdir -pv ../iso
    rm -f "../iso/${iso_name}.iso"

    xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames        \
      -volid "${name}" -eltorito-boot boot/grub/bios.img            \
      -no-emul-boot -boot-load-size 4 -boot-info-table              \
      --eltorito-catalog boot/grub/boot.cat --grub2-boot-info       \
      --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img             \
      -eltorito-alt-boot -e /EFI/BOOT/BOOTX64.efi                   \
      -no-emul-boot -append_partition 2 0xef isolinux/efiboot.img   \
      -output "../iso/${iso_name}.iso" -graft-points "."            \
        /boot/grub/bios.img=isolinux/bios.img                       \
        /EFI/BOOT/BOOTX64.efi=isolinux/efiboot.img

    cd ..

    if [ ! -s "iso/${iso_name}.iso" ]; then
        echo "Failed to generate ISO"
        return 1
    fi

    (
      cd iso
      sha256sum "${iso_name}.iso" > "${iso_name}.iso.sha256"
      sha256sum --check "${iso_name}.iso.sha256"
    )

    echo
    echo "  ISO image file: "
    echo "    $(du -sh "iso/${iso_name}.iso")"
    echo
}

#-----------------------------------------------------------------------------------------------------------------------------------------
chroot-apt-get() {
    # Package downloads from Launchpad PPAs fail with 503 for minutes at a
    # time (the same file answers 200, then 503): retry the whole command.
    # Files already downloaded stay in APT's cache.
    local attempt
    for attempt in 1 2 3 4; do
      if chroot "chroot" apt-get "$@"; then
        return 0
      fi
      echo "  - apt-get $1 failed (attempt ${attempt}/4), retrying in $((attempt * 60)) s"
      sleep $((attempt * 60))
    done
    chroot "chroot" apt-get "$@"
}
#-----------------------------------------------------------------------------------------------------------------------------------------
chroot-apt-update() {
    # Index downloads fail as errors (APT::Update::Error-Mode). Launchpad PPAs
    # sometimes answer 503 for minutes: retry the whole update a few times.
    local attempt
    for attempt in 1 2 3 4; do
      if chroot "chroot" apt-get update; then
        return 0
      fi
      echo "  - apt-get update failed (attempt ${attempt}/4), retrying in $((attempt * 60)) s"
      sleep $((attempt * 60))
    done
    chroot "chroot" apt-get update
}
#-----------------------------------------------------------------------------------------------------------------------------------------
iso-basename() {
    echo "${id}-${system_version}${release_stage:+-${release_stage}}-amd64"
}
#-----------------------------------------------------------------------------------------------------------------------------------------
show-header() {
    current_step=$((current_step+1))
    local progress="${current_step}/${step_count}"

    echo
    echo "---------------------------------------------------------------------"
    echo "  Step ${progress} - ${1}" 
    echo "---------------------------------------------------------------------"
    echo
}
#-----------------------------------------------------------------------------------------------------------------------------------------
EXIT() {
    # Let's make everything as possible to keep base 
    # system on a consistent state
   {
        umount-virtual-fs
    } &> /dev/null
     &> /dev/null
}
trap EXIT EXIT
#-----------------------------------------------------------------------------------------------------------------------------------------
--bind-umount() {
    mounts=(
        "chroot/dev/pts"
        "chroot/dev"
        "chroot/proc"
        "chroot/run"
        "chroot/debian-packages"
    )

    for mount_point in "${mounts[@]}"; do
        while mountpoint -q "${mount_point}"; do
            echo "  - Unmounting ${mount_point}"
            umount -l "${mount_point}" 2>/dev/null
            sleep 0.5
        done
    done
}
#-----------------------------------------------------------------------------------------------------------------------------------------
--bind-mount() {
    echo "  - Mounting /dev"
    mount --bind /dev "chroot/dev"

    echo "  - Mounting /run"
    mount --bind /run "chroot/run"

    echo "  - Mounting /proc"
    chroot "chroot" mount none -t proc /proc

    echo "  - Mounting /dev/pts"
    chroot "chroot" mount none -t devpts /dev/pts
}
#-----------------------------------------------------------------------------------------------------------------------------------------
--help() {
  echo
  echo "---------------------------------------------------------------------------------------------"
  echo "  Mita'i OS Builder v1.0-git"
  echo "---------------------------------------------------------------------------------------------"
  echo "
  This script builds custom Mita'i OS images based on Debian/Ubuntu derivatives.

  🔷 USAGE:

    ${0} [options] [variation] [step]

  🚀 BASIC USAGE:

    Build an image using the default Ubuntu ISO source:
      ${0} [variation]

    Build using a custom ISO URL:
      ${0} --iso=\"[url]\" [variation]

  💡 AVAILABLE VARIATIONS:

$(ls data | sed 's|^|        ▶️ |')

  ⚙️ BUILD STEPS:

    After running a full build at least once, you can execute individual steps:
      ${0} [variation] [step]

    Available steps:

$(grep '^function' "${script}" | grep -Ev -- 'EXIT|function-template|show-header|--|mount-virtual-fs' | cut -d' ' -f2 | sed 's|^|        ▶️ |')

  🧪 ADVANCED OPTIONS:

    Enter the build chroot environment interactively:
      ${0} [variation] --enter-chroot

    Run commands non-interactively inside the chroot:
      ${0} [variation] --chroot [command] [arg1] [arg2] ...

    Skip one or more build steps (comma-separated):
      ${0} [variation] --skip=\"[step1],[step2],[step3]\"

  📘 NOTES:

    Refer to the files under \"data/minimal/\" to understand the structure,
    purpose, and required contents of each configuration file.
"
}

#-----------------------------------------------------------------------------------------------------------------------------------------
--enter-chroot() {
  show-header "Entering chroot now..."
  chroot "chroot"
}

--chroot() {
  show-header "Entering chroot now..."
  if [ "$#" -eq 0 ]; then
    echo "Usage: ${0} <variant> --chroot <command> [arg1] ..." >&2
    return 2
  fi
  chroot "chroot" "$@"
}
#-----------------------------------------------------------------------------------------------------------------------------------------
--run-step() {
  local requested="${1:-}"
  local option=""
  local status=0

  if declare -F "${requested}" > /dev/null; then
    option="${requested}"
  elif [ "${requested}" = "--enter-chroot" ] || [ "${requested}" = "--chroot" ]; then
    option="${requested}"
  fi

  if [ -n "${option}" ]; then
    step_count=3

    show-header "Initialize virtual FS"
    --bind-mount

    (
      set -Eeo pipefail
      trap 'echo "ERROR in step ${option}, line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
      "${option}" "${@:2}"
    )
    status=$?

    show-header "Finish virtual FS"
    --bind-umount

    echo
    exit "${status}"
  fi
  echo "Unknown option '${requested}' availables:" >&2
  echo >&2
  grep '^function' "${script}" | cut -d' ' -f2 | sort | sed 's|^|  * |' >&2
  echo >&2
  exit 1
}
#-----------------------------------------------------------------------------------------------------------------------------------------
script=$(readlink -f "${0}")
step_count=$(grep "^function" "${script}" | wc -l)
current_step=0
#-----------------------------------------------------------------------------------------------------------------------------------------
export LANG=C;
export LC_ALL=C;
#-----------------------------------------------------------------------------------------------------------------------------------------
if [ "${EUID}" -ne 0 ] || { [ -n "${SUDO_USER}" ] && [ "${USER}" = "${SUDO_USER}" ]; }; then
    echo "This script must be run with sudo -EH (as root)."
    exit 1
fi
#-----------------------------------------------------------------------------------------------------------------------------------------
cd "$(dirname "$(readlink -f "${0}")")"
#-----------------------------------------------------------------------------------------------------------------------------------------
unset new_args url
new_args=()
for arg in "$@"; do
  if [[ "${arg}" == --iso=* ]]; then
    url=$(echo "${arg}" | cut -c 7-)
    continue
  fi

  if [ "${arg}" = "--help" ]; then
    --help
    exit
  fi

  if [[ "${arg}" == --skip=* ]]; then
    for step in $(echo "${arg}" | cut -c 8- | tr ',' ' '); do
      unset -f "${step}"
    done
    continue
  fi

  new_args+=("${arg}")
done
set -- "${new_args[@]}"
unset new_args
#-----------------------------------------------------------------------------------------------------------------------------------------
variant="${1}"

if [ ! -d "data" ]; then
  echo "Error: '${variant}' can't find 'data' directory"
  exit 1
fi

if echo "${variant}" | grep -qE '[ /]'; then
  echo "Error: '${variant}' can't contain spaces or /"
  exit 1
fi

if [ "${variant}" = "" ]; then
  echo "Warning: Variant not specified fallbacking to 'minimal'"
  variant="minimal"
fi

if [ ! -f "data/${variant}/distro.ini" ]; then
  echo "Error: 'data/${variant}/distro.ini' not found"
  exit 1
fi

readonly variant_data_dir=$(readlink -f "./data/${variant}")
#-----------------------------------------------------------------------------------------------------------------------------------------
source "${variant_data_dir}/distro.ini"
#-----------------------------------------------------------------------------------------------------------------------------------------

# The base image is pinned in distro.ini (base_iso_url, base_iso_sha256,
# base_iso_signing_key). --iso=<file> only avoids the download: the local
# file must still match the pinned SHA-256.
for required in base_iso_url base_iso_sha256 base_iso_signing_key; do
  if [ -z "${!required}" ]; then
    echo "Error: '${required}' is not set in data/${variant}/distro.ini"
    exit 1
  fi
done
if [ -n "${url}" ] && [ ! -f "${url}" ]; then
  echo "Error: --iso must point to a local copy of ${base_iso_url##*/}"
  exit 1
fi
#-----------------------------------------------------------------------------------------------------------------------------------------
mkdir -p ${variant}
cd ${variant}
mkdir -p iso chroot image/{boot/grub,casper,isolinux,preseed} ;
#-----------------------------------------------------------------------------------------------------------------------------------------
if [ "$#" -gt 1 ]; then
  # Preserve arguments for individual build steps and --chroot commands.
  --run-step "${@:2}"
fi
#-----------------------------------------------------------------------------------------------------------------------------------------
if [ -f "${variant_data_dir}/BuildSteps" ]; then
  while read -r step; do
    [ -n "${step}" ] || continue
    source "${variant_data_dir}/distro.ini"
    ( --run-step "${step}" )
    status=$?
    [ "${status}" -eq 0 ] || exit "${status}"
  done < "${variant_data_dir}/BuildSteps"
  exit 0
fi
#-----------------------------------------------------------------------------------------------------------------------------------------

# Steps run in declaration order. Each one runs in a subshell with errexit, so
# the first failing command stops the build with its step, line and command
# (a failing step used to be ignored and the build went on).
step_index=0
while read -r step; do
  step_index=$((step_index + 1))
  current_step=$((step_index - 1))   # show-header runs in the step's subshell
  if ! declare -F "${step}" > /dev/null; then
    echo "  - Skipping '${step}'"
    continue
  fi
  source "${variant_data_dir}/distro.ini"
  (
    set -Eeo pipefail
    trap 'echo "ERROR in step ${step}, line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
    "${step}"
  )
  status=$?
  if [ "${status}" -ne 0 ]; then
    echo
    echo "Build failed in step '${step}' (exit status ${status})."
    exit "${status}"
  fi
done < <(grep '^function' "${script}" | cut -d' ' -f2)

#-----------------------------------------------------------------------------------------------------------------------------------------

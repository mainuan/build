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
    show-header "Download ISO image"

    mkdir -p base
    if [ -f "base/${flavour}.iso" ]; then
      echo "The file is already fully retrieved; nothing to do."
      return;
    fi

    if [ -f "${url}" ]; then
      cp "${url}" "base/${flavour}.iso"
      return;
    fi
    
    wget --quiet --show-progress -c "${url}" -O "base/${flavour}.iso"
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

    sudo unsquashfs -d chroot -f base/filesystem.squashfs

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

    # Regenerate vmlinuz and force casper
    local kernel=$(chroot chroot dpkg-query -W -f='${Package}\n' 'linux-image-*-generic' | head -n1)
    chroot "chroot" apt update
    chroot "chroot" apt install casper ${kernel} --reinstall --allow-downgrades -y
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
        chroot "chroot" apt install -y software-properties-common
        echo
    fi

    echo "  - Adding PPAs"
    echo
    set -f
    for repo in $(sed "s|#.*||g" "${variant_data_dir}/launchpad-repositories.lst" | xargs); do
        echo "    - ${repo}"
        echo
        chroot "chroot" add-apt-repository "${repo}" -y
        echo
    done
    set +f

    chroot "chroot" sudo apt update
}

function git-dot-files {
    show-header "GIT dot Files"

    local list="${variant_data_dir}/git-dot-files.lst"

    if ! grep -vqE '^[[:space:]]*(#|$)' "${list}"; then
        echo "No git repositories to clone"
        return 0
    fi

    set -f
    IFS=$'\n'
    for repo in $(sed "s|#.*||g" "${variant_data_dir}/git-dot-files.lst" ); do
        [ -z "${repo}" ] && continue

        local workdir=$(mktemp -d -p "${PWD}/chroot/") || return 1;
        local target=$(echo "${repo}" | sed 's|^.* ||');
        local repo=$(echo "${repo}" | sed 's| .*$||');

        echo "  - Cloning '${repo}' to '${target}'..."
        echo

        if [[ "${repo}" == *.git ]]; then
          git clone "${repo}" "${workdir}";
        else
          wget -qO- "${repo}" |  bsdtar -xzf - -C "${workdir}" 
        fi

        echo
        (
          cd "${workdir}";
          if [ ! -d "${workdir}/rootfs" ]; then
            if [ -d "${workdir}/.git" ]; then
              rm -rf "${workdir}/.git"
            fi
            mkdir -p "${workdir}/rootfs";
            mkdir -p "${workdir}/rootfs/${target}";
            find . -mindepth 1 -maxdepth 1 ! -name rootfs -exec mv -t "${workdir}/rootfs/${target}" -- {} +;
          fi

          cd "${workdir}/rootfs";
              
          find . -type d -exec mkdir -p ../../{} \;
          find . \( -type f -o -type l \) -exec cp -a {} ../../{} \;
        )


        rm -rf "${workdir}"
    done
    IFS=$' '
    set +f
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
    chroot "chroot" sudo apt update
}

function install-deb-packages {
    show-header "Install Debian packages outside repositories" 

    if [ "$(sed 's|#.*||g' "${variant_data_dir}/install-deb-packages.lst" | sed '/^$/d' | xargs)" = "" ]; then
      echo "No Debian packages to install"
      return
    fi
    echo "  - Downloading packages"
    echo
    mkdir -p "chroot/mita-i.debian-packages"
    wget --quiet --show-progress -P "chroot/mita-i.debian-packages" $(sed "s|#.*||g" "${variant_data_dir}/install-deb-packages.lst"  | sed '/^$/d' | xargs)
    echo

    echo "  - Installing packages"
    echo
    chroot chroot /bin/bash -c "apt install -y /mita-i.debian-packages/*.deb"
    echo

    echo "  - Remove .deb files"
    echo
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
    chroot "chroot" apt install --reinstall $(sed "s|#.*||g" "${variant_data_dir}/install-apt-packages.lst" | xargs) -y
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
    chroot "chroot" apt install ca-certificates --reinstall --allow-downgrades -y
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
        echo "Snap support, not found skipping..."
        echo
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

    echo "  - Disable Libre Office reinstallation"
    sed -i 's|^      - libreoffice-help-|#      - libreoffice-help-|' "chroot/etc/calamares/modules/packages.conf"
    sed -i 's|^      - libreoffice-l10n-|#      - libreoffice-l10n-|' "chroot/etc/calamares/modules/packages.conf"

    echo "  - Disable Hunspell-[lang] installation"
    sed -i 's|^      - hunspell-|#      - hunspell-|' "chroot/etc/calamares/modules/packages.conf"

    echo "  - Disable Internet check"
    sed -i 's|^        - internet|#        - internet|' "chroot/etc/calamares/modules/welcome.conf"

    echo "  - Fix old donate URL"
    sed -i "s|^showDonateUrl: .*|showDonateUrl: ${donate}|" "chroot/etc/calamares/modules/welcome.conf"

    echo "  - Removing \"Customize\" section"
    sed -i 's|^  - pkgselect|#  - pkgselect|' "chroot/etc/calamares/settings.conf"

    echo "  - Disabling \"Automirror\" section"
    sed -i 's|^  - automirror|#  - automirror|' "chroot/etc/calamares/settings.conf"

    echo "  - Disabling \"shellprocess@rmcdrom\" section"
    sed -i 's|^  - shellprocess@rmcdrom|#  - shellprocess@rmcdrom|' "chroot/etc/calamares/settings.conf"

    echo "  - Change partitions name"
    sed -i 's|^    - name: "kubuntu_boot"|    - name: "System_Boot"|' "chroot/etc/calamares/modules/partition.conf"
    sed -i 's|^    - name: "kubuntu_2604"|    - name: "System_Root"|' "chroot/etc/calamares/modules/partition.conf"

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
    donateUrl:           ${donate}
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

    echo "  - Fix installer name"
    sed '
      s|^Name|#Name|;
      s|^GenericName|#GenericName|;
      s|^Comment|#Comment|;
      s|^#Name=.*|Name=Instalar o Sistema|;
    ' -i chroot/usr/share/applications/*calamares*.desktop
    sed 's|^Name=.*|Name=Instalar o Sistema (OEM)|' -i chroot/usr/share/applications/*calamares*oem*.desktop


    echo "  - Generating slideshow"
    echo "import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        interval: 15000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
" > "chroot/etc/calamares/branding/vendor/show.qml"
  (
    counter=0
    cd "chroot/etc/calamares/branding/vendor/"

    shopt -s nullglob
    for file in *.png; do
      if [[ "$file" =~ ^(icon|logo|welcome|welcome-oem)\.png$ ]]; then
        continue
      fi
      ((counter++))
      echo "
    Slide {
        Image {
            id: image${counter}
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: \"${file}\"
        }
    }

"
    done
    shopt -u nullglob
    unset counter
  ) >> "chroot/etc/calamares/branding/vendor/show.qml"
  echo "
}" >> "chroot/etc/calamares/branding/vendor/show.qml"

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
      for file in $(cat "chroot/var/lib/dpkg/info/${package}.list"); do
        if [ -f "chroot/${file}" ]; then
          rm "chroot/${file}"
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
    chroot chroot/ apt-get update
}

function reorganize-menu {
    show-header "Clear the system image" 

    echo "  - Hide apps from menu"
    mkdir -p chroot/usr/local/share/applications
    for file in $(sed "s|#.*||g" "${variant_data_dir}/hide-apps-from-menu.lst" | xargs); do
      if [ -f "chroot/usr/local/share/applications/${file}" ]; then
        rm "chroot/usr/local/share/applications/${file}"
      fi
      cp "chroot/usr/share/applications/${file}" "chroot/usr/local/share/applications"
      sed -i 's|\[Desktop Entry]|[Desktop Entry]\nNoDisplay=true|g' "chroot/usr/local/share/applications/${file}"
    done

    echo "  - Reorganize apps in menu"
    mkdir -p chroot/var/lib/semantic-ux/applications
    IFS=$'\n'
    for line in $(sed "s|#.*||g" "${variant_data_dir}/reorganize-apps.yaml"); do
      IFS=$' '
      file=$(echo $line     | cut -d':' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      category=$(echo $line | cut -d':' -f 2 | cut -d'|' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      name=$(echo $line     | cut -d':' -f 2 | cut -d'|' -f 2 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')

      [ ! -f "chroot/usr/share/applications/${file}" ] && continue;

      cp "chroot/usr/share/applications/${file}" "chroot/var/lib/semantic-ux/applications"
      sed -i "s|^Categories=.*|Categories=${category}|g" "chroot/var/lib/semantic-ux/applications/${file}"

      if [ "${name}" = "%GenericName" ]; then
        awk '
          /^\[Desktop Entry\]/ { in_section=1; print; next }
          /^\[/ { in_section=0 }
          in_section {
            if (/^[[:space:]]*(Name|Comment)(\[.*\])?=/) next
            sub(/^[[:space:]]*GenericName/, "Name")
          }
          { print }
        ' "chroot/var/lib/semantic-ux/applications/${file}" > "chroot/var/lib/semantic-ux/applications/${file}.tmp"
        mv "chroot/var/lib/semantic-ux/applications/${file}.tmp" "chroot/var/lib/semantic-ux/applications/${file}"
      elif  [ "${name}" = "%Name" ]; then
       awk '
          /^\[Desktop Entry\]/ { in_section=1; print; next }
          /^\[/ { in_section=0 }
          in_section {
            if (/^[[:space:]]*(GenericName|Comment)(\[.*\])?=/) next
          }
          { print }
        ' "chroot/var/lib/semantic-ux/applications/${file}" > "chroot/var/lib/semantic-ux/applications/${file}.tmp"
        mv "chroot/var/lib/semantic-ux/applications/${file}.tmp" "chroot/var/lib/semantic-ux/applications/${file}"
      else
        awk -v name="${name}" '
          /^\[Desktop Entry\]/ { in_section=1; print; next }
          /^\[/ { in_section=0 }
          in_section {
            if (/^[[:space:]]*(GenericName|Comment)(\[.*\])?=/) next
            if (/^[[:space:]]*Name(\[.*\])?=/) { sub(/=.*/, "=" name) }
          }
          { print }
        ' "chroot/var/lib/semantic-ux/applications/${file}" > "chroot/var/lib/semantic-ux/applications/${file}.tmp"
        mv "chroot/var/lib/semantic-ux/applications/${file}.tmp" "chroot/var/lib/semantic-ux/applications/${file}"
      fi

      cp "chroot/var/lib/semantic-ux/applications/${file}" "chroot/usr/local/share/applications"
    done
    IFS=$' '

    echo "  - Split KDE Plasma Settings in KCM menu items"
    IFS=$'\n'
    for line in $(sed "s|#.*||g" "${variant_data_dir}/plasma-kcms.yaml"); do
      IFS=$' '
      name=$(echo $line     | cut -d':' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      icon=$(echo $line | cut -d':' -f 2 | cut -d'|' -f 1 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
      kcms=$(echo $line     | cut -d':' -f 2 | cut -d'|' -f 2 | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')

      (
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Exec=kcmshell6 ${kcms}"
        echo "Icon=${icon}"
        echo "Name=Configurar: ${name}"
        echo "Categories=System"
      ) > "chroot/usr/local/share/applications/kcm_${icon}.desktop"
    done
    IFS=$' '

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

function install-electron {
    show-header "Install Electron.js" 

    mkdir -p chroot/usr/lib/electron
    
    wget -qO- https://github.com/electron/electron/releases/download/v44.1.0/electron-v44.1.0-linux-x64.zip \
      | bsdtar -x -f - -C chroot/usr/lib/electron
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
        target=$(chroot "chroot" readlink -f "${target}");
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
    
    echo "  - Cleaning up APT"
    chroot "chroot" apt clean
    chroot "chroot" apt -q modernize-sources -y

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

    (
        sed "s|#.*||g" "${variant_data_dir}/grub-entries.yaml"  | sed '/^$/d' | sed 's|^|menuentry |;s|$|\n  initrd /casper/initrd\n}\n|;s|:| {\n  |'
        
        echo "menuentry \"Reboot\" {reboot}"
        echo "menuentry \"Shutdown\" {halt}"
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

        grub-mkstandalone                                   \
          --format=x86_64-efi                               \
          --output=isolinux/bootx64.efi                     \
          --locales=""                                      \
          --fonts="" "boot/grub/grub.cfg=isolinux/grub.cfg"

        (
            cd isolinux 
            dd if=/dev/zero of=efiboot.img bs=1M count=10
            mkfs.vfat efiboot.img
            mmd -i efiboot.img efi efi/boot
            mcopy -i efiboot.img ./bootx64.efi ::efi/boot/
        )
        
        grub-mkstandalone --format=i386-pc --output=isolinux/core.img                      \
          --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls"  \
          --modules="linux16 linux normal iso9660 biosdisk search" --locales="" --fonts="" \
          "boot/grub/grub.cfg=isolinux/grub.cfg"
          
        cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img
    )
}

function build-iso {
    show-header "Generate ISO image"

    cd image

    mkdir -pv ".disk"
    echo "${name} ${system_version} \"${code_name}\" - Daily amd64 $(date +%y.0.%-m-%-d)" > .disk/info

    bash -c '(find . -type f -print0 | xargs -0 md5sum | grep -v "\./md5sum.txt" > md5sum.txt)'
    mkdir -pv ../iso

    xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames        \
      -volid "${name}" -eltorito-boot boot/grub/bios.img            \
      -no-emul-boot -boot-load-size 4 -boot-info-table              \
      --eltorito-catalog boot/grub/boot.cat --grub2-boot-info       \
      --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img             \
      -eltorito-alt-boot -e /EFI/BOOT/BOOTX64.efi                   \
      -no-emul-boot -append_partition 2 0xef isolinux/efiboot.img   \
      -output "../iso/${name}-amd64.iso" -graft-points "."          \
        /boot/grub/bios.img=isolinux/bios.img                       \
        /EFI/BOOT/BOOTX64.efi=isolinux/efiboot.img
         
    md5sum ../iso/${name}-amd64.iso > ../iso/${name}-amd64.md5
    
    ISO=$(readlink -f ../iso/${name}-amd64.iso)

    cd ..
    
    if [ -f "${ISO}" ]; then
        echo
        echo "  ISO image file: "
        echo "    "$( du -sh "${ISO}")
        echo
        
        return
    fi

    echo "Failed to generate ISO"
    exit 1
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
  shift;
  shift;
  chroot "chroot" "$@"
}
#-----------------------------------------------------------------------------------------------------------------------------------------
--run-step() {
  option=$(grep '^function' "${script}" | cut -d' ' -f2 | grep -- ^"${1}"$)

  if [ "${1}" = "--enter-chroot" ] || [ "${1}" = "--chroot" ]; then
    option="${1}";
  fi

  if [ ! "${option}" == "" ]; then
    step_count=3

    show-header "Initialize virtual FS"
    --bind-mount


    "${option}" "$@"

    show-header "Finish virtual FS" 
    --bind-umount

    echo
    exit
  fi
  echo "Unknown option '${1}' availables:"
  echo
  grep '^function' "${script}" | cut -d' ' -f2  | grep "" | sort | sed 's|^|  * |'
  echo
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

if [ "${url}" = "" ]; then
  iso_repository="https://cdimage.ubuntu.com/${flavour}/releases/${base}/release/"
  iso_file=$(wget -q -O - "${iso_repository}" | grep -o "kubuntu-${base}.*amd64.iso" | head -n1)
  url="https://cdimage.ubuntu.com/kubuntu/releases/${base}/release/${iso_file}"
fi
#-----------------------------------------------------------------------------------------------------------------------------------------
mkdir -p ${variant}
cd ${variant}
mkdir -p iso chroot image/{boot/grub,casper,isolinux,preseed} ;
#-----------------------------------------------------------------------------------------------------------------------------------------
if [ ! "${2}" = "" ]; then
  --run-step "${2}";
fi
#-----------------------------------------------------------------------------------------------------------------------------------------
if [ -f "${variant_data_dir}/BuildSteps" ]; then
  cat "${variant_data_dir}/BuildSteps" | while read step;do
    source "${variant_data_dir}/distro.ini";
    --run-step "${step}";
  done
fi
#-----------------------------------------------------------------------------------------------------------------------------------------

eval "$(grep '^function' ${script} | cut -d' ' -f2 | tr '\n' '\r' | sed 's|\r|;source \"${variant_data_dir}/distro.ini\";|g')"

#-----------------------------------------------------------------------------------------------------------------------------------------

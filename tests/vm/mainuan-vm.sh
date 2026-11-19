#!/usr/bin/env bash
# Local test VM for Mainuan ISOs (libvirt / QEMU / KVM).
#
#   tests/vm/mainuan-vm.sh create <image.iso> [name] [--bios] [--small]
#   tests/vm/mainuan-vm.sh snapshot <name> <snapshot> [description]
#   tests/vm/mainuan-vm.sh snapshots <name>
#   tests/vm/mainuan-vm.sh eject <name>          # boot from the disk next time
#   tests/vm/mainuan-vm.sh screenshot <name> <file.png>
#
# Safety: only domains and volumes whose name starts with "mainuan-test" are
# created or touched; an existing domain or volume is never overwritten.
# Images go to the libvirt "default" storage pool through libvirt itself.
set -euo pipefail

CONNECT="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
POOL="${MAINUAN_VM_POOL:-default}"
virsh() { command virsh -c "${CONNECT}" "$@"; }

guard_name() {
  case "$1" in
    mainuan-test*) ;;
    *) echo "Refusing to manage '$1': names must start with 'mainuan-test'." >&2; exit 1 ;;
  esac
}

create() {
  local iso="$1" name="${2:-mainuan-test}" firmware=uefi memory=6144 cpus=4 disk=60
  shift 2 || shift $#
  for option in "$@"; do
    case "${option}" in
      --bios) firmware=bios ;;
      --small) memory=4096 cpus=2 disk=40 ;;
      *) echo "Unknown option ${option}" >&2; exit 1 ;;
    esac
  done
  guard_name "${name}"
  [ -f "${iso}" ] || { echo "ISO not found: ${iso}" >&2; exit 1; }

  if virsh dominfo "${name}" > /dev/null 2>&1; then
    echo "Domain ${name} already exists; nothing changed." >&2; exit 1
  fi
  for volume in "${name}.qcow2" "${name}.iso"; do
    if virsh vol-info --pool "${POOL}" "${volume}" > /dev/null 2>&1; then
      echo "Volume ${volume} already exists in pool ${POOL}; nothing changed." >&2; exit 1
    fi
  done

  echo "Uploading the ISO to pool ${POOL} as ${name}.iso"
  virsh vol-create-as "${POOL}" "${name}.iso" "$(stat -c %s "${iso}")" --format raw > /dev/null
  virsh vol-upload --pool "${POOL}" "${name}.iso" "${iso}"
  virsh vol-create-as "${POOL}" "${name}.qcow2" "${disk}G" --format qcow2 > /dev/null

  local boot="uefi,cdrom,hd"
  [ "${firmware}" = bios ] && boot="cdrom,hd"

  virt-install --connect "${CONNECT}" --name "${name}" \
    --osinfo ubuntu26.04 --memory "${memory}" --vcpus "${cpus}" --cpu host-passthrough \
    --boot "${boot}" \
    --disk "vol=${POOL}/${name}.qcow2,bus=virtio" \
    --disk "vol=${POOL}/${name}.iso,device=cdrom,bus=sata,readonly=on" \
    --network network=default,model=virtio \
    --graphics spice --video virtio --channel spicevmc \
    --serial pty --console pty,target_type=serial \
    --sound ich9 --rng /dev/urandom \
    --noautoconsole
  echo "Domain ${name} created (${firmware}, ${cpus} vCPU, ${memory} MiB, ${disk} GB)."
}

case "${1:-}" in
  create) shift; create "$@" ;;
  snapshot)
    guard_name "$2"
    virsh snapshot-create-as "$2" "$3" "${4:-}" --disk-only --atomic ;;
  snapshots) guard_name "$2"; virsh snapshot-list "$2" --tree ;;
  eject)
    guard_name "$2"
    target="$(virsh domblklist "$2" --details | awk '$2 == "cdrom" {print $3; exit}')"
    # --config alone only applies at the next cold start: a reboot from the
    # guest (Calamares' "Restart now") keeps the running QEMU and its CD.
    scopes=(--config)
    [ "$(LC_ALL=C virsh domstate "$2")" = running ] && scopes+=(--live)
    for scope in "${scopes[@]}"; do
      out="$(LC_ALL=C virsh change-media "$2" "${target}" --eject "${scope}" 2>&1)" \
        || grep -q "doesn't have media" <<< "${out}" || { echo "${out}" >&2; exit 1; }
    done
    echo "CD ejected (${scopes[*]})" ;;
  screenshot) guard_name "$2"; virsh screenshot "$2" "$3" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac

#!/bin/busybox sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# To bootstrap the factory installer on rootfs. This file must be executed as
# PID=1 (exec).
# Note that this script uses the busybox shell (not bash, not dash).

#original: https://chromium.googlesource.com/chromiumos/platform/initramfs/+/refs/heads/main/factory_shim/bootstrap.sh

#set -x
set +x

AUTO_BOOT_DEVICE="/dev/mmcblk0p1"
AUTO_BOOT_LABEL="fixcraft_rootfs-iridium"
AUTO_BOOT_LABEL_LEGACY="fixcraft_rootfs:iridium"
AUTO_BOOT_LABELS="${AUTO_BOOT_LABEL} ${AUTO_BOOT_LABEL_LEGACY}"
CHROMIFY_DISK="/dev/mmcblk0"
FORBIDDEN_DEVICE="/dev/sda4"
ADMINBOOT_SENTINEL="/tmp/.adminboot"
ADMINBOOT_HELPER="/tmp/adminboot"
SDA_DISK="/dev/sda"
SDB_DISK="/dev/sdb"
SDB_KERNEL_LABEL="kernel"

case ":$PATH:" in
  *":/tmp:"*) ;;
  *) PATH="/tmp:${PATH}" ;;
esac
export PATH

rescue_mode=""

have() {
  command -v "$1" >/dev/null 2>&1
}

admin_boot_enabled() {
  [ -f "$ADMINBOOT_SENTINEL" ]
}

unlock_adminboot() {
  touch "$ADMINBOOT_SENTINEL"
}

resolve_prompt_tty() {
  local preferred="$1"
  local candidate=""

  for candidate in "$preferred" "${TTY1:-}" "/dev/tty" "/dev/console"; do
    if [ "$candidate" ] && [ "$candidate" != "/dev/null" ] &&
       [ -r "$candidate" ] && [ -w "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  if [ -t 0 ]; then
    echo ""
    return 0
  fi

  echo ""
  return 0
}

cecho() {
  local tty
  tty="$(resolve_prompt_tty "${TTY1:-}")"
  if [ "$tty" ]; then
    echo "$*" >"$tty"
  else
    echo "$*"
  fi
}

install_adminboot_helper() {
  rm -f "$ADMINBOOT_SENTINEL" "$ADMINBOOT_HELPER"
  cat <<EOF > "$ADMINBOOT_HELPER"
#!/bin/busybox sh
touch "$ADMINBOOT_SENTINEL"
echo "Admin boot unlocked for $FORBIDDEN_DEVICE."
echo "Type 'exit' (or press Ctrl+D) to return to the boot menu."
EOF
  chmod +x "$ADMINBOOT_HELPER"
  if [ -e /bin/adminboot ]; then
    rm -f /bin/adminboot 2>/dev/null || true
  fi
}

invoke_terminal() {
  local tty="$1"
  local title="$2"
  shift
  shift
  # Copied from factory_installer/factory_shim_service.sh.
  echo "${title}" >>${tty}
  setsid sh -c "exec script -afqc '$*' /dev/null <${tty} >>${tty} 2>&1 &"
}

enable_debug_console() {
  local tty="$1"
  echo -e "debug console enabled on ${tty}"
  invoke_terminal "${tty}" "[Bootstrap Debug Console]" "/bin/busybox sh"
}

open_shell_and_wait() {
  local tty="$1"
  local shell_bin="/bin/busybox"
  local shell_arg="sh"
  local shell_pid=""

  echo "Launching shell on ${tty}. Run 'adminboot' to unlock ${FORBIDDEN_DEVICE}, then type 'exit' or press Ctrl+D to return." >"${tty}"

  if have setsid; then
    if have cttyhack; then
      setsid cttyhack "$shell_bin" "$shell_arg" <"${tty}" >"${tty}" 2>&1 &
    elif have script; then
      setsid script -afqc "${shell_bin} ${shell_arg}" /dev/null <"${tty}" >"${tty}" 2>&1 &
    else
      setsid "$shell_bin" "$shell_arg" <"${tty}" >"${tty}" 2>&1 &
    fi
    shell_pid=$!
    if [ "$shell_pid" ]; then
      wait "$shell_pid" 2>/dev/null || true
    fi
  else
    if have cttyhack; then
      cttyhack "$shell_bin" "$shell_arg" <"${tty}" >"${tty}" 2>&1
    elif have script; then
      script -afqc "${shell_bin} ${shell_arg}" /dev/null <"${tty}" >"${tty}" 2>&1
    else
      "$shell_bin" "$shell_arg" <"${tty}" >"${tty}" 2>&1
    fi
  fi
}

refresh_boot_menu_console() {
  local tty="$1"
  if have stty; then
    stty sane <"${tty}" >/dev/null 2>&1 || true
  fi
  printf '\033c' >"${tty}" 2>/dev/null || true
}

read_secret() {
  local prompt="$1"
  local input=""
  local stty_used=""
  local target_tty=""

  target_tty="$(resolve_prompt_tty "${TTY1:-}")"

  if [ "$target_tty" ]; then
    printf "%s" "$prompt" >"$target_tty"
    if have stty && stty -F "$target_tty" -echo >/dev/null 2>&1; then
      stty_used="$target_tty"
    fi
    IFS= read -r input <"$target_tty" || input=""
    if [ "$stty_used" ]; then
      stty -F "$stty_used" echo >/dev/null 2>&1 || true
    fi
    printf '\n' >"$target_tty" 2>/dev/null || true
  else
    printf "%s" "$prompt"
    if have stty && [ -t 0 ] && stty -echo >/dev/null 2>&1; then
      stty_used="stdin"
    fi
    IFS= read -r input || input=""
    if [ "$stty_used" = "stdin" ]; then
      stty echo >/dev/null 2>&1 || true
    fi
    echo
  fi

  echo "$input"
}

prompt_read() {
  local prompt="$1"
  local preferred="$2"
  local input=""
  local target_tty=""

  target_tty="$(resolve_prompt_tty "$preferred")"

  if [ "$target_tty" ]; then
    printf "%s" "$prompt" >"$target_tty"
    IFS= read -r input <"$target_tty" || input=""
    printf '\n' >"$target_tty" 2>/dev/null || true
  else
    printf "%s" "$prompt"
    IFS= read -r input || input=""
    echo
  fi

  echo "$input"
}

write_base64_single_line() {
  local data="$1"
  local dest="$2"
  printf '%s' "$data" | base64 | tr -d '\n' >"$dest"
}

update_mmc_passphrase() {
  local device="$1"
  local base_pass="ILoveHentaiHentaiHentai0"

  if ! have cryptsetup; then
    echo "cryptsetup not available; skipping passphrase update."
    return 0
  fi

  if ! cryptsetup isLuks "$device" >/dev/null 2>&1; then
    echo "$device is not a LUKS volume; skipping passphrase update."
    return 0
  fi

  local suffix=""
  local confirm=""
  local new_pass=""
  local old_tmp="/tmp/.luks_old.$$"
  local new_tmp="/tmp/.luks_new.$$"

  while :; do
    suffix="$(read_secret "NEW PASSPHRASE: ")"
    if [ ! "$suffix" ]; then
      echo "No passphrase provided; skipping passphrase update."
      return 0
    fi
    confirm="$(read_secret "Confirm new passphrase: ")"
    if [ "$suffix" != "$confirm" ]; then
      echo "Passphrases do not match. Try again."
      continue
    fi
    new_pass="${base_pass}${suffix}"
    printf "%s" "$base_pass" >"$old_tmp"
    printf "%s" "$new_pass" >"$new_tmp"

    if cryptsetup luksAddKey "$device" --key-file "$old_tmp" --new-keyfile "$new_tmp"; then
      if ! cryptsetup luksRemoveKey "$device" --key-file "$old_tmp"; then
        echo "Warning: unable to remove old LUKS key."
      fi
      echo "Updated LUKS passphrase on ${device}."
      rm -f "$old_tmp" "$new_tmp"
      suffix='' ; confirm='' ; new_pass='' ; unset suffix confirm new_pass
      return 0
    fi

    rm -f "$old_tmp" "$new_tmp"
    echo "Failed to add new LUKS key; keeping existing passphrase."
    local retry=""
    retry="$(prompt_read "Retry passphrase update? (Y/n): " "${TTY1:-}")"
    case "${retry:-Y}" in
      [Yy]* )
        continue
        ;;
      * )
        suffix='' ; confirm='' ; new_pass='' ; unset suffix confirm new_pass
        return 0
        ;;
    esac
  done

  return 0
}

get_partition_label() {
  local dev="$1"

  if [ -z "$dev" ]; then
    return 1
  fi

  if command -v lsblk >/dev/null 2>&1; then
    local label="$(lsblk -no PARTLABEL "$dev" 2>/dev/null | head -n 1)"
    if [ "$label" ]; then
      echo "$label"
      return 0
    fi

    label="$(lsblk -no LABEL "$dev" 2>/dev/null | head -n 1)"
    if [ "$label" ]; then
      echo "$label"
      return 0
    fi
  fi

  if command -v blkid >/dev/null 2>&1; then
    local label="$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null)"
    if [ "$label" ]; then
      echo "$label"
      return 0
    fi

    label="$(blkid -s LABEL -o value "$dev" 2>/dev/null)"
    if [ "$label" ]; then
      echo "$label"
      return 0
    fi
  fi

  return 1
}

#get a partition block device from a disk path and a part number
get_part_dev() {
  local disk="$1"
  local partition="$2"

  #disk paths ending with a number will have a "p" before the partition number
  last_char="$(echo -n "$disk" | tail -c 1)"
  if [ "$last_char" -eq "$last_char" ] 2>/dev/null; then
    echo "${disk}p${partition}"
  else
    echo "${disk}${partition}"
  fi
}

find_rootfs_partitions() {
  local disks=$(fdisk -l | sed -n "s/Disk \(\/dev\/.*\):.*/\1/p")
  if [ ! "${disks}" ]; then
    return 1
  fi

  for disk in $disks; do
    local partitions=$(fdisk -l $disk | sed -n "s/^[ ]\+\([0-9]\+\).*fixcraft_rootfs[-:]\(.*\)$/\1:\2/p")
    if [ ! "${partitions}" ]; then
      continue
    fi
    for partition in $partitions; do
      local part_number="$(echo "$partition" | cut -d ":" -f 1)"
      local part_name="$(echo "$partition" | cut -d ":" -f 2)"
      local part_dev="$(get_part_dev "$disk" "$part_number")"

      if [ "$part_dev" = "$FORBIDDEN_DEVICE" ] && ! admin_boot_enabled; then
        continue
      fi

      if [ ! "$part_name" ]; then
        part_name="$part_dev"
      fi

      echo "${part_dev}:${part_name}:FixCraft"
    done
  done
}

find_chromeos_partitions() {
  local roota_partitions="$(cgpt find -l ROOT-A)"
  local rootb_partitions="$(cgpt find -l ROOT-B)"

  if [ "$roota_partitions" ]; then
    for partition in $roota_partitions; do
      if [ "$partition" = "$FORBIDDEN_DEVICE" ] && ! admin_boot_enabled; then
        continue
      fi
      echo "${partition}:ChromeOS_ROOT-A:CrOS"
    done
  fi
  
  if [ "$rootb_partitions" ]; then
    for partition in $rootb_partitions; do
      if [ "$partition" = "$FORBIDDEN_DEVICE" ] && ! admin_boot_enabled; then
        continue
      fi
      echo "${partition}:ChromeOS_ROOT-B:CrOS"
    done
  fi
}

find_all_partitions() {
  find_chromeos_partitions
  find_rootfs_partitions
}

#from original bootstrap.sh
move_mounts() {
  local base_mounts="/sys /proc /dev"
  local newroot_mnt="$1"
  for mnt in $base_mounts; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    mkdir -p "$newroot_mnt$mnt"
    mount -n -o move "$mnt" "$newroot_mnt$mnt"
  done
}

print_license() {
  local shimboot_version="$(cat /opt/.shimboot_version)"
  if [ -f "/opt/.shimboot_version_dev" ]; then
    local git_hash="$(cat /opt/.shimboot_version_dev)"
    local suffix="-dev-$git_hash"
  fi
  cat << EOF 
BOOT ${shimboot_version}${suffix}

Shimboot FORK
Copyright (C) 2025 FixCraft Inc.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
EOF
}

clone_sda_to_sdb() {
  local src_disk="$1"
  local dst_disk="$2"

  if [ ! -b "$dst_disk" ]; then
    return 0
  fi

  if ! have sgdisk; then
    echo "sgdisk not available; skipping clone to ${dst_disk}."
    return 0
  fi

  echo ">>> Cloning ${src_disk} partitions 1-3 into ${dst_disk}"

  local info3 end_sector total_sectors total_bytes
  if ! info3="$(sgdisk -i 3 "$src_disk" 2>/dev/null)"; then
    echo "Partition 3 missing on ${src_disk}; cannot determine clone size."
    return 1
  fi
  end_sector="$(echo "$info3" | sed -n 's/^[ ]*Last sector: \([0-9]\+\).*/\1/p')"
  if [ ! "$end_sector" ]; then
    echo "Unable to locate last sector for ${src_disk}3."
    return 1
  fi
  total_sectors=$((end_sector + 1))
  total_bytes=$((total_sectors * 512))

  if have blockdev; then
    local dst_sectors
    dst_sectors="$(blockdev --getsz "$dst_disk" 2>/dev/null)"
    if [ "$dst_sectors" ] && [ "$dst_sectors" -le "$end_sector" ]; then
      echo "${dst_disk} is too small to hold partitions 1-3 from ${src_disk}."
      return 1
    fi
  fi

  echo ">>> Copying ${total_sectors} sectors (${total_bytes} bytes)"
  if have pv; then
    dd if="$src_disk" bs=512 count="$total_sectors" conv=sync,noerror \
      2>/dev/null | pv -s "$total_bytes" | dd of="$dst_disk" bs=512 conv=fsync,noerror
  else
    dd if="$src_disk" of="$dst_disk" bs=512 count="$total_sectors" conv=sync,fsync,noerror
  fi
  sync

  if have sgdisk; then
    # Ensure backup GPT is rewritten for the destination size.
    sgdisk -e "$dst_disk" >/dev/null 2>&1 || true

    # Remove partitions beyond #3 so we do not expose incomplete copies.
    local part_list part_to_drop
    part_list="$(sgdisk -p "$dst_disk" 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{print $1}' | sort -rn)"
    for part_to_drop in $part_list; do
      if [ "$part_to_drop" -gt 3 ]; then
        sgdisk -d "$part_to_drop" "$dst_disk" >/dev/null 2>&1 || true
      fi
    done
    sgdisk -e "$dst_disk" >/dev/null 2>&1 || true
  fi

  if have partx; then
    partx -u "$dst_disk" || true
  fi
  if have blockdev; then
    blockdev --rereadpt "$dst_disk" || true
  fi
  sleep 1

  echo ">>> ${dst_disk} clone complete."
  return 0
}

print_selector() {
  local rootfs_partitions="$1"
  local i=1

  echo "┌────────────────────────┐"
  echo "│ FixCraft Boot Selector │"
  echo "└────────────────────────┘"

  if [ "${rootfs_partitions}" ]; then
    for rootfs_partition in $rootfs_partitions; do
      #i don't know of a better way to split a string in the busybox shell
      local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
      local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)
      local locked=""
      if [ "$part_path" = "$FORBIDDEN_DEVICE" ] && ! admin_boot_enabled; then
        locked=" (locked - run adminboot)"
      fi
      echo "${i}) ${part_name} on ${part_path}${locked}"
      i=$((i+1))
    done
  else
    echo "no bootable partitions found. please see the shimboot documentation to mark a partition as bootable."
  fi

  echo "g) manage crypto"
  echo "q) reboot"
  echo "s) enter a shell"
  echo "c) chromify"
  echo "u) erase mmc"
  echo "l) view license"
}

chromify_mmc() {
  clear
  set -e

  local DEV="$CHROMIFY_DISK"
  local SRC="${SDA_DISK}4"
  local P1="${DEV}p1"
  local START=110592
  local END=18874367
  local SIZE=$((END - START + 1))
  local PARTLABEL="$AUTO_BOOT_LABEL"

  echo ">>> WIPING old signatures (best effort)…"
  have wipefs && wipefs -a "$DEV" 2>/dev/null || true

  echo ">>> CARVING GPT + p1…"
  if have sgdisk; then
    sgdisk -Z "$DEV"
    sgdisk -o "$DEV"
    sgdisk -n 1:${START}:${END} -t 1:8300 -c 1:"$PARTLABEL" "$DEV"
  elif have sfdisk; then
    printf 'label: gpt\nunit: sectors\n%s : start=%s, size=%s, type=8300, name="%s"\n' \
      "$P1" "$START" "$SIZE" "$PARTLABEL" | sfdisk "$DEV"
  else
    echo "Need sgdisk or sfdisk to continue."
    exit 1
  fi

  echo ">>> TELL KERNEL to reread partition table…"
  if have partx; then
    partx -u "$DEV" || true
  fi
  if have blockdev; then
    blockdev --rereadpt "$DEV" || true
  fi
  sleep 1

  echo ">>> VERIFY partition exists…"
  if ! [ -b "$P1" ]; then
    echo "$P1 not found. Check drivers/kernel/utils."
    exit 2
  fi

  if have lsblk; then
    lsblk -o NAME,START,SECTORS,TYPE,PARTLABEL,PARTTYPE "$DEV" || true
  fi

  echo ">>> DD copy ${SRC} -> ${P1} …"
  if have pv; then
    pv "$SRC" | dd of="$P1" bs=4M conv=fsync,noerror
  else
    dd if="$SRC" of="$P1" bs=4M conv=fsync,noerror
  fi
  sync

  echo ">>> Ensuring GPT PARTLABEL is ${PARTLABEL}"
  if have sgdisk; then
    sgdisk --change-name=1:"$PARTLABEL" "$DEV" || true
  else
    echo "Unable to adjust PARTLABEL without sgdisk."
  fi

  update_mmc_passphrase "$P1"

  clone_sda_to_sdb "$SDA_DISK" "$SDB_DISK"

  echo "Done: GPT carved, PARTLABEL set, data copied."
  sleep 1
  clear
  reboot -f
}

erase_mmc() {
  clear
  local DEV="$CHROMIFY_DISK"
  local P1="${DEV}p1"

  echo "!!! ERASE MODE !!!"
  echo "This will zap partition tables and overwrite part of ${DEV}."
  confirm="$(prompt_read "Type ERASE to continue (anything else cancels): " "${TTY1:-}")"
  if [ "$confirm" != "ERASE" ]; then
    echo "Erase cancelled."
    sleep 1
    return 1
  fi

  echo ">>> Zapping GPT on ${DEV}"
  if have sgdisk; then
    sgdisk -Z "$DEV"
    sgdisk -o "$DEV"
    sgdisk -n 1:0:0 -t 1:8300 -c 1:"${AUTO_BOOT_LABEL}" "$DEV"
  elif have sfdisk; then
    dd if=/dev/zero of="$DEV" bs=1M count=8 conv=fsync >/dev/null 2>&1 || true
    printf 'label: gpt\n, type=8300, name="%s"\n' "$AUTO_BOOT_LABEL" | sfdisk "$DEV"
  else
    echo "Need sgdisk or sfdisk to erase ${DEV}."
    sleep 2
    return 1
  fi

  if have partx; then
    partx -u "$DEV" || true
  fi
  if have blockdev; then
    blockdev --rereadpt "$DEV" || true
  fi
  sleep 1

  if ! [ -b "$P1" ]; then
    echo "Partition ${P1} not found after erase."
    sleep 2
    return 1
  fi

  echo ">>> Quick zeroing ${P1} (about 3 seconds)..."
  dd if=/dev/zero of="$P1" bs=4M count=8 conv=fsync,noerror 2>/dev/null || true
  sync

  echo "✅ ${DEV} erased and reinitialized."
  sleep 2
  return 0
}

mmc_has_cros_root() {
  local partitions="$1"

  for partition in $partitions; do
    if [ ! "$partition" ]; then
      continue
    fi
    local part_path="$(echo "$partition" | cut -d ":" -f 1)"
    local part_flags="$(echo "$partition" | cut -d ":" -f 3)"

    case "$part_path" in
      ${CHROMIFY_DISK}*)
        if [ "$part_flags" = "CrOS" ]; then
          return 0
        fi
        ;;
    esac
  done

  return 1
}

auto_boot_from_mmc() {
  local partitions="$1"

  if [ ! -b "$AUTO_BOOT_DEVICE" ]; then
    return 1
  fi

  local mmc_label=""
  local mmc_flags=""

  for partition in $partitions; do
    if [ ! "$partition" ]; then
      continue
    fi
    local part_path="$(echo "$partition" | cut -d ":" -f 1)"
    local part_name="$(echo "$partition" | cut -d ":" -f 2)"
    local part_flags="$(echo "$partition" | cut -d ":" -f 3)"

    if [ "$part_path" = "$AUTO_BOOT_DEVICE" ]; then
      mmc_label="$part_name"
      mmc_flags="$part_flags"
      break
    fi
  done

  if [ ! "$mmc_label" ]; then
    local detected_label="$(get_partition_label "$AUTO_BOOT_DEVICE")"
    if [ ! "$detected_label" ]; then
      return 1
    fi

    local label_ok=""
    for candidate in $AUTO_BOOT_LABELS; do
      if [ "$detected_label" = "$candidate" ]; then
        label_ok="1"
        break
      fi
    done

    if [ ! "$label_ok" ]; then
      return 1
    fi

    mmc_label="$detected_label"
  else
    if [ "$mmc_flags" = "CrOS" ]; then
      return 1
    fi
  fi

  if [ ! "$mmc_label" ]; then
    mmc_label="$AUTO_BOOT_DEVICE"
  fi

  echo
  echo "Detected ${AUTO_BOOT_DEVICE} (${mmc_label})."
  echo "Booting in 5 seconds... Press Enter to cancel."
  if read -t 5 -r _; then
    echo "Auto boot cancelled."
    sleep 1
    return 1
  fi

  boot_target "$AUTO_BOOT_DEVICE"
}

maybe_chromify_mmc() {
  local partitions="$1"

  if ! mmc_has_cros_root "$partitions"; then
    return 1
  fi

  echo
  echo "Chromifying in 5 seconds... Press Enter to cancel."
  if read -t 5 -r _; then
    echo "Chromify cancelled."
    sleep 1
    return 1
  fi

  chromify_mmc
}

get_selection() {
  local rootfs_partitions="$1"
  local i=1

  selection="$(prompt_read "Your selection: " "${TTY1:-}")"

  if [ "$selection" = "adminboot.sda4" ]; then
    if [ ! -b "$FORBIDDEN_DEVICE" ]; then
      echo "${FORBIDDEN_DEVICE} not available."
      sleep 1
      return 1
    fi
    unlock_adminboot
    echo "Admin boot override triggered. Booting ${FORBIDDEN_DEVICE}."
    sleep 1
    boot_target "$FORBIDDEN_DEVICE"
    return 1
  fi
  if [ "$selection" = "q" ]; then
    echo "rebooting now."
    reboot -f
  elif [ "$selection" = "s" ]; then
    refresh_boot_menu_console "$TTY1"
    open_shell_and_wait "$TTY1"
    refresh_boot_menu_console "$TTY1"
    sleep 1
    return 0
  elif [ "$selection" = "g" ]; then
    manage_crypto_menu "$rootfs_partitions"
    return 0
  elif [ "$selection" = "c" ]; then
    chromify_mmc
    return 0
  elif [ "$selection" = "u" ]; then
    erase_mmc
    return 0
  elif [ "$selection" = "l" ]; then
   clear
    print_license
    echo
    : "$(prompt_read "press [enter] to return to the bootloader menu" "${TTY1:-}")"
    return 1
  fi

  local selection_cmd="$(echo "$selection" | cut -d' ' -f1)"
  if [ "$selection_cmd" = "rescue" ]; then
    selection="$(echo "$selection" | cut -d' ' -f2-)"
    rescue_mode="1"
  else
    rescue_mode=""
  fi

  for rootfs_partition in $rootfs_partitions; do
    local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
    local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)
    local part_flags=$(echo $rootfs_partition | cut -d ":" -f 3)

    if [ "$selection" = "$i" ]; then
      echo "selected $part_path"
      if [ "$part_flags" = "CrOS" ]; then
        echo "booting chrome os partition"
        print_donor_selector "$rootfs_partitions"
        get_donor_selection "$rootfs_partitions" "$part_path"
      else
        if [ "$part_path" = "$FORBIDDEN_DEVICE" ] && ! admin_boot_enabled; then
          echo "Admin boot required. Run adminboot in the debug shell first."
          sleep 1
          return 1
        fi
        boot_target "$part_path"
      fi
      return 1
    fi

    i=$((i+1))
  done
  
  echo "invalid selection"
  sleep 1
  return 1
}

copy_progress() {
  local source="$1"
  local destination="$2"
  mkdir -p "$destination"
  tar -cf - -C "${source}" . | pv -f | tar -xf - -C "${destination}"
}

print_donor_selector() {
  local rootfs_partitions="$1"
  local i=1;

  echo "Choose a partition to copy firmware and modules from:";

  for rootfs_partition in $rootfs_partitions; do
    local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
    local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)
    local part_flags=$(echo $rootfs_partition | cut -d ":" -f 3)

    if [ "$part_flags" = "CrOS" ]; then
      continue;
    fi

    echo "${i}) ${part_name} on ${part_path}"
    i=$((i+1))
  done
}

yes_no_prompt() {
  local prompt="$1"
  local var_name="$2"

  while true; do
    temp_result="$(prompt_read "$prompt" "${TTY1:-}")"

    if [ "$temp_result" = "y" ] || [ "$temp_result" = "n" ]; then
      #the busybox shell has no other way to declare a variable from a string
      #the declare command and printf -v are both bashisms
      eval "$var_name='$temp_result'"
      return 0
    else
      echo "invalid selection"
    fi
  done
}

manage_crypto_menu() {
  local partitions="$1"

  if ! have cryptsetup; then
    cecho "cryptsetup not available; crypto management disabled."
    sleep 2
    return 0
  fi

  while true; do
    echo
    echo "Crypto management"
    echo "1) change passphrase"
    echo "x) back"
    local choice
    choice="$(prompt_read "Selection: " "${TTY1:-}")"
    case "$choice" in
      1 )
        crypto_change_passphrase "$partitions"
        ;;
      x|X )
        return 0
        ;;
      * )
        cecho "invalid selection"
        sleep 1
        ;;
    esac
  done
}

crypto_change_passphrase() {
  local partitions="$1"
  local candidates=""
  local entry=""

  for entry in $partitions; do
    local part_path="$(echo "$entry" | cut -d ':' -f 1)"
    local part_name="$(echo "$entry" | cut -d ':' -f 2)"
    local part_flags="$(echo "$entry" | cut -d ':' -f 3)"

    if [ "$part_flags" != "FixCraft" ]; then
      continue
    fi

    if cryptsetup luksDump "$part_path" >/dev/null 2>&1; then
      candidates="${candidates}${part_path}:${part_name} "
    fi
  done

  if [ ! "$candidates" ]; then
    cecho "No LUKS FixCraft partitions detected."
    sleep 2
    return 0
  fi

  echo
  echo "Select a partition to change its passphrase:"
  local idx=1
  for entry in $candidates; do
    local part_path="$(echo "$entry" | cut -d ':' -f 1)"
    local part_name="$(echo "$entry" | cut -d ':' -f 2)"
    echo "${idx}) ${part_name} on ${part_path}"
    idx=$((idx+1))
  done

  local selection
  selection="$(prompt_read "Selection (x to cancel): " "${TTY1:-}")"
  if [ "$selection" = "x" ] || [ "$selection" = "X" ]; then
    return 0
  fi

  idx=1
  for entry in $candidates; do
    local part_path="$(echo "$entry" | cut -d ':' -f 1)"
    local part_name="$(echo "$entry" | cut -d ':' -f 2)"
    if [ "$selection" = "$idx" ]; then
      crypto_change_passphrase_device "$part_path" "$part_name"
      return 0
    fi
    idx=$((idx+1))
  done

  cecho "invalid selection"
  sleep 1
  return 0
}

crypto_change_passphrase_device() {
  local device="$1"
  local name="$2"
  local current=""
  local new_pass=""
  local confirm=""
  local retry=""
  local old_tmp="/tmp/.luks_change_old.$$"
  local new_tmp="/tmp/.luks_change_new.$$"

  while :; do
    echo
    cecho "Changing passphrase for ${name} (${device})"
    current="$(read_secret "Current passphrase: ")"
    if [ ! "$current" ]; then
      cecho "Cancelled passphrase update for ${device}."
      rm -f "$old_tmp" "$new_tmp"
      return 1
    fi
    new_pass="$(read_secret "New passphrase: ")"
    if [ ! "$new_pass" ]; then
      cecho "New passphrase cannot be empty."
      continue
    fi
    confirm="$(read_secret "Confirm new passphrase: ")"
    if [ "$new_pass" != "$confirm" ]; then
      cecho "Passphrases do not match."
      continue
    fi

    printf "%s" "$current" >"$old_tmp"
    printf "%s" "$new_pass" >"$new_tmp"

    if cryptsetup luksChangeKey "$device" --key-file "$old_tmp" --new-keyfile "$new_tmp"; then
      rm -f "$old_tmp" "$new_tmp"
      current='' ; new_pass='' ; confirm='' ; unset current new_pass confirm
      cecho "Passphrase updated for ${device}."
      sync
      return 0
    fi

    rm -f "$old_tmp" "$new_tmp"
    cecho "Failed to update passphrase (incorrect current passphrase?)."
    retry="$(prompt_read "Retry? (Y/n): " "${TTY1:-}")"
    case "${retry:-Y}" in
      [Yy]* )
        continue
        ;;
      * )
        cecho "Passphrase not changed for ${device}."
        current='' ; new_pass='' ; confirm='' ; unset current new_pass confirm
        return 1
        ;;
    esac
  done
}

get_donor_selection() {
  local rootfs_partitions="$1"
  local target="$2"
  local i=1;
  selection="$(prompt_read "Your selection: " "${TTY1:-}")"

  for rootfs_partition in $rootfs_partitions; do
    local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
    local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)
    local part_flags=$(echo $rootfs_partition | cut -d ":" -f 3)

    if [ "$part_flags" = "CrOS" ]; then
      continue;
    fi

    if [ "$selection" = "$i" ]; then
      echo "selected $part_path as the donor partition"
      yes_no_prompt "would you like to spoof verified mode? this is useful if you're planning on using chrome os while enrolled. (y/n): " use_crossystem
      yes_no_prompt "would you like to spoof an invalid hwid? this will forcibly prevent the device from being enrolled. (y/n): " invalid_hwid
      boot_chromeos "$target" "$part_path" "$use_crossystem" "$invalid_hwid"
    fi

    i=$((i+1))
  done

  echo "invalid selection"
  sleep 1
  return 1
}

exec_init() {
  if [ "$rescue_mode" = "1" ]; then
    echo "entering a rescue shell instead of starting init"
    echo "once you are done fixing whatever is broken, run 'exec /sbin/init' to continue booting the system normally"
    
    if [ -f "/bin/bash" ]; then
      exec /bin/bash < "$TTY1" >> "$TTY1" 2>&1
    else
      exec /bin/sh < "$TTY1" >> "$TTY1" 2>&1
    fi
  else
    exec /sbin/init < "$TTY1" >> "$TTY1" 2>&1
  fi
}

boot_target() {
  local target="$1"
  local autopath="/ENPASS"
  local autoperm="600"
  local persist_dev="/dev/sda3"
  local persist_mount="/mnt/sda3"
  local persist_autopath="${persist_mount}/ENPASS"
  local passph=""
  local unlocked=""
  local manual_unlock=""

  cecho "moving mounts to newroot"
  mkdir -p /newroot

  if command -v cryptsetup >/dev/null 2>&1 && cryptsetup luksDump "$target" >/dev/null 2>&1; then
    if [ -s "$autopath" ]; then
      if base64 -d "$autopath" 2>/dev/null | cryptsetup open "$target" rootfs --key-file - >/dev/null 2>&1; then
        unlocked="1"
      else
        cecho "Stored auto-decrypt material failed for $target. Removing."
        rm -f "$autopath" || true
        if mkdir -p "$persist_mount" && mount "$persist_dev" "$persist_mount" >/dev/null 2>&1; then
          rm -f "$persist_autopath" || true
          umount "$persist_mount" >/dev/null 2>&1 || true
        fi
      fi
    fi
    if [ ! "$unlocked" ]; then
      while :; do
        passph="$(read_secret "Enter the passphrase for $target: ")"
        if [ ! "$passph" ]; then
          cecho "Empty passphrase provided. Aborting unlock."
          break
        fi
        if printf '%s' "$passph" | cryptsetup open "$target" rootfs --key-file - >/dev/null 2>&1; then
          unlocked="1"
          manual_unlock="1"
          break
        fi
        cecho "Incorrect passphrase for $target."
      done
    fi
    if [ ! "$unlocked" ]; then
      passph='' ; unset passph
      cecho "Failed to unlock $target. Returning to boot menu."
      sleep 2
      return 1
    fi
    if [ "$manual_unlock" ]; then
      while :; do
        yn="$(prompt_read "Enable auto-decrypt by saving base64 to $persist_autopath? (Y/n): " "${TTY1:-}")"
        case "${yn:-Y}" in
          [Yy]* )
            write_base64_single_line "$passph" "$autopath"
            chmod "$autoperm" "$autopath" >/dev/null 2>&1 || true
            if mkdir -p "$persist_mount" && mount "$persist_dev" "$persist_mount" >/dev/null 2>&1; then
              write_base64_single_line "$passph" "$persist_autopath"
              chmod "$autoperm" "$persist_autopath" >/dev/null 2>&1 || true
              sync
              umount "$persist_mount" >/dev/null 2>&1 || true
              cecho "Saved. Auto-decrypt armed at $persist_autopath."
            else
              rm -f "$autopath" || true
              cecho "Unable to mount $persist_dev; passphrase NOT saved."
            fi
            break ;;
          [Nn]* )
            cecho "Passphrase NOT saved."
            break ;;
          * )
            cecho "Please answer Y or n."
            ;;
        esac
      done
    fi
    passph='' ; unset passph
    mount /dev/mapper/rootfs /newroot
  else
    mount "$target" /newroot
  fi
  move_mounts /newroot

  echo "switching root"
  mkdir -p /newroot/bootloader
  pivot_root /newroot /newroot/bootloader
  exec_init
}



boot_chromeos() {
  local target="$1"
  local donor="$2"
  local use_crossystem="$3"
  local invalid_hwid="$4"
  
  echo "mounting target"
  mkdir /newroot
  mount -o ro $target /newroot

  echo "mounting tmpfs"
  mount -t tmpfs -o mode=1777 none /newroot/tmp
  mount -t tmpfs -o mode=0555 run /newroot/run
  mkdir -p -m 0755 /newroot/run/lock

  echo "mounting donor partition"
  local donor_mount="/newroot/tmp/donor_mnt"
  local donor_files="/newroot/tmp/donor"
  mkdir -p $donor_mount
  mount -o ro $donor $donor_mount
  echo "copying modules and firmware to tmpfs (this may take a while)"
  copy_progress $donor_mount/lib/modules $donor_files/lib/modules
  copy_progress $donor_mount/lib/firmware $donor_files/lib/firmware
  mount -o bind $donor_files/lib/modules /newroot/lib/modules
  mount -o bind $donor_files/lib/firmware /newroot/lib/firmware
  umount $donor_mount
  rm -rf $donor_mount

  if [ -e "/newroot/etc/init/tpm-probe.conf" ]; then
    echo "applying chrome os flex patches"
    mkdir -p /newroot/tmp/empty
    mount -o bind /newroot/tmp/empty /sys/class/tpm

    cat /newroot/etc/lsb-release | sed "s/DEVICETYPE=OTHER/DEVICETYPE=CHROMEBOOK/" > /newroot/tmp/lsb-release
    mount -o bind /newroot/tmp/lsb-release /newroot/etc/lsb-release
  fi

  echo "patching chrome os rootfs"
  cat /newroot/etc/ui_use_flags.txt | sed "/reven_branding/d" | sed "/os_install_service/d" > /newroot/tmp/ui_use_flags.txt
  mount -o bind /newroot/tmp/ui_use_flags.txt /newroot/etc/ui_use_flags.txt

  cp /opt/mount-encrypted /newroot/tmp/mount-encrypted
  cp /newroot/usr/sbin/mount-encrypted /newroot/tmp/mount-encrypted.real
  mount -o bind /newroot/tmp/mount-encrypted /newroot/usr/sbin/mount-encrypted
  
  cat /newroot/etc/init/boot-splash.conf | sed '/^script$/a \  pkill frecon-lite || true' > /newroot/tmp/boot-splash.conf
  mount -o bind /newroot/tmp/boot-splash.conf /newroot/etc/init/boot-splash.conf
  
  if [ "$use_crossystem" = "y" ]; then
    echo "patching crossystem"
    cp /opt/crossystem /newroot/tmp/crossystem
    if [ "$invalid_hwid" = "y" ]; then
      sed -i 's/block_devmode/hwid/' /newroot/tmp/crossystem
    fi

    cp /newroot/usr/bin/crossystem /newroot/tmp/crossystem_old
    mount -o bind /newroot/tmp/crossystem /newroot/usr/bin/crossystem
  fi

  echo "moving mounts"
  move_mounts /newroot

  echo "switching root"
  mkdir -p /newroot/tmp/bootloader
  pivot_root /newroot /newroot/tmp/bootloader

  echo "starting init"
  /sbin/modprobe zram
  exec_init
}

main() {
  echo "starting the fixcraft bootloader"
  if [ -f "/bin/frecon-lite" ]; then 
    rm -f /dev/console
    touch /dev/console 
    mount -o bind "$TTY1" /dev/console
  fi
  install_adminboot_helper
  enable_debug_console "$TTY2"

  local auto_actions_done=""

  while true; do
    local valid_partitions="$(find_all_partitions)"

    if [ ! "$auto_actions_done" ]; then
      auto_boot_from_mmc "${valid_partitions}"
      maybe_chromify_mmc "${valid_partitions}"
      auto_actions_done="1"
    fi

    clear
    print_selector "${valid_partitions}"

    if get_selection "${valid_partitions}"; then
      break
    fi
  done
}

trap - EXIT
main "$@"
sleep 1d
echo "something went very wrong if you see this message... pray to fixcraft gods."
sleep 10d

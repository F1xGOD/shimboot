#!/bin/bash

#build the debian rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  user_fullname   - Full name (GECOS field) for the created user."
  echo "  timezone        - Timezone to configure (defaults to PST8PDT for Iridium builds)."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be 'debian', 'ubuntu', 'alpine', or 'iridium'."
  echo "  primary_repo    - Override the primary apt repo URL (Iridium builds)."
  echo "  primary_suite   - Override the apt suite name (Iridium builds)."
  echo "  primary_components - Override apt components list (Iridium builds)."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_deps "realpath debootstrap findmnt wget pcregrep tar gpg"
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
packages="${args['custom_packages']-task-xfce-desktop}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
timezone="${args['timezone']}"
user_fullname="${args['user_fullname']}"
primary_repo="${args['primary_repo']}"
primary_suite="${args['primary_suite']}"
primary_components="${args['primary_components']}"
primary_key="${args['primary_key']}"
primary_keyring_chroot="${args['primary_keyring']-/usr/share/keyrings/iridium-archive-keyring.gpg}"
script_dir="$(realpath -m "$(dirname "$0")")"
chroot_mounts="proc sys dev run"

if [ "$release_name" = "osaka" ] && [ "$distro" = "debian" ]; then
  distro="iridium"
fi

mkdir -p $rootfs_dir

unmount_all() {
  for mountpoint in $chroot_mounts; do
    umount -l "$rootfs_dir/$mountpoint"
  done
}

need_remount() {
  local target="$1"
  local mnt_options="$(findmnt -T "$target" | tail -n1 | rev | cut -f1 -d' '| rev)"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint="$(findmnt -T "$target" | tail -n1 | cut -f1 -d' ')"
  mount -o remount,dev,exec "$mountpoint"
}

ensure_debootstrap_script() {
  local release="$1"
  local base_script="$2"
  local script_path="/usr/share/debootstrap/scripts/$release"

  if [ -f "$script_path" ]; then
    return
  fi

  if [ ! -f "/usr/share/debootstrap/scripts/$base_script" ]; then
    print_error "missing debootstrap script for $base_script"
    exit 1
  fi

  print_info "creating debootstrap script for $release based on $base_script"
  ln -sf "$base_script" "$script_path"
}

prepare_iridium_keyring() {
  local key_src="$1"
  local dest="$2"
  local key_url="${3:-https://ir.fixcraft.jp/iridium/iridium-archive-keyring.gpg.asc}"

  mkdir -p "$(dirname "$dest")"

  if [ -f "$key_src" ]; then
    gpg --dearmor -o "$dest" "$key_src"
    chmod 0644 "$dest"
    return 0
  fi

  print_info "iridium key not found locally, attempting download"
  if command -v curl >/dev/null; then
    if curl -fsSL "$key_url" -o "$dest.asc"; then
      gpg --dearmor -o "$dest" "$dest.asc"
      rm -f "$dest.asc"
      chmod 0644 "$dest"
      return 0
    fi
  elif command -v wget >/dev/null; then
    if wget -q "$key_url" -O "$dest.asc"; then
      gpg --dearmor -o "$dest" "$dest.asc"
      rm -f "$dest.asc"
      chmod 0644 "$dest"
      return 0
    fi
  fi

  print_error "could not retrieve iridium archive key; will continue without a keyring"
  rm -f "$dest" "$dest.asc" 2>/dev/null || true
  return 1
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "iridium" ]; then
  print_info "bootstraping iridium chroot"
  primary_repo="${primary_repo:-https://ir.fixcraft.jp/iridium}"
  primary_suite="${primary_suite:-$release_name}"
  primary_components="${primary_components:-main}"
  primary_key="${primary_key:-}"
  primary_key_url="${PRIMARY_KEY_URL:-https://ir.fixcraft.jp/iridium/iridium-archive-keyring.gpg.asc}"
  primary_keyring_chroot="${primary_keyring_chroot:-/usr/share/keyrings/iridium-archive-keyring.gpg}"
  primary_keyring_host="$rootfs_dir$primary_keyring_chroot"

  ensure_debootstrap_script "$release_name" "trixie"
  debootstrap_opts="--arch $arch --components=$primary_components"
  if prepare_iridium_keyring "$primary_key" "$primary_keyring_host" "$primary_key_url"; then
    debootstrap_opts="$debootstrap_opts --keyring $primary_keyring_host"
  else
    debootstrap_opts="$debootstrap_opts --no-check-gpg"
    primary_keyring_chroot="" # signal to setup script to trust repo
    primary_keyring_host=""
  fi

  debootstrap $debootstrap_opts "$release_name" "$rootfs_dir" "$primary_repo"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then 
  print_info "bootstraping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else 
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcregrep -o1 '"(.+?.apk)"')"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstraping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then 
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

print_info "copying rootfs setup scripts"
cp -arv rootfs/* "$rootfs_dir"
cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"

print_info "creating bind mounts for chroot"
trap unmount_all EXIT
for mountpoint in $chroot_mounts; do
  mount --make-rslave --rbind "/${mountpoint}" "${rootfs_dir}/$mountpoint"
done

hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"
distro_id="$distro"
primary_keyring="$primary_keyring_chroot"

if [ "$distro" = "iridium" ]; then
  username="${username:-fixcraft}"
  user_passwd="${user_passwd:-fixcraft}"
  user_fullname="${user_fullname:-FixCraft User}"
  timezone="${timezone:-PST8PDT}"
  primary_repo="${primary_repo:-https://ir.fixcraft.jp/iridium}"
  primary_suite="${primary_suite:-$release_name}"
  primary_components="${primary_components:-main}"
  primary_keyring="${primary_keyring_chroot:-/usr/share/keyrings/iridium-archive-keyring.gpg}"
fi

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch' '$distro_id' '$timezone' \
  '$user_fullname' '$primary_repo' \
  '$primary_suite' '$primary_keyring' \
  '$primary_components'" 

LC_ALL=C chroot $rootfs_dir /bin/sh -c "${chroot_command}"

trap - EXIT
unmount_all

print_info "rootfs has been created"

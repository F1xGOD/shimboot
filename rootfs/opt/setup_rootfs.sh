#!/bin/bash

#setup the debian rootfs
#this is meant to be run within the chroot created by debootstrap


DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2"
packages="$3"

hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"
distro_id="${11}"
timezone="${12}"
user_fullname="${13}"
primary_repo="${14}"
primary_suite="${15}"
primary_keyring="${16}"
primary_components="${17}"

iridium_mode=""
if [ "$distro_id" = "iridium" ] || [ "$release_name" = "osaka" ]; then
  iridium_mode="1"
fi

if [ "$iridium_mode" ]; then
  username="${username:-fixcraft}"
  user_passwd="${user_passwd:-fixcraft}"
  user_fullname="${user_fullname:-FixCraft User}"
  timezone="${timezone:-PST8PDT}"
  primary_repo="${primary_repo:-https://ir.fixcraft.jp/iridium}"
  primary_suite="${primary_suite:-osaka}"
  primary_keyring="${primary_keyring:-/usr/share/keyrings/iridium-archive-keyring.gpg}"
  primary_components="${primary_components:-main}"
fi

custom_repo="https://shimboot.ading.dev/debian"
custom_repo_domain="shimboot.ading.dev"
sources_entry="deb [trusted=yes arch=$arch] ${custom_repo} ${release_name} main"

export DEBIAN_FRONTEND="noninteractive"

#configure apt sources
if [ "$iridium_mode" ]; then
  rm -f /etc/apt/sources.list.d/*.list
  rm -f /etc/apt/preferences /etc/apt/preferences.d/*
  repo_opts="arch=$arch"
  if [ -f "$primary_keyring" ]; then
    repo_opts="signed-by=${primary_keyring} arch=$arch"
  else
    repo_opts="trusted=yes arch=$arch"
  fi
  echo "deb [${repo_opts}] ${primary_repo} ${primary_suite} ${primary_components}" > /etc/apt/sources.list
  if [ "$primary_suite" ]; then
    mkdir -p /etc/apt/apt.conf.d
    echo "APT::Default-Release \"${primary_suite}\";" > /etc/apt/apt.conf.d/99iridium
  fi
else
  echo -e "${sources_entry}\n$(cat /etc/apt/sources.list)" > /etc/apt/sources.list
  tee -a /etc/apt/preferences << END
Package: *
Pin: origin ${custom_repo_domain}
Pin-Priority: 1001
END
fi

#enable i386 arch so that steam works 
if [ "$arch" = "amd64" ]; then
  dpkg --add-architecture i386
fi


#install certs to prevent apt ssl errors
apt-get install -y ca-certificates
apt-get update

#fix apt repos for ubuntu
if [ ! "$iridium_mode" ]; then
  if grep "ubuntu.com" /etc/apt/sources.list > /dev/null; then
    ubuntu_repo="$(grep "ubuntu.com" /etc/apt/sources.list)"
    ubuntu_repo="$ubuntu_repo universe"
    updates_repo="$(echo "$ubuntu_repo" | sed "s/$release_name/$release_name-updates/")"
    sed -i '/ubuntu.com/d' /etc/apt/sources.list
    echo "$ubuntu_repo" >> /etc/apt/sources.list
    echo "$updates_repo" >> /etc/apt/sources.list

    #install the mozilla apt repo to avoid using snap for firefox
    apt-get install -y wget gpg
    install -d -m 0755 /etc/apt/keyrings 
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- > /etc/apt/keyrings/packages.mozilla.org.asc
    gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc | awk '/pub/{getline; gsub(/^ +| +$/,""); if($0 == "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3") print "\nThe key fingerprint matches ("$0").\n"; else print "\nVerification failed: the fingerprint ("$0") does not match the expected one.\n"}' 
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" >> /etc/apt/sources.list.d/mozilla.list
    echo '
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
' > /etc/apt/preferences.d/mozilla 
    apt-get update
  fi
fi

#install the patched systemd
apt-get upgrade -y --allow-downgrades
installed_systemd="$(dpkg-query -W -f='${binary:Package}\n' | grep "systemd")"
apt-get clean
apt-get install -y --reinstall --allow-downgrades $installed_systemd

#enable shimboot services
systemctl enable kill-frecon.service

#install base packages
if [ ! "$disable_base_pkgs" ]; then
  apt-get install -y cloud-utils zram-tools sudo command-not-found bash-completion libfuse2 libfuse3-* ntp lsb-release

  #set up zram
  echo "ALGO=lzo" >> /etc/default/zramswap
  echo "PERCENT=100" >> /etc/default/zramswap

  #update apt-file cache
  if which apt-file >/dev/null; then
    apt-file update
  else #old versions of command-not-found did not use apt-file
    apt-get update
  fi

  if [ "$iridium_mode" ]; then
    systemctl enable ntp || true
  fi
fi

#configure timezone
if [ "$timezone" ]; then
  if [ -f "/usr/share/zoneinfo/$timezone" ]; then
    ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    echo "$timezone" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
  else
    echo "timezone '$timezone' not found, skipping configuration"
  fi
fi

#set up hostname and username
if [ ! "$hostname" ]; then
  read -p "Enter the hostname for the system: " hostname
fi
echo "${hostname}" > /etc/hostname
tee -a /etc/hosts << END
127.0.0.1 localhost
127.0.1.1 ${hostname}

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
END

#install desktop and other custom packages
apt-get install -y $packages

#disable selinux to prevent a harmless error from showing up during the boot
echo "SELINUX=disabled" >> /etc/selinux/config

if [ ! $username ]; then
  read -p "Enter the username for the user account: " username
fi
useradd -m -s /bin/bash -G sudo -c "$user_fullname" $username

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd $user; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd $user
  fi
}

if [ "$enable_root" ]; then 
  echo "Enter a root password:"
  set_password root "$root_passwd"
else
  usermod -a -G sudo $username
fi

echo "Enter a user password:"
set_password "$username" "$user_passwd"

if [ "$iridium_mode" ]; then
  cat > /etc/os-release << 'EOF'
NAME="Iridium GNU/Linux"
PRETTY_NAME="Iridium"
ID=iridium
ID_LIKE=debian
VERSION="13.2 (Osaka)"
VERSION_ID="13.2"
VERSION_CODENAME=osaka
HOME_URL="https://fixcraft.jp"
EOF
  cp /etc/os-release /usr/lib/os-release 2>/dev/null || true

  cat > /etc/lsb-release << 'EOF'
DISTRIB_ID=Iridium
DISTRIB_RELEASE=13.2
DISTRIB_CODENAME=osaka
DISTRIB_DESCRIPTION="Iridium 13.2 (Osaka)"
EOF
fi

#clean apt caches
apt-get clean

#enable bash greeter
echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc" 

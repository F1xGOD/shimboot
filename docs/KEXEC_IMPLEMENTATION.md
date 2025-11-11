# Kexec Implementation Guide for Kernel Upgrade

This document provides a step-by-step guide for implementing kexec support in Shimboot to enable booting newer kernels (e.g., 6.12) from the Chrome OS 4.14 base kernel.

## Prerequisites

Before starting implementation:

1. Verify Chrome OS kernel has kexec support
2. Set up kernel compilation environment
3. Identify target board for initial testing
4. Back up existing Shimboot installation

## Phase 1: Verification (Week 1-2)

### Step 1.1: Check Kexec Support

Test if the Chrome OS kernel supports kexec:

```bash
# Boot into Shimboot
# Check if kexec is available
which kexec-tools || apt install kexec-tools

# Check kernel config
zcat /proc/config.gz | grep CONFIG_KEXEC
# Should show: CONFIG_KEXEC=y

# Test basic kexec functionality
kexec --version
```

### Step 1.2: Document Current Kernel Version

```bash
# Check kernel version
uname -r
cat /proc/version

# Check kernel modules
ls -la /lib/modules/

# Save hardware info
lshw > /tmp/hardware_info.txt
lspci -vvv > /tmp/pci_devices.txt
lsusb -v > /tmp/usb_devices.txt
```

### Step 1.3: Identify Required Drivers

Common Chromebook drivers needed:
- Graphics: i915 (Intel), amdgpu (AMD), or panfrost/mali (ARM)
- WiFi: ath9k, ath10k, iwlwifi, rtl8xxxu, mt76xx
- Audio: snd-hda-intel, snd-soc-*
- Input: chromeos_laptop, chromeos-acpi
- Storage: nvme, sdhci, mmc

## Phase 2: Kernel Compilation (Week 3-4)

### Step 2.1: Set Up Build Environment

```bash
# Install dependencies
apt-get install build-essential libncurses-dev bison flex libssl-dev \
  libelf-dev bc kmod cpio

# Download kernel source
cd /usr/src
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz
tar xf linux-6.12.tar.xz
cd linux-6.12
```

### Step 2.2: Configure Kernel

```bash
# Start with Chrome OS config as base
zcat /proc/config.gz > .config
make olddefconfig

# Enable essential options
make menuconfig

# Required options:
# - General setup -> Initial RAM filesystem and RAM disk support
# - Processor type and features -> EFI runtime service support
# - Device Drivers -> Graphics support -> Intel i915 (for Intel Chromebooks)
# - Device Drivers -> Network device support -> Wireless LAN
# - File systems -> EXT4, VFAT, SquashFS
```

### Step 2.3: Build Kernel

```bash
# Compile kernel (use all CPU cores)
make -j$(nproc)

# Build modules
make modules

# Install to temporary location for testing
mkdir -p /tmp/kernel-6.12
make INSTALL_PATH=/tmp/kernel-6.12 install
make INSTALL_MOD_PATH=/tmp/kernel-6.12 modules_install
```

## Phase 3: Integration (Week 5-6)

### Step 3.1: Modify Build Scripts

Create new script: `build_kexec_kernel.sh`

```bash
#!/bin/bash
# Build script for kexec-compatible kernel

. ./common.sh

print_help() {
  echo "Usage: ./build_kexec_kernel.sh output_dir kernel_version"
  echo "  output_dir: Directory to store compiled kernel"
  echo "  kernel_version: Kernel version to build (e.g., 6.12)"
}

assert_root
assert_args "$2"

output_dir="$(realpath -m "$1")"
kernel_version="$2"

# Download and build kernel
# ... (implementation details)
```

### Step 3.2: Modify Bootloader

Update `bootloader/bin/bootstrap.sh` to support kexec:

```bash
# Add kexec boot option
print_kexec_menu() {
  echo "Kexec Options:"
  echo "  1. Boot with Chrome OS kernel (4.14) - Default"
  echo "  2. Boot with mainline kernel (6.12) via kexec"
  echo "  3. Auto-detect best kernel"
}

boot_with_kexec() {
  local rootfs_path="$1"
  local kernel_version="$2"
  
  local kernel_path="${rootfs_path}/boot/vmlinuz-${kernel_version}"
  local initrd_path="${rootfs_path}/boot/initrd.img-${kernel_version}"
  
  if [ ! -f "$kernel_path" ]; then
    echo "Error: Kernel not found at $kernel_path"
    return 1
  fi
  
  echo "Loading kernel ${kernel_version} via kexec..."
  
  # Get current kernel command line
  local cmdline="$(cat /proc/cmdline)"
  
  # Load new kernel
  kexec -l "$kernel_path" \
    --initrd="$initrd_path" \
    --command-line="$cmdline"
  
  # Execute kexec
  echo "Executing kexec..."
  kexec -e
}
```

### Step 3.3: Update patch_rootfs.sh

Modify to install both kernels:

```bash
install_kexec_kernel() {
  local target_rootfs="$1"
  local kernel_dir="$2"
  
  # Install kexec-tools
  chroot "$target_rootfs" apt-get install -y kexec-tools
  
  # Copy kernel files
  cp "$kernel_dir/vmlinuz" "$target_rootfs/boot/vmlinuz-6.12"
  cp "$kernel_dir/initrd.img" "$target_rootfs/boot/initrd.img-6.12"
  
  # Copy modules
  cp -r "$kernel_dir/lib/modules/6.12" "$target_rootfs/lib/modules/"
  
  # Update bootloader config
  echo "KEXEC_KERNEL_VERSION=6.12" >> "$target_rootfs/etc/shimboot.conf"
}
```

## Phase 4: Testing (Week 7-8)

### Step 4.1: Basic Boot Test

```bash
# Build image with kexec support
sudo ./build_complete.sh <board_name> kexec=1

# Flash to USB
# Boot on Chromebook
# Select kexec option in bootloader
# Verify kernel version
uname -r  # Should show 6.12.x
```

### Step 4.2: Hardware Testing

Test each component:

```bash
# Graphics
glxinfo | grep "OpenGL version"
glxgears  # Should show smooth rendering

# WiFi
nmcli device wifi list
nmcli device wifi connect <SSID> password <password>

# Audio
speaker-test -t sine -f 1000 -l 1

# Touchscreen/Touchpad
xinput list
evtest /dev/input/event*

# Webcam
v4l2-ctl --list-devices
cheese  # or ffplay /dev/video0

# Bluetooth
bluetoothctl
# scan on, pair, connect
```

### Step 4.3: Regression Testing

Ensure existing functionality still works:

```bash
# Test with Chrome OS kernel (fallback)
# Boot with original kernel option
# Verify all features work as before

# Test rescue mode
# Test Chrome OS booting
# Test encrypted rootfs (if applicable)
```

## Phase 5: Multi-Board Support (Week 9-12)

### Step 5.1: Board-Specific Configs

Create kernel configs for different board families:

```
configs/
  ├── kernel-config-intel-x86
  ├── kernel-config-amd-x86
  ├── kernel-config-arm64-mediatek
  └── kernel-config-arm64-qualcomm
```

### Step 5.2: Auto-Detection

Implement board detection and automatic kernel selection:

```bash
detect_board_family() {
  local cpu_vendor="$(lscpu | grep 'Vendor ID' | awk '{print $3}')"
  local arch="$(uname -m)"
  
  if [ "$arch" = "x86_64" ]; then
    if [ "$cpu_vendor" = "GenuineIntel" ]; then
      echo "intel-x86"
    elif [ "$cpu_vendor" = "AuthenticAMD" ]; then
      echo "amd-x86"
    fi
  elif [ "$arch" = "aarch64" ]; then
    # Detect ARM SoC type
    local soc="$(cat /sys/firmware/devicetree/base/compatible | tr '\0' '\n' | head -1)"
    if [[ "$soc" == *"mediatek"* ]]; then
      echo "arm64-mediatek"
    elif [[ "$soc" == *"qualcomm"* ]]; then
      echo "arm64-qualcomm"
    fi
  fi
}
```

## Phase 6: Documentation and Release (Week 13-14)

### Step 6.1: User Documentation

Update README.md:
- Add kexec feature to features list
- Document kernel versions available
- Add FAQ entries about kernel selection

### Step 6.2: Build Documentation

Create docs/KERNEL_BUILDING.md:
- How to build custom kernels
- How to add board-specific drivers
- Troubleshooting guide

### Step 6.3: Release Checklist

- [ ] Test on at least 5 different board families
- [ ] Verify fallback to Chrome OS kernel works
- [ ] Test on both enrolled and unenrolled devices
- [ ] Update compatibility table
- [ ] Create prebuilt images with kexec support
- [ ] Update GitHub releases

## Troubleshooting

### Kexec Fails to Load

```bash
# Check kernel logs
dmesg | grep -i kexec

# Verify kernel has kexec support
cat /proc/cmdline | grep kexec

# Try with debug output
kexec -l /boot/vmlinuz-6.12 --initrd=/boot/initrd.img-6.12 --debug
```

### Graphics Not Working

```bash
# Check loaded modules
lsmod | grep -E "i915|amdgpu|nouveau|panfrost"

# Check Xorg logs
cat /var/log/Xorg.0.log | grep -i error

# Try forcing driver
echo "options i915 modeset=1" > /etc/modprobe.d/i915.conf
update-initramfs -u
```

### WiFi Not Working

```bash
# Check if driver is loaded
lsmod | grep -E "ath|iwl|rtl|mt76"

# Check firmware
ls -la /lib/firmware/

# Enable driver debug
modprobe -r ath10k_pci
modprobe ath10k_pci debug_mask=0xffffffff
```

### Audio Not Working

```bash
# Check ALSA
aplay -l

# Check PulseAudio/PipeWire
pactl info

# Load SOF firmware if needed
modprobe snd_sof_pci
```

## Performance Considerations

### Initramfs Size

Keep initramfs small to reduce boot time:
- Only include essential modules
- Use compression (xz or zstd)
- Remove unnecessary firmware

### Kernel Size

Optimize kernel configuration:
- Disable unused drivers
- Use modules instead of built-in where possible
- Enable link-time optimization (LTO)

### Boot Time

Expected boot times:
- Chrome OS kernel boot: ~10-15 seconds
- Kexec transition: ~5-8 seconds
- Total: ~15-23 seconds (vs ~10-15 without kexec)

## Security Considerations

### Kexec Restrictions

Some Chrome OS kernels may have kexec_load disabled:
- Check: `cat /proc/sys/kernel/kexec_load_disabled`
- If 1, kexec may be restricted
- May work with kexec_file_load instead

### Enrolled Devices

Kexec may trigger security alerts on enrolled devices:
- Test thoroughly before deployment
- Provide clear warnings to users
- Document behavior differences

## Alternative Approaches

If kexec doesn't work:

1. **Firmware Modification**: Requires unlocking firmware (defeats Shimboot purpose)
2. **Wait for Chrome OS Updates**: Not controllable by project
3. **Board-Specific Workarounds**: Use newer boards with newer kernels
4. **Driver Backporting**: Port newer drivers to 4.14 kernel (complex)

## Success Metrics

A successful implementation should achieve:
- ✅ Boot time increase < 10 seconds
- ✅ All hardware working on at least 80% of tested boards
- ✅ No regressions in existing functionality
- ✅ Fallback to Chrome OS kernel always works
- ✅ Works on at least 5 different board families

## References

- Linux Kexec documentation: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Chrome OS kernel source: https://chromium.googlesource.com/chromiumos/third_party/kernel/
- Kexec-tools: https://kernel.org/pub/linux/utils/kernel/kexec/

---

**Document Version**: 1.0  
**Last Updated**: 2025-11-11  
**Status**: Planning/Implementation Guide

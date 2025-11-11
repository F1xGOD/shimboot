# Kernel Upgrade Analysis: 4.14 → 6.12

## Executive Summary

This document analyzes the feasibility of upgrading the Linux kernel in Shimboot from version 4.14 (current) to 6.12 (latest stable).

## Current Architecture

### How Shimboot Uses the Kernel

1. **Kernel Source**: Chrome OS RMA shim images (provided by Google)
2. **Current Version**: Linux 4.14.x (varies by Chromebook board)
3. **Extraction Process**: 
   - Kernel is extracted from partition 2 (KERN-A) of the RMA shim
   - Located at `/home/runner/work/shimboot/shimboot/shim_utils.sh::copy_kernel()`
   - Extracted using `dd` command from the shim's kernel partition
4. **Integration**: The extracted kernel is directly copied to the Shimboot image without modification

### Key Constraints

1. **Firmware Dependency**: The Chrome OS kernel includes firmware and drivers specific to Chromebook hardware
2. **Boot Process**: Uses Chrome OS verified boot process which requires a specific kernel format
3. **Kernel Format**: Chrome OS kernels use a special partition format (FE3A2A5D-4F32-41A7-B725-ACCC3285A309)
4. **Module Compatibility**: Kernel modules from the shim are copied to rootfs for hardware support

### Current Limitations (due to 4.14 kernel)

From README.md:
- No audio on many devices
- Suspend disabled
- Swap disabled
- Some boards (reks, kefka) have X11 issues due to old kernel
- GPU acceleration issues requiring mesa-amber drivers

## Upgrade Feasibility Assessment

### Option 1: Direct Kernel Replacement (NOT FEASIBLE)

**Approach**: Replace the Chrome OS 4.14 kernel with a mainline 6.12 kernel

**Challenges**:
- ❌ Chrome OS verified boot expects a specific kernel format and signing
- ❌ Would require firmware modification (defeats Shimboot's purpose)
- ❌ Loss of Chromebook-specific hardware drivers
- ❌ Chrome OS kernel format is not standard Linux kernel format

**Verdict**: Not feasible without modifying firmware

### Option 2: Kexec (POTENTIALLY FEASIBLE)

**Approach**: Use kexec to boot into a newer kernel from the running 4.14 kernel

**How it works**:
- Boot with Chrome OS 4.14 kernel
- Once in userspace, use kexec to load and boot into kernel 6.12
- Bypasses firmware/bootloader restrictions

**Requirements**:
1. 4.14 kernel must have kexec support enabled (need to verify)
2. Mainline 6.12 kernel with Chromebook hardware support
3. Firmware/driver compatibility for hardware

**Advantages**:
- ✅ No firmware modification needed
- ✅ Can use modern kernel features
- ✅ Listed as TODO in README.md

**Challenges**:
- ⚠️  Need to verify if Chrome OS 4.14 kernel has kexec enabled
- ⚠️  Requires porting Chromebook-specific drivers to mainline kernel 6.12
- ⚠️  Firmware blobs may not be compatible with newer kernels
- ⚠️  Complex bootloader integration needed
- ⚠️  May break on enrolled devices

**Current Status**: Listed as TODO item in README.md

### Option 3: Wait for Google Updates (NOT CONTROLLABLE)

**Approach**: Wait for Google to update RMA shim kernels

**Verdict**: 
- Google controls RMA shim updates
- No guarantee of kernel version upgrades
- Not a viable solution for this project

## Chrome OS Kernel Versions

Chrome OS uses different kernel versions depending on the board:
- Older boards (reks, kefka): 3.18 or earlier
- Most current boards: 4.14.x or 4.19.x
- Some newer boards: 5.4.x or 5.10.x
- Newest boards: 5.15.x

**Note**: Each board's RMA shim determines the available kernel version. This is not configurable by Shimboot.

## Detailed Analysis: Kexec Implementation

### What Needs to be Done

1. **Verify kexec Support**
   - Check if Chrome OS 4.14 kernel has `CONFIG_KEXEC` enabled
   - Test kexec functionality on various Chromebook boards

2. **Build Mainline Kernel**
   - Compile Linux 6.12 with Chromebook hardware support
   - Include necessary drivers for each board family
   - Create kernel config for common Chromebook platforms

3. **Firmware Extraction**
   - Extract firmware from Chrome OS shim/recovery images
   - Package firmware for use with mainline kernel
   - Ensure compatibility with kernel 6.12 drivers

4. **Bootloader Integration**
   - Modify `bootloader/bin/bootstrap.sh` to support kexec path
   - Add option to boot with original 4.14 kernel or kexec to 6.12
   - Handle kernel command-line parameters properly

5. **Driver Compatibility**
   - Intel/AMD graphics drivers
   - WiFi drivers (varies by board)
   - Audio drivers (ALSA/SOF)
   - Touchscreen/touchpad drivers
   - Webcam drivers
   - Bluetooth drivers

6. **Testing Matrix**
   - Test on multiple board families (dedede, octopus, nissa, etc.)
   - Verify all hardware functionality
   - Performance testing
   - Power management testing

### Implementation Complexity

**Estimated Effort**: High (several weeks to months)

**Components to Modify**:
1. `bootloader/bin/bootstrap.sh` - Add kexec boot path
2. `build.sh` - Include mainline kernel build
3. `patch_rootfs.sh` - Package both kernels and firmware
4. New scripts for kernel configuration and compilation
5. Documentation updates

**Dependencies**:
- kexec-tools
- Kernel compilation toolchain
- Board-specific firmware
- Extensive testing infrastructure

## Recommendations

### Short Term (Immediate)

1. **Create Documentation**
   - Document current kernel limitations
   - Add FAQ entry about kernel versions
   - Explain why each board has a specific kernel version

2. **Investigate kexec Support**
   - Test if Chrome OS 4.14 kernel supports kexec
   - Create proof-of-concept on one board
   - Document findings

3. **Board-Specific Guidance**
   - Document which boards have newer kernels available
   - Guide users to select boards with newer RMA shim kernels if possible

### Medium Term (1-3 months)

1. **Kexec Prototype**
   - If kexec is viable, create prototype for one board family
   - Test with kernel 5.15 or 6.1 (LTS versions) first
   - Validate hardware compatibility

2. **Driver Analysis**
   - Analyze which drivers work with mainline kernels
   - Document driver compatibility matrix
   - Create driver extraction/packaging tools

### Long Term (3+ months)

1. **Full Kexec Implementation**
   - Support multiple board families
   - Auto-detect and boot appropriate kernel
   - Fallback to 4.14 if kexec fails

2. **Mainline Kernel Support**
   - Target Linux 6.12 LTS once stable
   - Regular kernel updates
   - Automated testing pipeline

## Known Issues with Old Kernel

From README and codebase:

1. **Audio**: Not working on most boards (dedede, nissa, grunt, corsola, etc.)
2. **GPU**: Requires mesa-amber for older GPUs (workaround exists)
3. **Suspend**: Disabled by kernel
4. **Swap**: Disabled by kernel
5. **X11**: Broken on very old kernels (reks, kefka with 3.18)
6. **Steam**: bwrap issues due to kernel security features (workaround exists)
7. **WiFi**: Some 5GHz bands not working on certain boards

## Security Considerations

1. **Kernel 4.14 EOL**: Linux 4.14 LTS reached end-of-life in January 2024
   - No more security updates from mainline
   - Chrome OS may backport security fixes (unknown)

2. **Kexec Security**: 
   - Could be disabled on enrolled devices
   - May trigger security alerts
   - Need to test on enrolled devices

## Conclusions

### Is Upgrading to 6.12 Possible?

**Direct Replacement**: ❌ **NO** - Not feasible without firmware modification

**Via Kexec**: ⚠️ **MAYBE** - Technically possible but requires significant work:
- High implementation complexity
- Extensive testing required
- May not work on all boards
- Driver compatibility challenges

### Recommended Path Forward

1. **Document current state** (this document)
2. **Test kexec viability** on 1-2 popular boards
3. **If viable**: Create proof-of-concept with LTS kernel (6.1 or 6.6)
4. **If successful**: Expand to more boards and eventually 6.12

### Realistic Timeline

- **Kexec viability test**: 1-2 weeks
- **Single-board prototype**: 1-2 months
- **Multi-board support**: 3-6 months
- **Production-ready 6.12**: 6-12 months

## Next Steps

1. Add this analysis to repository documentation
2. Test kexec support on available hardware
3. Create GitHub issue to track kexec implementation
4. Seek community input on priorities and board selection
5. Document findings from kexec tests

## References

- Current TODO list mentions kexec: README.md line 97
- Kernel extraction: `shim_utils.sh::extract_initramfs_full()`
- Kernel copying: `shim_utils.sh::copy_kernel()`
- Boot process: `bootloader/bin/bootstrap.sh`
- Partition layout: `image_utils.sh::create_partitions()`
- Chrome OS kernel format: GUID FE3A2A5D-4F32-41A7-B725-ACCC3285A309

## Appendix: Technical Details

### Kernel Extraction Process

```bash
# From build.sh
extract_initramfs_full "$shim_path" "$initramfs_dir" "$kernel_img" "$arch"

# Kernel is copied from partition 2 (KERN-A)
dd if=$kernel_loop of=$kernel_dir/kernel.bin bs=1M status=progress

# Then used directly in image creation
create_partitions "$image_loop" "$kernel_img" "$luks_enabled" "$crypt_password"
```

### Chrome OS Kernel Partition Format

- Type GUID: `FE3A2A5D-4F32-41A7-B725-ACCC3285A309`
- Size: 32MB (configurable in `image_utils.sh`)
- Contains: Kernel binary + initramfs + signatures

### Kexec Command Example (theoretical)

```bash
# Load new kernel
kexec -l /boot/vmlinuz-6.12 --initrd=/boot/initrd.img-6.12 --command-line="$(cat /proc/cmdline)"

# Execute kexec
kexec -e
```

---

**Document Version**: 1.0  
**Date**: 2025-11-11  
**Status**: Initial Analysis

# Kernel Upgrade Quick Reference

This is a quick reference guide for understanding the kernel situation in Shimboot and potential upgrade paths.

## Current State

- **Kernel Source**: Chrome OS RMA shim images (from Google)
- **Typical Version**: 4.14.x (varies by board)
- **Location in Code**: `shim_utils.sh::copy_kernel()` and `build.sh`
- **Cannot Change**: Kernel comes from Google's RMA shim, not under our control

## Why This Matters

### Benefits of Upgrading
- Better hardware support (newer drivers)
- Audio support on more devices
- Modern kernel features (newer filesystems, security features)
- Suspend/hibernate support
- Better power management
- Security updates (4.14 is EOL since January 2024)

### Current Limitations
- Audio doesn't work on most boards
- Suspend/swap disabled by kernel
- Old GPU drivers (require mesa-amber)
- X11 broken on very old kernels (3.18)
- Missing modern kernel features

## Upgrade Options Comparison

| Method | Feasibility | Effort | Risk | Impact |
|--------|------------|--------|------|--------|
| Direct replacement | ❌ Not possible | N/A | N/A | Would require firmware modification |
| Kexec | ⚠️ Maybe | High (6-12 months) | Medium | Boot newer kernel from 4.14 |
| Wait for Google | ❌ Not controllable | None | None | Depends on Google's update schedule |
| Use newer boards | ✅ Works now | None | None | Some boards have 5.x kernels |

## Recommended Path: Kexec

### What is Kexec?
Kexec is a Linux kernel feature that allows booting a new kernel from the running kernel without going through firmware/BIOS.

### How It Would Work
1. Boot Chromebook with Chrome OS 4.14 kernel (normal Shimboot process)
2. Once in userspace, use kexec to load kernel 6.12
3. Execute kexec to switch to the new kernel
4. Continue boot with modern kernel

### Prerequisites
- Chrome OS kernel must have `CONFIG_KEXEC` enabled
- Compile mainline kernel 6.12 with Chromebook drivers
- Extract and package firmware for new kernel
- Modify bootloader to support kexec path

### Timeline Estimate
- **Weeks 1-2**: Verify kexec support, test on 1-2 boards
- **Weeks 3-4**: Compile and configure kernel 6.12
- **Weeks 5-6**: Integrate into build system
- **Weeks 7-8**: Hardware testing and debugging
- **Weeks 9-12**: Multi-board support
- **Weeks 13-14**: Documentation and release

Total: **3-4 months for initial release, 6-12 months for full multi-board support**

## Key Files to Modify

If implementing kexec:

1. **bootloader/bin/bootstrap.sh**
   - Add kexec boot path
   - Menu for kernel selection
   - Fallback to Chrome OS kernel

2. **build_complete.sh**
   - Add `kexec=1` option
   - Download/build mainline kernel
   - Package both kernels

3. **patch_rootfs.sh**
   - Install kexec-tools
   - Copy both kernel versions
   - Install firmware

4. **New: build_kexec_kernel.sh**
   - Download kernel source
   - Configure for Chromebooks
   - Compile and package

## Board-Specific Kernel Versions

| Board Family | Typical Kernel | Notes |
|--------------|----------------|-------|
| dedede | 4.14.x | Most common, good hardware support |
| octopus | 4.14.x | Audio issues, otherwise good |
| nissa | 5.10.x | Newer kernel, better support |
| reks | 3.18.x | Very old, X11 broken |
| kefka | 3.18.x | Very old, X11 broken |
| corsola | 5.10.x | Newer ARM board |
| hatch | 4.19.x | Slightly newer than 4.14 |

## Testing Kexec Support

Quick test to see if kexec is available:

```bash
# Boot Shimboot normally
# Install kexec-tools
sudo apt install kexec-tools

# Check kernel config
zcat /proc/config.gz | grep CONFIG_KEXEC

# Try loading a kernel (test only, won't work without proper kernel)
sudo kexec --version
```

If you get a working kexec-tools installation and CONFIG_KEXEC=y, then kexec might be feasible for that board.

## Alternative: Use Boards with Newer Kernels

Some Chromebook boards already have newer kernels in their RMA shims:

**Boards with 5.x kernels:**
- nissa (5.10.x)
- corsola (5.10.x) - ARM64
- Some newer Intel/AMD boards

**How to check:**
1. Look up board on https://cros.download/recovery/
2. Download RMA shim
3. Extract and check kernel version

**Trade-off:**
- ✅ Works immediately, no development needed
- ✅ Better driver support than 4.14
- ❌ Still not latest (6.12)
- ❌ Limited to specific boards

## Security Considerations

### Kernel 4.14 End-of-Life
- Linux 4.14 LTS reached EOL in January 2024
- No more mainline security updates
- Chrome OS may backport critical fixes (unknown)

### Kexec Security
- May be restricted on enrolled devices
- Could trigger security alerts
- Needs thorough testing on enrolled devices
- May not work if `kexec_load_disabled=1`

## Getting Started with Kexec Development

If you want to start working on kexec support:

1. **Read the documentation:**
   - `KERNEL_UPGRADE_ANALYSIS.md` - Full analysis
   - `docs/KEXEC_IMPLEMENTATION.md` - Implementation guide

2. **Set up test environment:**
   - Get a Chromebook for testing (dedede or octopus recommended)
   - Set up kernel compilation environment
   - Install Shimboot on USB

3. **Phase 1: Verification**
   - Boot Shimboot
   - Test kexec-tools
   - Check kernel config
   - Document findings

4. **Phase 2: Proof of Concept**
   - Compile kernel 6.12 (or 6.6 LTS)
   - Extract firmware
   - Test kexec manually
   - Measure boot time impact

5. **Phase 3: Integration**
   - Modify build scripts
   - Update bootloader
   - Create test images
   - Test on multiple boards

## FAQs

**Q: Can I just download kernel 6.12 and copy it to Shimboot?**
A: No. Chrome OS expects a specially formatted kernel with signatures. Direct replacement would break the boot process.

**Q: Why not modify the firmware?**
A: Firmware modification defeats Shimboot's main advantage: working on enrolled devices without firmware changes.

**Q: Will kexec work on enrolled devices?**
A: Unknown. Needs testing. It might trigger security alerts or be disabled by policy.

**Q: How much slower will kexec boot be?**
A: Estimated 5-10 seconds additional boot time for the kexec transition.

**Q: Can I help with this?**
A: Yes! Test kexec on your Chromebook and report results. See `docs/KEXEC_IMPLEMENTATION.md` for details.

## Contact and Contributions

- File issues on GitHub for kexec-related questions
- PRs welcome for kexec implementation
- Test results appreciated (especially enrolled devices)

## References

- Full analysis: `KERNEL_UPGRADE_ANALYSIS.md`
- Implementation guide: `docs/KEXEC_IMPLEMENTATION.md`
- Main README: `README.md`
- Kexec documentation: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

---

**Last Updated**: 2025-11-11  
**Version**: 1.0

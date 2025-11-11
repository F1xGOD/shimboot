# Where Does Shimboot Get Its Kernel? (Simple Explanation)

## Short Answer

Shimboot gets its kernel from **Chrome OS RMA Shim images** that Google provides. These are downloaded automatically during the build process.

## How It Works

### 1. Download Process

When you run `./build_complete.sh octopus`, the script:

1. **Downloads RMA Shim** from Google's servers
   - URL: `https://cdn.cros.download/` 
   - File: A zip file specific to your board (e.g., `octopus`)
   - Size: ~500MB-1GB

2. **Extracts the Kernel** from the shim
   - Location: Partition 2 (KERN-A) of the shim image
   - Script: `shim_utils.sh` line 59-68 (`copy_kernel` function)
   - Command: `dd if=$kernel_loop of=$kernel_dir/kernel.bin`

3. **Copies Kernel** to your Shimboot USB image
   - Script: `build.sh` 
   - The kernel is placed in partition 2 of your Shimboot image

### 2. What Kernel Version You Get

The kernel version depends on which Chromebook board you choose:

| Board | Kernel Version | Notes |
|-------|---------------|-------|
| octopus | 4.14.x | Your board - audio doesn't work |
| dedede | 4.14.x | Most common |
| nissa | 5.10.x | Newer kernel available |
| corsola | 5.10.x | Newer ARM board |
| reks/kefka | 3.18.x | Very old, X11 broken |

**You cannot choose the kernel version** - it's determined by what Google put in the RMA shim for that board.

## Can I Use a Prebuilt Kernel?

### ❌ No - You Cannot Replace the Kernel Directly

**Why not?**
1. Chrome OS requires a **signed kernel** in a special format
2. The signature is checked by the Chromebook's firmware
3. Only Google can sign kernels that will boot
4. Replacing the kernel breaks the boot process

**What happens if you try?**
- The Chromebook will refuse to boot
- Error: "Chrome OS verification failed"
- The USB drive becomes unusable

### ⚠️ Prebuilt Kernels Won't Work

Even if you find a prebuilt Linux 6.12 kernel:
- It's not signed by Google
- It's not in Chrome OS format
- Shimboot cannot use it

## What Are Your Options?

### Option 1: Use a Different Board (Easy)

Choose a board with a newer kernel from the start:

```bash
# Instead of octopus (4.14), use:
sudo ./build_complete.sh nissa    # Gets you kernel 5.10
```

**Pros:**
- ✅ Easy - just use different board name
- ✅ Newer kernel (5.10 vs 4.14)
- ✅ Better hardware support

**Cons:**
- ❌ Only works if you have that Chromebook model
- ❌ Still not kernel 6.12

### Option 2: Wait for Kexec Implementation (Long-term)

The only way to get kernel 6.12 is implementing kexec:
- Boot with Chrome OS kernel (4.14)
- Then switch to Linux 6.12 using kexec
- Requires development work (documented in `docs/KEXEC_IMPLEMENTATION.md`)

### Option 3: Use Standard Linux (Not Shimboot)

Install regular Debian/Ubuntu with kernel 6.12:
- Requires unlocking firmware (can't use on enrolled devices)
- Loses Shimboot's main benefit
- See: https://mrchromebox.tech/

## Where to Find Shim Images

Google hosts RMA shims at:
- **URL**: https://cdn.cros.download/
- **Board List**: https://cros.download/recovery/

You can manually download for any board, but:
- The kernel is embedded in the shim
- You cannot extract and use it elsewhere
- Each shim only works on its specific board type

## Technical Details (If You're Curious)

### File Locations in Build Process

```
build_complete.sh (line 230-237)
  ↓ downloads shim
  ↓
shim_utils.sh::copy_kernel() (line 59)
  ↓ extracts kernel using dd
  ↓
build.sh (line 15-21)
  ↓ copies to final image
  ↓
Your Shimboot USB (partition 2)
```

### Kernel Format Details

Chrome OS kernels use:
- **Type GUID**: `FE3A2A5D-4F32-41A7-B725-ACCC3285A309`
- **Format**: Kernel binary + initramfs + Google signature
- **Size**: 32MB partition
- **Compression**: LZ4 (x86) or gzip (ARM)

## Summary for Octopus Board

**Your situation:**
- Board: octopus
- Available kernel: 4.14.x (from Google's RMA shim)
- Cannot be changed without breaking boot
- No prebuilt 6.12 kernel will work
- Only option for 6.12: implement kexec (months of work)

**Quick solutions that work now:**
1. Use octopus with 4.14 (audio won't work)
2. Switch to nissa board for 5.10 kernel (if you have that hardware)
3. Accept the limitation and use Shimboot with 4.14

## Need More Info?

- **Full technical analysis**: `KERNEL_UPGRADE_ANALYSIS.md`
- **Kexec implementation guide**: `docs/KEXEC_IMPLEMENTATION.md`
- **Quick reference**: `KERNEL_QUICK_REFERENCE.md`
- **Board compatibility**: See README.md table

---

**Bottom line**: Shimboot gets the kernel from Google's RMA shim downloads. You cannot use prebuilt kernels because Chrome OS requires signed kernels. The kernel version is fixed per board and cannot be easily changed.

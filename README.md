# linux-kernel-build

Automated Bash script to compile and package an optimized, low-latency `PREEMPT_RT` Linux kernel, optimized for Intel Meteor Lake systems and real-time audio work.

---

## Features & applied optimizations

- **Automatic tarball handling:** Automatically detects pre-downloaded `.tar.xz` or `.tar.gz` archives in the current directory or workspace; falls back to official upstream downloads if missing.
- **In-kernel Real-Time preemption:** Enables `CONFIG_PREEMPT_RT=y` with RT RCU boosting (`CONFIG_RCU_BOOST=y`).
- **High timer resolution:** Forces `CONFIG_HZ=1000` (1 ms tick rate) with high-resolution timers enabled.
- **Meteor Lake hardware hardening:**
  - Enforces `CONFIG_PCIEASPM_PERFORMANCE=y` to prevent PCIe link power drops and xHCI bus completion timeouts.
  - Sets Intel P-State scaling default governor to `performance`.
  - Enables Intel HFI thermal telemetry and Intel Xe graphics drivers.
  - Mitigates false-positive watchdog panics under heavy audio loads.
- **Fast build times:** Strips debugging symbols (`DEBUG_INFO`, `BTF`, `LOCKDEP`) to accelerate compilation.
- **Native Debian packaging:** Compiles `linux-image` and `linux-headers` packages and updates the GRUB bootloader automatically.

---

## Prerequisites

- **Distribution:** Ubuntu / Debian-based x86_64 system.
- **Disk space:** Minimum 25–30 GB of free space in your home directory or build partition.
- **Permissions:** Sudo privileges for dependency installation and kernel package deployment.

---

## Usage

### 1. Configure the target version
Open the script and adjust the target kernel version at the top:

```bash
KERNEL_VER="7.2.2"    # e.g., "7.2.2" or "7.3-rc2"
LOCAL_VER="-rt-custom"  # Appended to the kernel release string
```

### 2. (Optional) Provide a local archive
If you are compiling a pre-release candidate or have already downloaded the archive, place either format in the directory you run the script from or in `~/src/kernel/`:
- `linux-<KERNEL_VER>.tar.xz`
- `linux-<KERNEL_VER>.tar.gz`

If not present, the script will automatically attempt to download the `.tar.xz` archive from `cdn.kernel.org`.

### 3. Make executable and run
```bash
chmod +x build-rt-kernel.sh
./build-rt-kernel.sh
```

The script will:
1. Install required compiler and packaging dependencies.
2. Unpack the source tree into `~/src/kernel/linux-<KERNEL_VER>`.
3. Inherit your running system's `.config` from `/boot`.
4. Apply RT, scheduler, and Meteor Lake driver configurations via `scripts/config`.
5. Compile Debian `.deb` packages using all available CPU threads (`-j$(nproc)`).
6. Install the resulting `linux-image` and `linux-headers` packages and execute `update-grub`.
7. Cleans up compilation directory to reclaim disk space

---

## Post-install & verification

After the script finishes, reboot your system.

Once logged in, verify the running kernel and RT preemption:

```bash
uname -a
```
*Expected output contains your kernel version, `-rt-custom`, and `PREEMPT_RT`.*

Confirm the timer tick rate:
```bash
zgrep CONFIG_HZ /proc/config.gz 2>/dev/null || grep CONFIG_HZ "/boot/config-$(uname -r)"
```
*Expected output: `CONFIG_HZ=1000`.*

---

## Rollback instructions

The script installs kernel versions side-by-side. You can always roll back to the previous kernel:
1. Reboot your system
2. In the GRUB menu, navigate to **Advanced options for Ubuntu**
3. Select your previous working kernel (e.g., `Linux 7.2.2`)
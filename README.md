# linux-kernel-build

Automated Bash script to compile and package an optimized, low-latency PREEMPT_RT Linux kernel (.deb packages) for real-time digital audio workstations, with selectable hardware optimization profiles (Generic, AMD Zen, Intel Legacy, and Intel Meteor Lake).

---

## Features & Applied Optimizations

- Automatic Tarball Handling: Automatically detects pre-downloaded .tar.xz or .tar.gz archives in the invocation directory or build workspace; falls back to downloading the official upstream archive from kernel.org if missing.
- In-Kernel Real-Time Preemption: Enables hard real-time preemption (CONFIG_PREEMPT_RT=y) with real-time RCU priority boosting (CONFIG_RCU_BOOST=y with 500 ms boost delay).
- High-Resolution Timer: Forces a 1000 Hz timer frequency (CONFIG_HZ=1000 / 1 ms tick rate) with dynamic idle ticks (CONFIG_NO_HZ_IDLE=y) and high-resolution timers enabled.
- Memory & Jitter Defense: Configures Transparent Hugepages to madvise (CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y) and enables split-lock detection mitigations (CONFIG_X86_SPLIT_LOCK_DETECT=y) to eliminate latency stalls during audio callbacks.
- RT Watchdog Protection: Enables lockup detectors while disarming hard/soft lockup kernel panics (CONFIG_BOOTPARAM_HARDLOCKUP_PANIC=0, CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=0) to prevent false-positive kernel crashes under sustained DSP load.
- Hardware Architecture Profiles:
  - generic (Default): Platform-neutral real-time audio profile; inherits vendor drivers without hardware-specific overrides.
  - amd: Enforces AMD CPPC autonomous frequency scaling (CONFIG_X86_AMD_PSTATE=y), Radeon DRM graphics (CONFIG_DRM_AMDGPU=y), and AMD KVM virtualization (CONFIG_KVM_AMD=y).
  - intel-pre-meteor: Enforces Intel P-State scaling (CONFIG_X86_INTEL_PSTATE=y), performance governor defaults, legacy Intel graphics (CONFIG_DRM_I915=y), and Intel KVM virtualization (CONFIG_KVM_INTEL=y).
  - intel-meteor: Enforces Intel Meteor Lake / Arrow Lake Core Ultra features including Intel Thread Director / Hardware Feedback Interface (CONFIG_INTEL_HFI_THERMAL=y, CONFIG_INTEL_TURBO_MAX_3=y), idle drivers (CONFIG_INTEL_IDLE=y), both xe and i915 DRM subsystems (CONFIG_DRM_XE=y, CONFIG_DRM_I915=y), and locks PCIe ASPM to performance (CONFIG_PCIEASPM_PERFORMANCE=y).
- Dynamic GRUB Labels: Automatically reflects your chosen platform profile directly in the GRUB boot menu (e.g., "Ubuntu, with Linux 7.2.4-rt-amd").
- Fast Build Times: Strips debugging symbols and tracing bloat (DEBUG_INFO, BTF, LOCKDEP, PROVE_LOCKING) to accelerate compilation and eliminate RT lock verification overhead.
- Native Debian Packaging: Builds native linux-image and linux-headers .deb packages and updates the GRUB bootloader automatically.

---

## Prerequisites

- Distribution: Ubuntu / Debian-based x86_64 system.
- Disk Space: Minimum 25–30 GB of free space in your home directory or build partition.
- Permissions: Sudo privileges for installing dependencies and registering new kernel packages.

---

## Usage

### Syntax

./build-rt-kernel.sh [KERNEL_VERSION] [PLATFORM] [CUSTOM_TAG]

### Available Profiles:

| Profile | Target Architecture | Key Drivers Configured |
| :--- | :--- | :--- |
| generic (Default) | Any x86_64 system | Universal PREEMPT_RT audio tuning; inherits host drivers |
| amd | AMD Zen 3/4/5 (Hawk Point, Phoenix, Ryzen) | amd_pstate, amdgpu, kvm_amd |
| intel-pre-meteor | Intel 12th–14th Gen & older (Alder/Raptor Lake) | intel_pstate, i915, kvm_intel, performance gov |
| intel-meteor | Intel Core Ultra (Meteor Lake, Arrow Lake) | intel_pstate, xe, i915, Intel HFI, PCIe ASPM perf |

---

### Examples

1. Default Build (Generic Platform):
   Builds version 7.2.4 with the generic platform profile:
   ./build-rt-kernel.sh
   -> GRUB Label: "Ubuntu, with Linux 7.2.4-rt-generic"

2. AMD Zen / Ryzen / Hawk Point / Radeon 780M:
   Builds version 7.2.4 optimized for AMD Zen architecture:
   ./build-rt-kernel.sh 7.2.4 amd
   -> GRUB Label: "Ubuntu, with Linux 7.2.4-rt-amd"

3. Intel Meteor Lake / Core Ultra:
   Builds version 7.2.2 with Intel Xe, HFI, and PCIe anti-freeze hardening:
   ./build-rt-kernel.sh 7.2.2 intel-meteor
   -> GRUB Label: "Ubuntu, with Linux 7.2.2-rt-intel-meteor"

4. Intel 12th/13th/14th Gen (Pre-Meteor Lake):
   Builds version 7.2.4 for Alder Lake / Raptor Lake with i915 graphics:
   ./build-rt-kernel.sh 7.2.4 intel-pre-meteor
   -> GRUB Label: "Ubuntu, with Linux 7.2.4-rt-intel-pre-meteor"

5. Custom Build with Identifier Tag:
   Appends a custom suffix to the kernel release string:
   ./build-rt-kernel.sh 7.2.4 amd studio
   -> GRUB Label: "Ubuntu, with Linux 7.2.4-rt-amd-studio"

---

### Providing Local Archives (Optional)

If you are compiling a pre-release candidate (e.g., 7.3-rc2) or already have the source tarball, place it in the directory where you run the script or in ~/src/kernel/:
- linux-<KERNEL_VER>.tar.xz
- linux-<KERNEL_VER>.tar.gz

If no local archive is found, the script downloads the source directly from cdn.kernel.org.

---

## Post-Install & Verification

After the build script completes, reboot your system:

sudo reboot

### 1. Verify Real-Time Preemption
Once logged in, verify the running kernel and RT preemption:

uname -a
(Expected output contains your kernel version, your platform tag, and PREEMPT_RT)
Example: Linux workstation 7.2.4-rt-amd #1 SMP PREEMPT_RT ...

Confirm hard real-time sysfs reporting:
cat /sys/kernel/realtime
(Expected output: 1)

### 2. Confirm Timer Resolution
zgrep CONFIG_HZ /proc/config.gz 2>/dev/null || grep CONFIG_HZ "/boot/config-$(uname -r)"
(Expected output: CONFIG_HZ=1000)

---

## Rollback Instructions

The script installs kernel packages side-by-side without deleting existing kernels:
1. Reboot your system.
2. In the GRUB menu, navigate to Advanced options for Ubuntu.
3. Select any prior working kernel (e.g., Ubuntu, with Linux 7.2.2-rt-custom or generic recovery).
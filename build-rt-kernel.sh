#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Sudo Keep-Alive
# Validate sudo credentials once upfront and refresh the timestamp in the
# background every 60 seconds so long compiles do not trigger a password prompt.
# ==============================================================================
echo "Requesting administrative privileges..."
sudo -v

while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

trap 'kill "${SUDO_KEEP_ALIVE_PID}" 2>/dev/null || true' EXIT

# ==============================================================================
# Universal Linux PREEMPT_RT Kernel Build & Packaging Utility
# ==============================================================================
# Usage:
#   ./build-rt-kernel.sh [KERNEL_VERSION] [PLATFORM] [CUSTOM_TAG] [--cleanup]
#
# Platforms:
#   generic           - Pure RT audio stack, inherits hardware drivers
#   amd               - AMD Zen 3/4/5 (Hawk Point / Phoenix / Ryzen) + Radeon
#   intel-pre-meteor  - Intel 14th Gen and older (Alder Lake, Raptor Lake, i915)
#   intel-meteor      - Intel Meteor Lake / Arrow Lake (Core Ultra, Xe, HFI)
# ==============================================================================

KERNEL_VER="${1:-${KERNEL_VER:-7.2.7}}"
PLATFORM="${2:-${PLATFORM:-generic}}"
CUSTOM_TAG="${3:-}"
DO_CLEANUP=false

for arg in "$@"; do
    if [ "$arg" == "--cleanup" ]; then
        DO_CLEANUP=true
    fi
done

if [ -n "${CUSTOM_TAG}" ] && [ "${CUSTOM_TAG}" != "--cleanup" ]; then
    LOCAL_VER="-rt-${PLATFORM}-${CUSTOM_TAG}"
else
    LOCAL_VER="-rt-${PLATFORM}"
fi

SRC_DIR="${HOME}/src/kernel"
ORIGIN_DIR="${PWD}"

echo "================================================================="
echo " Target Version  : ${KERNEL_VER}"
echo " Release String  : ${LOCAL_VER}"
echo " Boot Menu Label : Ubuntu, with Linux ${KERNEL_VER}${LOCAL_VER}"
echo " Hardware Profile: [${PLATFORM}]"
echo " Cleanup Source  : ${DO_CLEANUP}"
echo "================================================================="

echo "=== 1. Installing Build & Packaging Dependencies ==="
sudo apt update
sudo apt install -y \
    build-essential \
    fakeroot \
    kmod \
    libncurses-dev \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    libdw-dev \
    debhelper \
    rsync \
    bc \
    dwarves \
    zstd \
    libudev-dev \
    libpci-dev \
    wget

echo "=== 2. Setting Up Source Workspace ==="
mkdir -p "${SRC_DIR}"

TARBALL=""
for ext in "tar.xz" "tar.gz"; do
    if [ -f "${ORIGIN_DIR}/linux-${KERNEL_VER}.${ext}" ]; then
        TARBALL="linux-${KERNEL_VER}.${ext}"
        if [ "${ORIGIN_DIR}" != "${SRC_DIR}" ]; then
            echo "Found local ${TARBALL} in current directory. Copying to workspace..."
            cp "${ORIGIN_DIR}/${TARBALL}" "${SRC_DIR}/${TARBALL}"
        fi
        break
    elif [ -f "${SRC_DIR}/linux-${KERNEL_VER}.${ext}" ]; then
        TARBALL="linux-${KERNEL_VER}.${ext}"
        break
    fi
done

cd "${SRC_DIR}"

if [ -z "${TARBALL}" ]; then
    TARBALL="linux-${KERNEL_VER}.tar.xz"
    MAJOR_VER="${KERNEL_VER%%.*}"
    TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/${TARBALL}"
    echo "No local archive found. Downloading ${TARBALL} from kernel.org..."
    wget -c "${TARBALL_URL}"
else
    echo "Using existing local tarball: ${TARBALL}."
fi

echo "Extracting kernel source (${TARBALL})..."
rm -rf "linux-${KERNEL_VER}"
mkdir -p "linux-${KERNEL_VER}"
tar -xf "${TARBALL}" -C "linux-${KERNEL_VER}" --strip-components=1
cd "linux-${KERNEL_VER}"

echo "=== 3. Inheriting Base Configuration ==="
if [ -f "/boot/config-$(uname -r)" ]; then
    echo "Inheriting running kernel config (/boot/config-$(uname -r))..."
    cp "/boot/config-$(uname -r)" .config
elif ls /boot/config-*-rt-* 1>/dev/null 2>&1; then
    LATEST_RT_CONF=$(ls -t /boot/config-*-rt-* | head -n 1)
    echo "Inheriting latest RT config (${LATEST_RT_CONF})..."
    cp "${LATEST_RT_CONF}" .config
elif [ -f "/proc/config.gz" ]; then
    echo "Inheriting config from /proc/config.gz..."
    zcat /proc/config.gz > .config
elif [ -f ".config" ]; then
    echo "Using existing local .config in source tree..."
else
    echo "No base config found. Generating defconfig..."
    make defconfig
fi

echo "=== 4. Applying Universal Real-Time Tuning ==="
# Strip vendor keys and module signature enforcement (prevents DKMS build failures)
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
scripts/config --disable CONFIG_MODULE_SIG
scripts/config --disable CONFIG_MODULE_SIG_ALL
scripts/config --disable CONFIG_MODULE_SIG_FORCE

# PREEMPT_RT deterministic scheduling
scripts/config --enable CONFIG_EXPERT
scripts/config --disable CONFIG_PREEMPT_NONE
scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
scripts/config --disable CONFIG_PREEMPT
scripts/config --disable CONFIG_PREEMPT_DYNAMIC
scripts/config --enable CONFIG_PREEMPT_RT

# High-resolution 1000Hz timer tick
scripts/config --disable CONFIG_HZ_250
scripts/config --disable CONFIG_HZ_300
scripts/config --enable CONFIG_HZ_1000
scripts/config --set-val CONFIG_HZ 1000
scripts/config --enable CONFIG_HIGH_RES_TIMERS
scripts/config --enable CONFIG_NO_HZ_IDLE

# Disable debug overhead and locking trackers
scripts/config --disable CONFIG_DEBUG_INFO
scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
scripts/config --disable CONFIG_DEBUG_INFO_BTF
scripts/config --disable CONFIG_PROVE_LOCKING
scripts/config --disable CONFIG_LOCKDEP
scripts/config --disable CONFIG_DEBUG_SPINLOCK
scripts/config --disable CONFIG_DEBUG_MUTEXES
scripts/config --disable CONFIG_DEBUG_ATOMIC_SLEEP

# Real-time RCU boost
scripts/config --enable CONFIG_RCU_BOOST
scripts/config --set-val CONFIG_RCU_BOOST_DELAY 500
scripts/config --enable CONFIG_RCU_LAZY

# Memory allocation & latency stability
scripts/config --disable CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS
scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE_MADVISE
scripts/config --enable CONFIG_X86_SPLIT_LOCK_DETECT

scripts/config --enable CONFIG_LOCKUP_DETECTOR
scripts/config --enable CONFIG_HARDLOCKUP_DETECTOR
scripts/config --set-val CONFIG_BOOTPARAM_HARDLOCKUP_PANIC 0
scripts/config --set-val CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC 0

# Support compressed firmware loading (.zst)
scripts/config --enable CONFIG_FW_LOADER_COMPRESS_ZSTD

echo "=== 5. Applying Platform-Specific Profile: [${PLATFORM}] ==="
case "${PLATFORM}" in
    generic)
        echo "Generic profile: pure RT audio tuning applied. Keeping inherited vendor drivers."
        ;;
    amd)
        echo "AMD profile: enforcing Zen CPPC (amd_pstate), Radeon (amdgpu as module), and KVM-AMD..."
        scripts/config --enable CONFIG_X86_AMD_PSTATE
        scripts/config --enable CONFIG_X86_AMD_PSTATE_DEFAULT_MODE_ACTIVE
        scripts/config --enable CONFIG_AMD_IOMMU
        scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU

        # AMDGPU Graphics Stack (Must be =m for initramfs firmware inclusion)
        scripts/config --module CONFIG_DRM_AMDGPU
        scripts/config --enable CONFIG_DRM_AMD_DC
        scripts/config --enable CONFIG_DRM_AMD_DC_FP
        scripts/config --module CONFIG_DRM_AMD_ACP

        # KVM Virtualization
        scripts/config --module CONFIG_KVM_AMD

        # Strip lingering Intel hardware/power drivers
        scripts/config --disable CONFIG_DRM_I915
        scripts/config --disable CONFIG_DRM_XE
        scripts/config --disable CONFIG_INTEL_HFI_THERMAL
        scripts/config --disable CONFIG_X86_INTEL_PSTATE
        scripts/config --disable CONFIG_INTEL_IDLE
        ;;
    intel-pre-meteor)
        echo "Intel legacy profile: enforcing intel_pstate, i915 DRM, and KVM-Intel..."
        scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
        scripts/config --enable CONFIG_X86_INTEL_PSTATE
        scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU
        scripts/config --module CONFIG_DRM_I915
        scripts/config --module CONFIG_KVM_INTEL
        scripts/config --disable CONFIG_DRM_AMDGPU
        scripts/config --disable CONFIG_X86_AMD_PSTATE
        ;;
    intel-meteor)
        echo "Intel Meteor Lake profile: enforcing Xe DRM, HFI Thread Director, and PCIe Performance..."
        scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
        scripts/config --enable CONFIG_X86_INTEL_PSTATE
        scripts/config --enable CONFIG_INTEL_HFI_THERMAL
        scripts/config --enable CONFIG_INTEL_TURBO_MAX_3
        scripts/config --enable CONFIG_INTEL_IDLE
        scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU
        
        # Heterogeneous Core Scheduling (P/E Cores)
        scripts/config --enable CONFIG_SCHED_SMT
        scripts/config --enable CONFIG_SCHED_MC
        scripts/config --enable CONFIG_SCHED_MC_PRIO

        scripts/config --module CONFIG_DRM_XE
        scripts/config --module CONFIG_DRM_I915
        scripts/config --module CONFIG_KVM_INTEL
        scripts/config --disable CONFIG_PCIEASPM_DEFAULT
        scripts/config --disable CONFIG_PCIEASPM_POWERSAVE
        scripts/config --disable CONFIG_PCIEASPM_POWER_SUPERSAVE
        scripts/config --enable CONFIG_PCIEASPM_PERFORMANCE
        scripts/config --disable CONFIG_DRM_AMDGPU
        scripts/config --disable CONFIG_X86_AMD_PSTATE
        ;;
    *)
        echo "Error: Unknown platform '${PLATFORM}'!"
        echo "Valid options: generic, amd, intel-pre-meteor, intel-meteor"
        exit 1
        ;;
esac

make olddefconfig

echo "=== 6. Configuration Verification ==="
if ! grep -q "CONFIG_PREEMPT_RT=y" .config; then
    echo "ERROR: CONFIG_PREEMPT_RT=y was rejected by make olddefconfig!"
    echo "Check dependencies or verify if this kernel version requires an out-of-tree RT patch."
    exit 1
fi

grep -E "CONFIG_PREEMPT_RT=|CONFIG_HZ=|CONFIG_RCU_BOOST=|CONFIG_DRM_AMDGPU=|CONFIG_FW_LOADER_COMPRESS_ZSTD=" .config

echo "=== 7. Compiling Debian Packages ==="
# Clean old matching packages in destination to avoid installing the wrong builds
rm -f "${SRC_DIR}"/linux-image-*"${LOCAL_VER}"*.deb "${SRC_DIR}"/linux-headers-*"${LOCAL_VER}"*.deb

make -j"$(nproc)" bindeb-pkg LOCALVERSION="${LOCAL_VER}" 2>&1 | tee build.log

RELEASE_NAME=$(cat include/config/kernel.release 2>/dev/null || echo "${KERNEL_VER}${LOCAL_VER}")

echo "=== 8. Installing Kernel Packages & Updating GRUB ==="
LATEST_PKG=$(find "${SRC_DIR}" -maxdepth 1 -name "linux-image-*${LOCAL_VER}*.deb" -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
LATEST_HDR=$(find "${SRC_DIR}" -maxdepth 1 -name "linux-headers-*${LOCAL_VER}*.deb" -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")

if [ -z "${LATEST_PKG}" ] || [ -z "${LATEST_HDR}" ]; then
    echo "Error: Could not locate compiled .deb packages in ${SRC_DIR}!"
    exit 1
fi

echo "Installing: $(basename "${LATEST_PKG}")"
echo "Installing: $(basename "${LATEST_HDR}")"

sudo dpkg -i "${LATEST_PKG}" "${LATEST_HDR}"
sudo update-grub

echo "=== 9. Cleaning Up Build Artifacts ==="
cd "${SRC_DIR}"
if [ "${DO_CLEANUP}" = true ] && [ -d "linux-${KERNEL_VER}" ]; then
    echo "Removing source tree 'linux-${KERNEL_VER}' to reclaim disk space..."
    rm -rf "linux-${KERNEL_VER}"
else
    echo "Retaining source tree at ${SRC_DIR}/linux-${KERNEL_VER} for DKMS/debugging."
    echo "Pass '--cleanup' if you wish to automatically remove it."
fi

echo ""
echo "================================================================="
echo " Build Complete!"
echo " Installed Kernel: ${RELEASE_NAME}"
echo " Boot Entry Name : Ubuntu, with Linux ${RELEASE_NAME}"
echo " Reboot your system to load the new kernel."
echo "================================================================="
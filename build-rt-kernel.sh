#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Universal Linux PREEMPT_RT Kernel Build & Packaging Utility
# ==============================================================================
# Usage:
#   ./build-rt-kernel.sh [KERNEL_VERSION] [PLATFORM] [CUSTOM_TAG]
#
# Platforms:
#   generic            - (Default) Pure RT audio stack, inherits hardware drivers
#   amd                - AMD Zen 3/4/5 (Hawk Point / Phoenix / Ryzen) + Radeon
#   intel-pre-meteor   - Intel 14th Gen and older (Alder Lake, Raptor Lake, i915)
#   intel-meteor       - Intel Meteor Lake / Arrow Lake (Core Ultra, Xe, HFI)
#
# Examples:
#   ./build-rt-kernel.sh                              -> 7.2.4-rt-generic
#   ./build-rt-kernel.sh 7.2.4 amd                    -> 7.2.4-rt-amd
#   ./build-rt-kernel.sh 7.2.4 intel-meteor           -> 7.2.4-rt-intel-meteor
#   ./build-rt-kernel.sh 7.2.4 amd studio             -> 7.2.4-rt-amd-studio
# ==============================================================================

KERNEL_VER="${1:-${KERNEL_VER:-7.2.4}}"
PLATFORM="${2:-${PLATFORM:-generic}}"
CUSTOM_TAG="${3:-}"

# Dynamically construct the release string so it shows up in GRUB:
# e.g., -rt-amd, -rt-intel-meteor, -rt-generic (or -rt-amd-studio if custom tag given)
if [ -n "${CUSTOM_TAG}" ]; then
    LOCAL_VER="-rt-${PLATFORM}-${CUSTOM_TAG}"
else
    LOCAL_VER="-rt-${PLATFORM}"
fi

SRC_DIR="${HOME}/src/kernel"
ORIGIN_DIR="${PWD}"

echo "================================================================="
echo " Target Version : ${KERNEL_VER}"
echo " Release String : ${LOCAL_VER}"
echo " Boot Menu Label: Ubuntu, with Linux ${KERNEL_VER}${LOCAL_VER}"
echo " Hardware Profile: [${PLATFORM}]"
echo "================================================================="

echo "=== 1. Installing Build & Packaging Dependencies ==="
sudo apt update
sudo apt install -y \
    build-essential \
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
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

scripts/config --enable CONFIG_EXPERT
scripts/config --disable CONFIG_PREEMPT_NONE
scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
scripts/config --disable CONFIG_PREEMPT
scripts/config --disable CONFIG_PREEMPT_DYNAMIC
scripts/config --enable CONFIG_PREEMPT_RT

scripts/config --disable CONFIG_HZ_250
scripts/config --disable CONFIG_HZ_300
scripts/config --enable CONFIG_HZ_1000
scripts/config --set-val CONFIG_HZ 1000
scripts/config --enable CONFIG_HIGH_RES_TIMERS
scripts/config --enable CONFIG_NO_HZ_IDLE

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

scripts/config --enable CONFIG_RCU_BOOST
scripts/config --set-val CONFIG_RCU_BOOST_DELAY 500
scripts/config --enable CONFIG_RCU_LAZY

scripts/config --disable CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS
scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE_MADVISE
scripts/config --enable CONFIG_X86_SPLIT_LOCK_DETECT

scripts/config --enable CONFIG_LOCKUP_DETECTOR
scripts/config --enable CONFIG_HARDLOCKUP_DETECTOR
scripts/config --set-val CONFIG_BOOTPARAM_HARDLOCKUP_PANIC 0
scripts/config --set-val CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC 0

echo "=== 5. Applying Platform-Specific Profile: [${PLATFORM}] ==="
case "${PLATFORM}" in
    generic)
        echo "Generic profile: pure RT audio tuning applied. Keeping inherited vendor drivers."
        ;;
    amd)
        echo "AMD profile: enforcing Zen CPPC (amd_pstate), Radeon (amdgpu), and KVM-AMD..."
        scripts/config --enable CONFIG_X86_AMD_PSTATE
        scripts/config --enable CONFIG_DRM_AMDGPU
        scripts/config --enable CONFIG_KVM_AMD
        ;;
    intel-pre-meteor)
        echo "Intel legacy profile: enforcing intel_pstate, i915 DRM, and KVM-Intel..."
        scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
        scripts/config --enable CONFIG_X86_INTEL_PSTATE
        scripts/config --enable CONFIG_DRM_I915
        scripts/config --enable CONFIG_KVM_INTEL
        ;;
    intel-meteor)
        echo "Intel Meteor Lake profile: enforcing Xe DRM, HFI Thread Director, and PCIe Performance..."
        scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
        scripts/config --enable CONFIG_X86_INTEL_PSTATE
        scripts/config --enable CONFIG_INTEL_HFI_THERMAL
        scripts/config --enable CONFIG_INTEL_TURBO_MAX_3
        scripts/config --enable CONFIG_INTEL_IDLE
        scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU
        scripts/config --enable CONFIG_DRM_XE
        scripts/config --enable CONFIG_DRM_I915
        scripts/config --enable CONFIG_KVM_INTEL
        scripts/config --disable CONFIG_PCIEASPM_DEFAULT
        scripts/config --disable CONFIG_PCIEASPM_POWERSAVE
        scripts/config --disable CONFIG_PCIEASPM_POWER_SUPERSAVE
        scripts/config --enable CONFIG_PCIEASPM_PERFORMANCE
        ;;
    *)
        echo "Error: Unknown platform '${PLATFORM}'!"
        echo "Valid options: generic, amd, intel-pre-meteor, intel-meteor"
        exit 1
        ;;
esac

make olddefconfig

echo "=== 6. Configuration Verification ==="
grep -E "CONFIG_PREEMPT_RT=|CONFIG_HZ=|CONFIG_RCU_BOOST=" .config

echo "=== 7. Compiling Debian Packages ==="
make -j"$(nproc)" bindeb-pkg LOCALVERSION="${LOCAL_VER}" 2>&1 | tee build.log

echo "=== 8. Installing Kernel Packages & Updating GRUB ==="
PKG_PATTERN="${SRC_DIR}/linux-image-*${LOCAL_VER}*.deb"
HDR_PATTERN="${SRC_DIR}/linux-headers-*${LOCAL_VER}*.deb"

LATEST_PKG=$(ls -t ${PKG_PATTERN} | head -n 1)
LATEST_HDR=$(ls -t ${HDR_PATTERN} | head -n 1)

echo "Installing: $(basename "${LATEST_PKG}")"
echo "Installing: $(basename "${LATEST_HDR}")"

sudo dpkg -i "${LATEST_PKG}" "${LATEST_HDR}"
sudo update-grub

RELEASE_NAME=$(cat include/config/kernel.release 2>/dev/null || echo "${KERNEL_VER}${LOCAL_VER}")

echo ""
echo "================================================================="
echo " Build Complete!"
echo " Boot Entry Name: Ubuntu, with Linux ${RELEASE_NAME}"
echo " Reboot your system to load the new kernel."
echo "================================================================="
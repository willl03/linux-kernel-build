#!/usr/bin/env bash
set -euo pipefail

KERNEL_VER="7.2.2"
LOCAL_VER="-rt-custom"
SRC_DIR="${HOME}/src/kernel"
ORIGIN_DIR="${PWD}"

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
    libpci-dev

echo "=== 2. Setting Up Source Workspace ==="
mkdir -p "${SRC_DIR}"

TARBALL=""
# 1. Search for pre-existing tarballs in the invocation directory
if [ -f "${ORIGIN_DIR}/linux-${KERNEL_VER}.tar.xz" ]; then
    TARBALL="linux-${KERNEL_VER}.tar.xz"
    if [ "${ORIGIN_DIR}" != "${SRC_DIR}" ]; then
        echo "Found manually placed ${TARBALL} in current directory. Copying to workspace..."
        cp "${ORIGIN_DIR}/${TARBALL}" "${SRC_DIR}/${TARBALL}"
    fi
elif [ -f "${ORIGIN_DIR}/linux-${KERNEL_VER}.tar.gz" ]; then
    TARBALL="linux-${KERNEL_VER}.tar.gz"
    if [ "${ORIGIN_DIR}" != "${SRC_DIR}" ]; then
        echo "Found manually placed ${TARBALL} in current directory. Copying to workspace..."
        cp "${ORIGIN_DIR}/${TARBALL}" "${SRC_DIR}/${TARBALL}"
    fi
# 2. Search for pre-existing tarballs already sitting in the workspace directory
elif [ -f "${SRC_DIR}/linux-${KERNEL_VER}.tar.xz" ]; then
    TARBALL="linux-${KERNEL_VER}.tar.xz"
elif [ -f "${SRC_DIR}/linux-${KERNEL_VER}.tar.gz" ]; then
    TARBALL="linux-${KERNEL_VER}.tar.gz"
fi

cd "${SRC_DIR}"

# 3. If neither was found locally, default to downloading the official .tar.xz
if [ -n "${TARBALL}" ]; then
    echo "Using existing local tarball: ${TARBALL}. Skipping download."
else
    TARBALL="linux-${KERNEL_VER}.tar.xz"
    TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v7.x/${TARBALL}"
    echo "No local archive found. Downloading ${TARBALL}..."
    wget -c "${TARBALL_URL}"
fi

echo "Extracting kernel source (${TARBALL})..."
rm -rf "linux-${KERNEL_VER}"
mkdir -p "linux-${KERNEL_VER}"
tar -xf "${TARBALL}" -C "linux-${KERNEL_VER}" --strip-components=1
cd "linux-${KERNEL_VER}"

echo "=== 3. Inheriting Working System Config ==="
if [ -f "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" .config
elif [ -f ".config" ]; then
    echo "Using existing local .config"
else
    echo "Error: No base kernel configuration found!"
    exit 1
fi

echo "=== 4. Applying RT & Hardware Optimizations ==="
# Clear canonical distribution keys that break local packaging
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# Enable Full In-Kernel Real-Time Preemption
scripts/config --enable CONFIG_EXPERT
scripts/config --disable CONFIG_PREEMPT_NONE
scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
scripts/config --disable CONFIG_PREEMPT
scripts/config --disable CONFIG_PREEMPT_DYNAMIC
scripts/config --enable CONFIG_PREEMPT_RT

# Set 1000 Hz Timer Frequency for audio determinism
scripts/config --disable CONFIG_HZ_250
scripts/config --disable CONFIG_HZ_300
scripts/config --enable CONFIG_HZ_1000
scripts/config --set-val CONFIG_HZ 1000
scripts/config --enable CONFIG_HIGH_RES_TIMERS
scripts/config --enable CONFIG_NO_HZ_IDLE

# Strip Debugging Bloat (reduces compile time and prevents RT lock delays)
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

# RCU RT Optimization
scripts/config --enable CONFIG_RCU_BOOST
scripts/config --set-val CONFIG_RCU_BOOST_DELAY 500
scripts/config --enable CONFIG_RCU_LAZY

# Intel CPU Frequency Scaling & Meteor Lake Drivers
scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
scripts/config --enable CONFIG_X86_INTEL_PSTATE
scripts/config --enable CONFIG_INTEL_HFI_THERMAL
scripts/config --enable CONFIG_INTEL_TURBO_MAX_3
scripts/config --enable CONFIG_INTEL_IDLE
scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU
scripts/config --enable CONFIG_DRM_XE
scripts/config --enable CONFIG_DRM_I915

# --- Meteor Lake Bus & Anti-Freeze Hardening ---
# Set PCIe ASPM default to Performance (prevents PCIe link power drops & bus timeouts)
scripts/config --disable CONFIG_PCIEASPM_DEFAULT
scripts/config --disable CONFIG_PCIEASPM_POWERSAVE
scripts/config --disable CONFIG_PCIEASPM_POWER_SUPERSAVE
scripts/config --enable CONFIG_PCIEASPM_PERFORMANCE

# Split Lock Detection mitigation support
scripts/config --enable CONFIG_X86_SPLIT_LOCK_DETECT

# Watchdog RT protection (avoids false-positive hard panics under heavy RT audio load)
scripts/config --enable CONFIG_LOCKUP_DETECTOR
scripts/config --enable CONFIG_HARDLOCKUP_DETECTOR
scripts/config --disable CONFIG_BOOTPARAM_HARDLOCKUP_PANIC
scripts/config --disable CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC

# Resolve all dependencies non-interactively
make olddefconfig

echo "=== 5. Configuration Verification ==="
grep -E "CONFIG_PREEMPT_RT=|CONFIG_HZ=|CONFIG_RCU_BOOST=|CONFIG_PCIEASPM_PERFORMANCE=" .config

# Capture release string before build artifacts are removed
RELEASE_NAME="$(cat include/config/kernel.release)"

echo "=== 6. Compiling Debian Packages ==="
make -j"$(nproc)" bindeb-pkg LOCALVERSION="${LOCAL_VER}" 2>&1 | tee build.log

echo "=== 7. Installing Kernel Packages, Updating GRUB & Cleaning Up ==="
sudo dpkg -i "${SRC_DIR}/linux-image-${KERNEL_VER%%.*}"*${LOCAL_VER}*.deb "${SRC_DIR}/linux-headers-${KERNEL_VER%%.*}"*${LOCAL_VER}*.deb
sudo update-grub

echo "Cleaning up compilation directory to reclaim disk space..."
cd "${SRC_DIR}"
rm -rf "${SRC_DIR}/linux-${KERNEL_VER}"

echo "=== Complete! Reboot system to load ${RELEASE_NAME} ==="
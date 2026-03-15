#!/bin/bash
# =============================================================================
# ipu6-camera-adl — Intel IPU6 MIPI Camera Setup
# =============================================================================
# Builds the full Intel IPU6 camera stack from source for Alder Lake (12th Gen)
# and Raptor Lake (13th Gen) laptops with MIPI cameras on Ubuntu 24.04 LTS.
#
# Usage:  sudo ./setup.sh          # Full install
#         sudo ./setup.sh --check  # Hardware check only
# License: GPL-3.0
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}==> $1${NC}"; }

WORKDIR="/tmp/ipu6-camera-adl-build"
KERNEL_VER=$(uname -r)

[ "$EUID" -eq 0 ] || { err "Run as root: sudo $0"; exit 1; }

# --- Hardware detection ---

detect_hardware() {
    step "Detecting hardware..."

    local pci_line
    pci_line=$(lspci -nn -d ::0480 2>/dev/null | grep -i "8086:" | head -1) || true
    [ -n "$pci_line" ] || { err "No Intel IPU6 device found."; exit 1; }

    IPU6_PCI_ID=$(echo "$pci_line" | grep -oP '\[8086:\K[0-9a-f]+' | head -1)

    case "$IPU6_PCI_ID" in
        462e|465d)  IPU6_VARIANT="ipu6ep";    IPU6_DESC="Alder Lake" ;;
        a75d)       IPU6_VARIANT="ipu6ep";    IPU6_DESC="Raptor Lake" ;;
        9a19)       IPU6_VARIANT="ipu6";      IPU6_DESC="Tiger Lake (experimental)" ;;
        7d19)       IPU6_VARIANT="ipu6epmtl"; IPU6_DESC="Meteor Lake" ;;
        *)          err "Unknown IPU6 PCI ID: 8086:$IPU6_PCI_ID"; exit 1 ;;
    esac

    info "Detected $IPU6_DESC IPU6 (PCI: 8086:$IPU6_PCI_ID, HAL: $IPU6_VARIANT)"
    local sensor
    sensor=$(dmesg 2>/dev/null | grep -oP 'Found supported sensor \K\S+' | head -1) || true
    [ -n "$sensor" ] && info "Sensor: $sensor" || warn "Sensor not detected in dmesg."
    info "Kernel: $KERNEL_VER"
}

if [ "${1:-}" = "--check" ]; then detect_hardware; exit 0; fi
detect_hardware

echo -e "\n${BOLD}This will build the IPU6 camera stack from source (~500 MB, needs internet).${NC}"
read -p "Continue? [y/N] " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0
mkdir -p "$WORKDIR"

# === STEP 1: Build dependencies ===

step "Step 1/7: Installing build dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential cmake dkms git pkg-config \
    "linux-headers-${KERNEL_VER}" v4l2loopback-dkms \
    libexpat1-dev automake autoconf libtool \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-tools \
    libdrm-dev libdrm-intel1
info "Dependencies installed"

# === STEP 2: Remove conflicting packages ===

step "Step 2/7: Removing conflicting packages..."
dpkg --remove --force-remove-reinstreq intel-ipu6-dkms 2>/dev/null || true
apt-get autopurge -y oem-*-meta 2>/dev/null || true
dkms status 2>/dev/null | grep -i "ipu6" | while IFS= read -r line; do
    m=$(echo "$line" | cut -d',' -f1 | xargs)
    dkms remove "$(echo "$m" | cut -d/ -f1)/$(echo "$m" | cut -d/ -f2)" --all 2>/dev/null || true
done
info "Cleanup complete"

# === STEP 3: IPU6 PSYS kernel module (out-of-tree) ===

step "Step 3/7: Building IPU6 PSYS kernel module..."
cd "$WORKDIR"
rm -rf ipu6-drivers
git clone --depth 1 https://github.com/intel/ipu6-drivers.git
cd ipu6-drivers

DKMS_VER="0.0.0"
DKMS_SRC="/usr/src/ipu6-drivers-${DKMS_VER}"
rm -rf "$DKMS_SRC"; mkdir -p "$DKMS_SRC"
cp -r drivers/ "$DKMS_SRC/"
cp -r include/ "$DKMS_SRC/" 2>/dev/null || true
[ -f dkms.conf ] && cp dkms.conf "$DKMS_SRC/"
[ -d patches ]   && cp -r patches "$DKMS_SRC/"

KMAJ=$(echo "$KERNEL_VER" | grep -oP '^\d+\.\d+')
if [ "$(echo "$KMAJ >= 6.10" | bc)" -eq 1 ]; then
    HDIR="/usr/src/linux-headers-${KERNEL_VER}/drivers/media/pci/intel/ipu6"
    [ -d "$HDIR" ] && cp "$HDIR"/*.h "$DKMS_SRC/drivers/media/pci/intel/ipu6/" 2>/dev/null || true
fi

dkms add "ipu6-drivers/${DKMS_VER}" 2>/dev/null || true
if dkms build "ipu6-drivers/${DKMS_VER}" -k "$KERNEL_VER" 2>&1; then
    dkms install "ipu6-drivers/${DKMS_VER}" -k "$KERNEL_VER" 2>&1 || true
    info "PSYS built via DKMS"
else
    warn "DKMS failed -- falling back to direct build..."
    cd "$DKMS_SRC"
    make -C "/lib/modules/${KERNEL_VER}/build" M="$DKMS_SRC" modules 2>&1 || true
    mkdir -p "/lib/modules/${KERNEL_VER}/updates"
    find "$DKMS_SRC" -name "*.ko" -exec cp {} "/lib/modules/${KERNEL_VER}/updates/" \; 2>/dev/null || true
    depmod -a "$KERNEL_VER"
    info "PSYS built via direct make"
fi

# === STEP 4: Camera firmware + ISP libraries ===

step "Step 4/7: Installing camera firmware and ISP libraries..."
cd "$WORKDIR"
rm -rf ipu6-camera-bins
git clone --depth 1 https://github.com/intel/ipu6-camera-bins.git
cd ipu6-camera-bins

mkdir -p /lib/firmware/intel/ipu
cp -f lib/firmware/intel/ipu/*.bin /lib/firmware/intel/ipu/ 2>/dev/null || true
for lib in lib/lib*.so.*; do [ -f "$lib" ] && cp -f "$lib" /usr/lib/; done
cp -Pf lib/lib*.so /usr/lib/ 2>/dev/null || true
mkdir -p /usr/include /usr/lib/pkgconfig
cp -rf include/* /usr/include/ 2>/dev/null || true
cp -rf lib/pkgconfig/* /usr/lib/pkgconfig/ 2>/dev/null || true

# CRITICAL: Create .so linker symlinks
# Libs ship as libia_aiq-ipu6ep.so.0 but linker needs libia_aiq-ipu6ep.so
cd /usr/lib
for lib in libia_*-${IPU6_VARIANT}.so.0 \
           libbroxton_ia_pal-${IPU6_VARIANT}.so.0 \
           libgcss-${IPU6_VARIANT}.so.0; do
    [ -f "$lib" ] && ln -sf "$lib" "${lib%.so.0}.so"
done

# CRITICAL: Create generic pkgconfig symlinks
# CMake looks for ia_imaging.pc but bins install ia_imaging-ipu6ep.pc
ln -sf "/usr/lib/pkgconfig/ia_imaging-${IPU6_VARIANT}.pc" /usr/lib/pkgconfig/ia_imaging.pc
ln -sf "/usr/lib/pkgconfig/libgcss-${IPU6_VARIANT}.pc"    /usr/lib/pkgconfig/libgcss.pc
ln -sf "/usr/lib/pkgconfig/lib${IPU6_VARIANT}.pc"         /usr/lib/pkgconfig/libipu.pc

ldconfig
info "Firmware and ISP libraries installed"

# === STEP 5: Build Camera HAL (libcamhal) ===

step "Step 5/7: Building Camera HAL for ${IPU6_VARIANT}..."
cd "$WORKDIR"
rm -rf ipu6-camera-hal
git clone --depth 1 https://github.com/intel/ipu6-camera-hal.git
cd ipu6-camera-hal && mkdir build && cd build

cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_CAMHAL_ADAPTOR=ON \
      -DBUILD_CAMHAL_PLUGIN=ON \
      -DIPU_VER="$IPU6_VARIANT" \
      -DUSE_PG_LITE_PIPE=ON ..

make -j"$(nproc)"
make install
ldconfig
info "Camera HAL built and installed"

# === STEP 6: Build icamerasrc GStreamer plugin ===

step "Step 6/7: Building icamerasrc GStreamer plugin..."
cd "$WORKDIR"
rm -rf icamerasrc
git clone --depth 1 -b icamerasrc_slim_api https://github.com/intel/icamerasrc.git
cd icamerasrc

export CHROME_SLIM_CAMHAL=ON
export STRIP_VIRTUAL_CHANNEL_CAMHAL=ON

./autogen.sh
./configure --prefix=/usr
make -j"$(nproc)"
make install
ldconfig
info "icamerasrc installed"

# === STEP 7: v4l2loopback + systemd service ===

step "Step 7/7: Configuring v4l2loopback and systemd service..."

cat > /etc/modprobe.d/ipu6-camera.conf << 'MODEOF'
options v4l2loopback video_nr=99 card_label="Integrated Camera" exclusive_caps=1
MODEOF

cat > /etc/modules-load.d/ipu6-camera.conf << 'LOADEOF'
mei_vsc
ivsc_ace
ivsc_csi
v4l2loopback
LOADEOF

cat > /etc/systemd/system/ipu6-camera-loopback.service << 'SVCEOF'
[Unit]
Description=IPU6 Camera to V4L2 Loopback
After=multi-user.target
ConditionPathExists=/dev/video99

[Service]
Type=simple
Environment=GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0:/usr/lib/x86_64-linux-gnu/gstreamer-1.0
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/gst-launch-1.0 -e icamerasrc buffer-count=7 ! video/x-raw,format=NV12,width=1280,height=720 ! videoconvert ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 ! identity drop-allocation=true ! v4l2sink device=/dev/video99 sync=false
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable ipu6-camera-loopback.service
usermod -aG video "${SUDO_USER:-$USER}" 2>/dev/null || true
for dev in /dev/video{0..47}; do [ -e "$dev" ] && setfacl -b "$dev" 2>/dev/null || true; done
info "v4l2loopback and systemd service configured"

# === DONE ===

echo ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}  Installation complete! Please reboot now.${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo ""
echo "  Camera: 'Integrated Camera' on /dev/video99"
echo "  Test:   https://webcamtest.com (Chrome/Brave/Edge)"
echo "  Note:   Firefox Snap does NOT work"
echo ""
echo "  sudo systemctl status ipu6-camera-loopback   # Check"
echo "  sudo journalctl -u ipu6-camera-loopback -f   # Logs"
echo "  sudo ./uninstall.sh                          # Remove"
echo ""
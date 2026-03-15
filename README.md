# ipu6-camera

Enable the integrated Intel IPU6 MIPI camera on **Alder Lake** (12th Gen)

## The Problem

Modern Intel laptops use MIPI cameras connected through the IPU6 (Imaging Processing Unit 6). On Ubuntu 24.04 with kernels 6.10+, these cameras produce a black screen or aren't detected because:

1. **The PSYS module isn't in the mainline kernel.** Intel considers the hardware ISP interface proprietary and never upstreamed it.
2. **Ubuntu's libcamera (v0.2.0) doesn't support IPU6.** IPU6 support requires libcamera ≥0.3.2, which isn't in the repos.
3. **The old `icamerasrc` stack fails** without the out-of-tree PSYS module — "Failed to open PSYS" errors.

This script builds the complete camera stack from Intel's upstream sources.

## Architecture

```
Browser (Chrome, Brave, Edge)
        ↑
/dev/video99  ← v4l2loopback virtual camera
        ↑
GStreamer:  icamerasrc → videoconvert → v4l2sink
        ↑
Intel Camera HAL  (libcamhal — userspace ISP)
        ↑
IPU6 PSYS (out-of-tree)  +  IPU6 ISYS (mainline)
        ↑
OV2740 sensor  ←  IVSC (powers the sensor on/off)
```

## Supported Hardware

| Platform | PCI IDs | HAL | Status |
|----------|---------|-----|--------|
| Alder Lake (12th Gen) | `8086:465d` | `ipu6ep` | ✅ Tested |
| Raptor Lake (13th Gen) | `8086:a75d` | `ipu6ep` | ✅ Should work |
| Tiger Lake (11th Gen) | `8086:9a19` | `ipu6` | ⚠️ Experimental |
| Meteor Lake (12th Gen) | `8086:7d19` | `ipu6epmtl` | → Use [ipu6-camera](https://github.com/achrafsoltani/ipu6-camera) |

### Tested On

- **Lenovo ThinkPad X1 Carbon Gen 12** — Alder Lake, OV2740 (`INT3474`), kernel `6.17.0-1012-oem`, Ubuntu 24.04.4 LTS

## Quick Start

```bash
git clone https://github.com/Jem256/ipu6-camera.git
cd ipu6-camera

# Optional: check hardware first
sudo ./setup.sh --check

# Install
sudo ./setup.sh
sudo reboot
```

Test at [webcamtest.com](https://webcamtest.com) in Chrome, Brave, or Edge.

## What It Does

| Step | Description | Source |
|------|-------------|--------|
| 1 | Install build deps | Ubuntu repos |
| 2 | Remove conflicting `intel-ipu6-dkms` | — |
| 3 | Build IPU6 PSYS module (DKMS + fallback) | [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers) |
| 4 | Install firmware + ISP libs + create linker symlinks | [intel/ipu6-camera-bins](https://github.com/intel/ipu6-camera-bins) |
| 5 | Build Camera HAL (`libcamhal`) | [intel/ipu6-camera-hal](https://github.com/intel/ipu6-camera-hal) |
| 6 | Build `icamerasrc` GStreamer plugin | [intel/icamerasrc](https://github.com/intel/icamerasrc) (`icamerasrc_slim_api`) |
| 7 | Configure v4l2loopback `/dev/video99` + systemd service | — |

## Commands

```bash
sudo systemctl status ipu6-camera-loopback    # Service status
sudo journalctl -u ipu6-camera-loopback -f    # Live logs
sudo ./uninstall.sh                           # Remove everything
```

## Troubleshooting

### Black screen

Check IVSC modules (they power the sensor):
```bash
lsmod | grep -E "ivsc|mei_vsc"
# Should show: ivsc_ace, ivsc_csi, mei_vsc_hw
# If missing:
sudo modprobe mei_vsc ivsc_ace ivsc_csi
```

### "Failed to open PSYS"

The PSYS module didn't build. Check:
```bash
ls /dev/ipu-psys*
cat /var/lib/dkms/ipu6-drivers/0.0.0/build/make.log
```

### Firefox doesn't see the camera

Firefox Snap can't access v4l2loopback. Use Chrome, Brave, Edge, or install Firefox from `.deb`.

### 1080p instead of 720p

```bash
sudo systemctl edit ipu6-camera-loopback
```
Replace `1280,height=720` with `1920,height=1080` in both caps, then:
```bash
sudo systemctl restart ipu6-camera-loopback
```

## Key Insights

Non-obvious lessons from building this:

1. **Linker symlinks are critical.** `ipu6-camera-bins` ships `libia_aiq-ipu6ep.so.0` but the linker needs `libia_aiq-ipu6ep.so`. Without explicit symlinks, the HAL build fails.

2. **Pkgconfig needs generic names.** CMake expects `ia_imaging.pc` but only `ia_imaging-ipu6ep.pc` exists. Symlinks fix this.

3. **IVSC must load before IPU6.** If `ivsc_ace`/`ivsc_csi` load after IPU6 scans for sensors, the camera appears in media topology but stays powered off.

4. **PCI ID `465d` is common but undocumented.** Many guides only list `462e` — the `465d` variant (Alder Lake-P) is on ThinkPad X1 Carbon Gen 10/11 and is often missing from detection scripts.

5. **DKMS often fails on 6.11+.** The out-of-tree patches don't apply cleanly. The direct `make` fallback builds whatever modules it can.

## Related Projects

- [achrafsoltani/ipu6-camera](https://github.com/achrafsoltani/ipu6-camera) — Meteor Lake (USB-IO bridge)
- [stefanpartheym/archlinux-ipu6-webcam](https://github.com/stefanpartheym/archlinux-ipu6-webcam) — Arch Linux
- [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers) — Intel's upstream source

## Credits

- Intel — open-source Camera HAL and GStreamer plugin
- [Achraf Soltani](https://www.achrafsoltani.com/computer-science/ipu6-camera-linux-meteor-lake/) - Intel IPU6 Camera on Linux: Automated Setup for Meteor Lake Laptops
- [Javier Tia](https://jetm.github.io/blog/posts/ipu6-webcam-libcamera-on-linux/) — mainline migration documentation
- Launchpad bugs [#2125294](https://bugs.launchpad.net/bugs/2125294), [#2107304](https://bugs.launchpad.net/bugs/2107304), [#2114878](https://bugs.launchpad.net/bugs/2114878)

## License

GPL-3.0. See [LICENSE](LICENSE). Intel camera binaries are proprietary — see Intel's license.
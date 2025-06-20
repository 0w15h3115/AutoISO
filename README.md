# AutoISO - Persistent Bootable Linux ISO Creator

AutoISO is a comprehensive bash script that creates persistent bootable Linux ISO images from your current system. It generates live USBs that can save changes between reboots, making it perfect for portable workstations, system recovery, or creating custom Linux distributions.

## Features

- **Persistent Live System**: Save changes between reboots
- **Flexible Storage**: Choose any disk with sufficient space (not limited to /tmp)
- **Interactive Disk Selection**: Automatically detects available drives
- **Multiple Boot Options**: Persistent, live, safe mode, and to-RAM modes
- **Space Optimization**: Intelligent cleanup and compression
- **Error Recovery**: Robust error handling and space monitoring
- **Network Ready**: Includes NetworkManager and essential tools
- **User-Friendly**: Pre-configured with useful applications

## Requirements

- **Operating System**: Debian/Ubuntu-based Linux distributions
- **Storage**: At least 15GB free space on target disk
- **Privileges**: Root or sudo access
- **Architecture**: x86/x64 systems

## Installation

1. Download the script:
```bash
wget https://raw.githubusercontent.com/yourusername/autoiso/main/autoiso.sh
chmod +x autoiso.sh
```

2. Or clone the repository:
```bash
git clone https://github.com/yourusername/autoiso.git
cd autoiso
chmod +x autoiso.sh
```

## Usage

### Basic Usage

```bash
# Interactive disk selection (recommended for first-time users)
./autoiso.sh

# Use specific directory
./autoiso.sh /mnt/external-drive

# Use environment variable
export WORKDIR=/home/user/iso-build
./autoiso.sh

# Show help
./autoiso.sh --help
```

### Common Examples

```bash
# Use external USB drive
./autoiso.sh /media/user/USB-DRIVE

# Use external SSD for faster builds
./autoiso.sh /mnt/external-ssd

# Use home directory (if sufficient space)
./autoiso.sh /home/user/iso-workspace

# Use mounted network storage
./autoiso.sh /mnt/network-storage
```

## Step-by-Step Guide

### 1. Prepare Your System
```bash
# Update package lists
sudo apt update

# Install git if needed
sudo apt install git

# Download AutoISO
git clone https://github.com/yourusername/autoiso.git
cd autoiso
```

### 2. Run AutoISO
```bash
# Start the build process
./autoiso.sh /path/to/build/location

# The script will:
# - Install required packages
# - Copy your system files
# - Create the bootable ISO
# - Provide usage instructions
```

### 3. Create Bootable USB
```bash
# Write ISO to USB drive (replace /dev/sdX with your USB device)
sudo dd if=/path/to/autoiso-persistent-YYYYMMDD-HHMM.iso of=/dev/sdX bs=4M status=progress oflag=sync

# Verify the write completed
sync
```

### 4. Create Persistence Partition (Optional)
```bash
# Create second partition using gparted or fdisk
sudo gparted /dev/sdX

# Format persistence partition
sudo mkfs.ext4 -L persistence /dev/sdX2

# Mount and configure persistence
sudo mkdir -p /mnt/persistence
sudo mount /dev/sdX2 /mnt/persistence
echo "/ union" | sudo tee /mnt/persistence/persistence.conf
sudo umount /mnt/persistence
```

## Boot Options

When booting from your USB drive, you'll see these options:

- **AutoISO Persistent Mode** (Recommended): Changes are saved between reboots
- **AutoISO Live Mode**: Traditional live CD behavior, no changes saved
- **AutoISO Safe Mode**: Use if you experience graphics issues
- **AutoISO to RAM**: Loads entire system to RAM (requires 4GB+ RAM)

## Default Credentials

- **Username**: `user`
- **Password**: `live`
- **Privileges**: User has sudo access

## Included Software

AutoISO includes essential software for a complete live environment:

- **Network**: NetworkManager, wireless tools, WPA supplicant
- **Browser**: Firefox ESR
- **File Manager**: PCManFM
- **Editor**: Nano
- **System Monitor**: htop
- **Base System**: Full Debian/Ubuntu base with live-boot

## Troubleshooting

### Common Issues

**"Insufficient space" error:**
```bash
# Check available space
df -h

# Use different disk
./autoiso.sh /path/to/larger/disk

# Clean up previous builds
sudo rm -rf /tmp/iso
```

**"Kernel not found" error:**
```bash
# Check available kernels
ls -la /boot/vmlinuz*

# Update kernel packages
sudo apt update && sudo apt upgrade
```

**USB not booting:**
- Verify ISO integrity: `md5sum your-iso-file.iso`
- Try different USB port or USB drive
- Check BIOS/UEFI boot settings
- Ensure USB drive is bootable

**Persistence not working:**
- Verify persistence partition is labeled correctly: `sudo blkid`
- Check persistence.conf file exists and contains `/ union`
- Ensure partition is ext4 formatted

### Performance Tips

- **Use SSD**: Build on SSD for faster compilation
- **External Drive**: Use USB 3.0+ external drive for better performance
- **RAM**: More RAM helps during build process
- **CPU**: Multi-core systems build faster due to parallel compression

## Advanced Configuration

### Custom Exclusions

Edit the `EXCLUDE_DIRS` array in the script to customize what gets excluded:

```bash
EXCLUDE_DIRS=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*"
    "/your/custom/exclude/path"
    # Add more exclusions here
)
```

### Custom Packages

Modify the chroot section to install additional packages:

```bash
# In the chroot section, add:
apt-get install -y your-package-name
```

### Boot Menu Customization

Edit the `isolinux.cfg` creation section to customize boot options and appearance.

## File Structure

```
autoiso-build/
├── extract/          # Extracted system files
├── cdroot/           # CD root structure
│   ├── boot/         # Boot configuration
│   └── live/         # Live system files
└── autoiso-persistent-YYYYMMDD-HHMM.iso  # Final ISO
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes
4. Test thoroughly
5. Submit a pull request

### Development Setup

```bash
git clone https://github.com/yourusername/autoiso.git
cd autoiso

# Make changes to autoiso.sh
# Test in a virtual machine first!

# Submit changes
git add .
git commit -m "Description of changes"
git push origin feature-name
```

## Security Considerations

- **Sensitive Data**: The ISO contains a copy of your system. Remove sensitive files before building
- **Passwords**: Consider changing default passwords in the live system
- **Network**: Live system includes network tools - secure accordingly
- **Updates**: Regularly update the base system before creating ISOs

## FAQ

**Q: How long does it take to build an ISO?**
A: Typically 30-60 minutes depending on system size and storage speed.

**Q: Can I create an ISO of a different system?**
A: No, AutoISO creates an ISO of the current running system.

**Q: Will my personal files be included?**
A: No, user home directories are excluded by default for privacy.

**Q: Can I run this on other Linux distributions?**
A: Currently optimized for Debian/Ubuntu. May work on derivatives with modifications.

**Q: How do I update an existing live USB?**
A: Create a new ISO and re-write it to the USB drive. Persistence data is preserved.

**Q: Can I create multiple ISOs from the same system?**
A: Yes, each build is timestamped and can coexist.

## Support

- **Issues**: Report bugs on GitHub Issues
- **Discussions**: Use GitHub Discussions for questions
- **Documentation**: Check this README and script comments
- **Community**: Join our community forums

## Changelog

### Version 2.0 (Current)
- Added flexible disk selection
- Interactive mode for disk choosing
- Enhanced error handling and recovery
- Better space management
- Improved boot configuration
- Added help system

### Version 1.0
- Initial release
- Basic ISO creation functionality
- Persistent boot support

## Roadmap

- [ ] UEFI boot support
- [ ] Custom package selection GUI
- [ ] Automated testing framework
- [ ] Support for other distributions
- [ ] Encrypted persistence option
- [ ] Network deployment features

## License

This project is licensed under the MIT License - see the [LICENSE](#license) section below for details.

---

## License

MIT License


Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

*AutoISO - Making persistent Linux live systems accessible to everyone.*

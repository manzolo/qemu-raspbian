#!/bin/bash

# Script to emulate Raspberry Pi OS ARM64 with QEMU - COMPATIBILITY FIXED VERSION
# This version resolves the SD interface compatibility issues with virt machine

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables
RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_arm64/images/raspios_arm64-2023-05-03/2023-05-03-raspios-bullseye-arm64.img.xz"
RPI_IMAGE_XZ="2023-05-03-raspios-bullseye-arm64.img.xz"
RPI_IMAGE="2023-05-03-raspios-bullseye-arm64.img"
DISTRO="Bullseye"
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/bullseye"
SSH_PORT="auto"
VNC_PORT="auto"
RDP_PORT="auto"
WAYVNC_PORT="auto"
ENABLE_VNC=false
ENABLE_RDP=false
ENABLE_WAYVNC=false
HEADLESS=false
INSTANCE_ID=""
FORCE_VIRT=false

    # Detect available QEMU machine types and select the best one
detect_machine_type() {
    log "Detecting available QEMU ARM64 machine types..."
    
    # Get list of available ARM64 machines
    local available_machines=$(qemu-system-aarch64 -machine help)
    
    log "Available ARM64 machines:"
    echo "$available_machines" | grep -E "(raspi|virt)" | head -10
    
    # Always prefer raspi3b when available (proven to work with the article approach)
    if echo "$available_machines" | grep -q "raspi3b"; then
        MACHINE_TYPE="raspi3b" 
        CPU_TYPE="cortex-a72"  # Changed to match working article
        MEMORY="1G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2710-rpi-3-b-plus.dtb"  # Specific DTB for this setup
        log "Using Raspberry Pi 3B machine type (proven working configuration)"
    elif echo "$available_machines" | grep -q "raspi3ap"; then
        MACHINE_TYPE="raspi3ap"
        CPU_TYPE="cortex-a72"
        MEMORY="512M"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2710-rpi-3-b-plus.dtb"
        log "Using Raspberry Pi 3A+ machine type"
    elif [ "$FORCE_VIRT" = true ]; then
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a57"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_REQUIRED=""
        warning "Forcing use of generic ARM64 virt machine"
    else
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a57"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_REQUIRED=""
        warning "No Pi-specific machines found, using generic ARM64 virt machine"
    fi
    
    log "Selected machine: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage: $STORAGE_INTERFACE interface, root device: $ROOT_DEVICE"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS ARM64..."

    local deps=("qemu-system-aarch64" "wget" "xz" "fdisk" "openssl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt-get update"
        echo "sudo apt-get install -y qemu-system-aarch64 qemu-user-static wget xz-utils fdisk openssl"
        exit 1
    fi

    log "All dependencies are present ✓"
    detect_machine_type
}

# Download image
download_image() {
    log "Preparing working directory for ARM64..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "ARM64 image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_XZ" ]; then
        log "Downloading Raspberry Pi OS ARM64 image (approx. 818MB)..."
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Decompressing the image..."
    xz -d "$RPI_IMAGE_XZ"
}

# Extract boot files with better compatibility
extract_boot_files() {
    log "Extracting kernel and device tree for ARM64..."

    # If the files already exist, skip
    if [ -f "kernel8.img" ]; then
        log "Boot files already extracted, skipping"
        KERNEL_FILE="kernel8.img"
        if [[ "$MACHINE_TYPE" == "raspi"* ]] && [ -f "bcm2711-rpi-4-b.dtb" ]; then
            DTB_FILE="bcm2711-rpi-4-b.dtb"
        elif [[ "$MACHINE_TYPE" == "raspi"* ]] && [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
            DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
        else
            DTB_FILE=""
        fi
        return 0
    fi

    # Find the offset of the boot partition
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')

    if [ -z "$offset" ]; then
        error "Could not find the boot partition"
        exit 1
    fi

    log "Boot partition offset: $offset"

    # Create a temporary mount directory
    local mount_dir="/tmp/rpi_boot_$$"
    sudo mkdir -p "$mount_dir"

    # Mount the boot partition
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Copy kernel file
    if [ -f "$mount_dir/kernel8.img" ]; then
        cp "$mount_dir/kernel8.img" .
        KERNEL_FILE="kernel8.img"
        log "Extracted kernel: $KERNEL_FILE"
    else
        error "Could not find ARM64 kernel file"
        sudo umount "$mount_dir"
        sudo rmdir "$mount_dir"
        exit 1
    fi

    # Copy DTB file based on machine configuration
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # For Pi machines, extract the specific DTB we need
        if [ -n "$DTB_REQUIRED" ] && [ -f "$mount_dir/$DTB_REQUIRED" ]; then
            cp "$mount_dir/$DTB_REQUIRED" .
            DTB_FILE="$DTB_REQUIRED"
            log "Extracted required DTB: $DTB_FILE"
        else
            # Fallback DTB selection for Pi machines
            case "$MACHINE_TYPE" in
                "raspi3b"|"raspi3ap")
                    if [ -f "$mount_dir/bcm2710-rpi-3-b-plus.dtb" ]; then
                        cp "$mount_dir/bcm2710-rpi-3-b-plus.dtb" .
                        DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
                        log "Extracted Pi 3B+ DTB: $DTB_FILE"
                    elif [ -f "$mount_dir/bcm2710-rpi-3-b.dtb" ]; then
                        cp "$mount_dir/bcm2710-rpi-3-b.dtb" .
                        DTB_FILE="bcm2710-rpi-3-b.dtb"
                        log "Extracted Pi 3B DTB: $DTB_FILE"
                    else
                        error "Required DTB file not found for Pi machine!"
                        sudo umount "$mount_dir"
                        sudo rmdir "$mount_dir"
                        exit 1
                    fi
                    ;;
                *)
                    warning "Unknown Pi machine - trying without DTB"
                    DTB_FILE=""
                    ;;
            esac
        fi
    else
        DTB_FILE=""
        log "DTB not needed for virt machine"
    fi

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"

    log "Boot files extracted successfully ✓"
}

# Configure remote access and kernel modules - FIXED for virtio compatibility
setup_remote_access() {
    log "Configuring remote access and kernel modules for ARM64..."

    # Find the partition offsets and sizes
    local fdisk_output=$(fdisk -l "$RPI_IMAGE")
    local boot_offset=$(echo "$fdisk_output" | awk '/W95 FAT32/ {print $2 * 512}')
    local root_offset=$(echo "$fdisk_output" | awk '/Linux/ {print $2 * 512}')
    
    if [ -z "$boot_offset" ] || [ -z "$root_offset" ]; then
        error "Could not find boot or root partition offsets"
        return 1
    fi

    log "Boot partition offset: $boot_offset"
    log "Root partition offset: $root_offset"

    # Create temporary mount directories with unique names
    local boot_mount_dir="/tmp/rpi_boot_$(date +%s)_$$"
    local root_mount_dir="/tmp/rpi_root_$(date +%s)_$$"
    
    # Clean up any existing mount points first
    cleanup_mounts() {
        sudo umount "$boot_mount_dir" 2>/dev/null || true
        sudo umount "$root_mount_dir" 2>/dev/null || true
        sudo rmdir "$boot_mount_dir" 2>/dev/null || true
        sudo rmdir "$root_mount_dir" 2>/dev/null || true
    }

    if [ -n "$INSTANCE_ID" ]; then
        cleanup_instance_ports "$INSTANCE_ID" || true
    fi
    
    trap cleanup_mounts RETURN
    
    sudo mkdir -p "$boot_mount_dir"
    sudo mkdir -p "$root_mount_dir"

    # Configure boot partition first
    log "Mounting boot partition..."
    if ! sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$boot_mount_dir"; then
        error "Failed to mount boot partition"
        return 1
    fi

    # Enable SSH
    sudo touch "$boot_mount_dir/ssh"

    # Generate password hash for pi user
    log "Generating password hash for user 'pi'..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf" > /dev/null

    # Configure display settings
    log "Configuring display settings..."
    echo "" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "# Display Configuration for ARM64" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$boot_mount_dir/config.txt"

    # Configure GPU and modules for machine compatibility
    if [[ "$MACHINE_TYPE" == "virt" ]]; then
        echo "# ARM64 Virt Machine Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-bt" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-wifi" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=64" | sudo tee -a "$boot_mount_dir/config.txt"
    elif [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        echo "# ARM64 GPU Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
        
        # Enable VNC and RDP configuration for Pi machines
        if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
            echo "# Remote Desktop Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "disable_overscan=1" | sudo tee -a "$boot_mount_dir/config.txt"
        fi
    fi

    # Unmount boot partition before mounting root
    log "Unmounting boot partition..."
    sudo umount "$boot_mount_dir"

    # Now mount the root partition using a different loop device approach
    log "Mounting root partition..."
    
    # Use losetup to create a specific loop device for the root partition
    local root_loop_device=$(sudo losetup -f)
    sudo losetup -o "$root_offset" "$root_loop_device" "$RPI_IMAGE"
    
    if ! sudo mount "$root_loop_device" "$root_mount_dir"; then
        error "Failed to mount root partition"
        sudo losetup -d "$root_loop_device" 2>/dev/null || true
        return 1
    fi

    # FIXED: Configure kernel modules and initramfs for both virtio and SD card interfaces
    log "Configuring kernel modules for block device support..."
    
    # Create modules configuration to ensure block devices work
    sudo mkdir -p "$root_mount_dir/etc/modules-load.d"
    
    # Add remote desktop service to systemd if VNC or RDP is enabled
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        sudo tee "$root_mount_dir/etc/systemd/system/setup-remote-desktop.service" > /dev/null << 'EOF'
[Unit]
Description=Setup Remote Desktop Services (VNC/RDP)
After=network.target graphical-session.target
Before=display-manager.service
Wants=graphical-session.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-remote-desktop.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=graphical.target multi-user.target
EOF
        
        # Enable the service
        sudo mkdir -p "$root_mount_dir/etc/systemd/system/multi-user.target.wants"
        sudo mkdir -p "$root_mount_dir/etc/systemd/system/graphical.target.wants"
        sudo ln -sf "/etc/systemd/system/setup-remote-desktop.service" "$root_mount_dir/etc/systemd/system/multi-user.target.wants/setup-remote-desktop.service"
        sudo ln -sf "/etc/systemd/system/setup-remote-desktop.service" "$root_mount_dir/etc/systemd/system/graphical.target.wants/setup-remote-desktop.service"
        
        log "Created and enabled remote desktop setup service"
    fi
    
    if [[ "$STORAGE_INTERFACE" == "virtio" ]]; then
        # Configure for virtio block devices - more comprehensive approach
        sudo tee "$root_mount_dir/etc/modules-load.d/virtio-block.conf" > /dev/null << 'EOF'
# Critical virtio modules for QEMU virt machine - load early
virtio
virtio_ring
virtio_pci
virtio_blk
virtio_scsi
virtio_mmio
EOF
        log "Configured virtio block device modules for virt machine"
        
        # CRITICAL: Add virtio modules to initramfs-tools configuration
        sudo mkdir -p "$root_mount_dir/etc/initramfs-tools"
        
        # Check if modules file exists and handle it properly
        if [ ! -f "$root_mount_dir/etc/initramfs-tools/modules" ]; then
            sudo touch "$root_mount_dir/etc/initramfs-tools/modules"
        fi
        
        # Add virtio modules if not already present
        if ! sudo grep -q "virtio_blk" "$root_mount_dir/etc/initramfs-tools/modules"; then
            sudo tee -a "$root_mount_dir/etc/initramfs-tools/modules" > /dev/null << 'EOF'
# CRITICAL: Virtio modules must be in initramfs for early boot
virtio
virtio_ring
virtio_pci
virtio_blk
virtio_scsi
virtio_mmio
EOF
            log "Added virtio modules to initramfs"
        else
            log "Virtio modules already in initramfs configuration"
        fi
        
        # Force virtio modules to be included in initramfs
        sudo mkdir -p "$root_mount_dir/etc/initramfs-tools/conf.d"
        sudo tee "$root_mount_dir/etc/initramfs-tools/conf.d/virtio.conf" > /dev/null << 'EOF'
# Force inclusion of virtio drivers
MODULES=most
BUSYBOX=y
EOF
        log "Added virtio modules to initramfs configuration"
    else
        # Configure for SD card interface (Pi machines)
        sudo tee "$root_mount_dir/etc/modules-load.d/block-devices.conf" > /dev/null << 'EOF'
# Essential block device modules for Pi machines
mmc_block
sdhci
sdhci_of_arasan
virtio_blk
virtio_scsi
virtio_pci
EOF
        log "Configured SD card block device modules for Pi machine"
    fi

    # FIXED: Update fstab if using virtio to change root device
    if [[ "$STORAGE_INTERFACE" == "virtio" ]] && [[ "$ROOT_DEVICE" == "/dev/vda2" ]]; then
        log "Updating fstab for virtio root device..."
        
        # Backup original fstab
        sudo cp "$root_mount_dir/etc/fstab" "$root_mount_dir/etc/fstab.backup"
        
        # Update fstab to use virtio device names
        sudo sed -i 's|/dev/mmcblk0p1|/dev/vda1|g' "$root_mount_dir/etc/fstab"
        sudo sed -i 's|/dev/mmcblk0p2|/dev/vda2|g' "$root_mount_dir/etc/fstab"
        
        log "Updated fstab: /dev/mmcblk0p* -> /dev/vda*"
    fi

    # Ensure initramfs includes necessary modules
    if [ -f "$root_mount_dir/etc/initramfs-tools/modules" ]; then
        if [[ "$STORAGE_INTERFACE" == "virtio" ]]; then
            # Don't duplicate - modules already added above
            log "Virtio modules already configured in initramfs-tools"
        else
            sudo tee -a "$root_mount_dir/etc/initramfs-tools/modules" > /dev/null << 'EOF'
# Pi SD card block device support
mmc_block
sdhci
sdhci_of_arasan
EOF
        fi
    fi

    # Create a comprehensive setup script for remote desktop services
    sudo mkdir -p "$root_mount_dir/usr/local/bin"
    
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        # Create a comprehensive remote desktop setup script
        sudo tee "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << EOF
#!/bin/bash
# Comprehensive Remote Desktop Setup Script for Pi OS ARM64

# Function to log messages
log_msg() {
    echo "[REMOTE-DESKTOP] \$1" | tee -a /var/log/remote-desktop-setup.log
}

log_msg "Starting remote desktop configuration..."

# Update package lists
log_msg "Updating package lists..."
apt-get update -y

# Install desktop environment if not present
if ! dpkg -l | grep -q "raspberrypi-ui-mods"; then
    log_msg "Installing desktop environment (this may take several minutes)..."
    apt-get install -y --no-install-recommends raspberrypi-ui-mods lxterminal gvfs
fi

EOF

        # Add VNC configuration if enabled
        if [ "$ENABLE_VNC" = true ]; then
            sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure VNC Server
if [ "$ENABLE_VNC" != "false" ]; then
    log_msg "Configuring VNC server..."
    
    # Install RealVNC Server (usually pre-installed on Pi OS)
    if ! dpkg -l | grep -q "realvnc-vnc-server"; then
        log_msg "Installing RealVNC server..."
        apt-get install -y realvnc-vnc-server realvnc-vnc-viewer
    fi
    
    # Enable VNC via raspi-config
    log_msg "Enabling VNC via raspi-config..."
    raspi-config nonint do_vnc 0
    
    # Wait for VNC service to be ready
    log_msg "Waiting for VNC service to initialize..."
    sleep 5
    
    # Enable and start VNC service first
    log_msg "Starting VNC service..."
    systemctl enable vncserver-x11-serviced.service
    systemctl start vncserver-x11-serviced.service
    
    # Wait for service to be fully ready
    log_msg "Waiting for VNC service to be fully ready..."
    for i in {1..30}; do
        if systemctl is-active --quiet vncserver-x11-serviced.service; then
            log_msg "VNC service is active"
            break
        fi
        log_msg "Waiting for VNC service... (attempt $i/30)"
        sleep 5
    done
    
    # Now set the password with legacy compatibility
    log_msg "Setting VNC password with legacy compatibility..."
    echo 'raspberry' | vncpasswd -service -legacy
    
    # Restart service to apply password
    log_msg "Restarting VNC service to apply password..."
    systemctl restart vncserver-x11-serviced.service
    
    # Final verification
    if systemctl is-active --quiet vncserver-x11-serviced.service; then
        log_msg "VNC server configured and started successfully on port 5900"
        log_msg "VNC password: raspberry (legacy mode for third-party clients)"
    else
        log_msg "WARNING: VNC service may not have started properly"
    fi
fi
EOF
        fi

        # Add RDP configuration if enabled
        if [ "$ENABLE_RDP" = true ]; then
            sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure RDP Server
if [ "$ENABLE_RDP" != "false" ]; then
    log_msg "Configuring RDP server..."
    
    # Install xrdp
    log_msg "Installing xrdp server..."
    apt-get install -y xrdp
    
    # Configure xrdp
    log_msg "Configuring xrdp settings..."
    
    # Add pi user to ssl-cert group for xrdp
    usermod -a -G ssl-cert pi
    
    # Configure xrdp to use the correct session
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
# xrdp X session start script (c) 2015, 2017, 2021 mirabilos
# published under The MirOS Licence

if test -r /etc/profile; then
    . /etc/profile
fi

if test -r /etc/default/locale; then
    . /etc/default/locale
    test -z "${LANG+x}" || export LANG
    test -z "${LANGUAGE+x}" || export LANGUAGE
    test -z "${LC_ADDRESS+x}" || export LC_ADDRESS
    test -z "${LC_ALL+x}" || export LC_ALL
    test -z "${LC_COLLATE+x}" || export LC_COLLATE
    test -z "${LC_CTYPE+x}" || export LC_CTYPE
    test -z "${LC_IDENTIFICATION+x}" || export LC_IDENTIFICATION
    test -z "${LC_MEASUREMENT+x}" || export LC_MEASUREMENT
    test -z "${LC_MESSAGES+x}" || export LC_MESSAGES
    test -z "${LC_MONETARY+x}" || export LC_MONETARY
    test -z "${LC_NAME+x}" || export LC_NAME
    test -z "${LC_NUMERIC+x}" || export LC_NUMERIC
    test -z "${LC_PAPER+x}" || export LC_PAPER
    test -z "${LC_TELEPHONE+x}" || export LC_TELEPHONE
    test -z "${LC_TIME+x}" || export LC_TIME
fi

if test -r /etc/profile; then
    . /etc/profile
fi

# Start LXDE session for Pi OS
exec /usr/bin/startlxde
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    
    # Configure xrdp settings
    sed -i 's/max_bpp=32/max_bpp=16/g' /etc/xrdp/xrdp.ini
    sed -i 's/#tcp_nodelay=1/tcp_nodelay=1/g' /etc/xrdp/xrdp.ini
    
    # Enable and start xrdp service
    log_msg "Enabling xrdp service..."
    systemctl enable xrdp
    systemctl start xrdp
    
    log_msg "RDP server configured and started on port 3389"
fi
EOF
        fi

        # Complete the setup script
        sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure desktop for better remote access
log_msg "Configuring desktop settings for remote access..."

# Create desktop session configuration for pi user
sudo -u pi mkdir -p /home/pi/.config/lxsession/LXDE-pi
sudo -u pi cat > /home/pi/.config/lxsession/LXDE-pi/desktop.conf << 'DESKTOPEOF'
[Session]
window_manager=openbox-lxde-pi
windows_manager/command=openbox-lxde-pi
windows_manager/session=LXDE-pi
disable_autostart=no
polkit/command=lxpolkit
clipboard/command=lxclipboard
xscreensaver/command=light-locker
power_manager/command=lxde-pi-powermanagement
quit_manager/command=lxsession-logout
upgrade_manager/command=lxsession-default-apps
lock_manager/command=light-locker-command -l
launcher_manager/command=lxpanelctl

[GTK]
sNet/ThemeName=PiX
sNet/IconThemeName=PiX
sGtk/FontName=PibotoLt 12
iGtk/ToolbarStyle=3
iGtk/ButtonImages=1
iGtk/MenuImages=1
iGtk/CursorThemeSize=24
iXft/Antialias=1
iXft/Hinting=1
iXft/HintStyle=hintslight
iXft/RGBA=rgb
DESKTOPEOF

# Enable autologin for pi user to start desktop session
log_msg "Configuring autologin for desktop session..."
systemctl set-default graphical.target

# Create marker file to indicate setup is complete
touch /boot/.remote-desktop-configured

log_msg "Remote desktop setup completed successfully!"
log_msg "VNC available on port 5900 (password: raspberry)"
log_msg "RDP available on port 3389 (user: pi, password: raspberry)"
EOF

        # Make the setup script executable
        sudo chmod +x "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh"

        # Set environment variables for the script
        echo "ENABLE_VNC=$ENABLE_VNC" | sudo tee "$root_mount_dir/etc/environment" > /dev/null
        echo "ENABLE_RDP=$ENABLE_RDP" | sudo tee -a "$root_mount_dir/etc/environment" > /dev/null

        log "Created comprehensive remote desktop setup script"
    fi
    
    if [[ "$STORAGE_INTERFACE" == "virtio" ]]; then
        # Special script for virtio compatibility with aggressive module loading
        sudo tee "$root_mount_dir/usr/local/bin/fix-virtio.sh" > /dev/null << 'EOF'
#!/bin/bash
# Critical virtio setup for QEMU compatibility

# Function to log messages
log_msg() {
    echo "[VIRTIO-FIX] $1" | tee -a /var/log/virtio-fix.log
}

log_msg "Starting virtio compatibility setup..."

# Force load critical virtio modules if not already loaded
for module in virtio virtio_ring virtio_pci virtio_blk virtio_scsi virtio_mmio; do
    if ! lsmod | grep -q "^$module"; then
        log_msg "Loading module: $module"
        modprobe "$module" 2>/dev/null && log_msg "Successfully loaded $module" || log_msg "Failed to load $module"
    else
        log_msg "Module $module already loaded"
    fi
done

# Check if virtio block devices are detected
if ls /dev/vda* >/dev/null 2>&1; then
    log_msg "Virtio block devices detected: $(ls /dev/vda* 2>/dev/null | tr '\n' ' ')"
else
    log_msg "WARNING: No virtio block devices found!"
    log_msg "Available block devices: $(ls /dev/ | grep -E '^(sd|hd|vd|nvme|mmcblk)' | tr '\n' ' ')"
fi

# Rebuild initramfs if needed
if [ ! -f /boot/.virtio-initramfs-fixed ]; then
    log_msg "Updating initramfs with virtio modules..."
    
    # Force update of all kernels
    update-initramfs -u -k all
    
    # Create marker
    touch /boot/.virtio-initramfs-fixed
    
    log_msg "Initramfs updated. System should reboot for changes to take effect."
    log_msg "Scheduling reboot in 10 seconds..."
    
    # Schedule reboot to apply initramfs changes
    (sleep 10 && reboot) &
    
else
    log_msg "Virtio initramfs already configured"
fi

log_msg "Virtio setup complete"
EOF
    else
        # Standard script for Pi machines
        sudo tee "$root_mount_dir/usr/local/bin/fix-virtio.sh" > /dev/null << 'EOF'
#!/bin/bash
# Fix initramfs for Pi machine compatibility
if [ ! -f /boot/.initramfs-fixed ]; then
    echo "Updating initramfs for Pi machine compatibility..."
    
    # Ensure block device modules are loaded
    modprobe mmc_block 2>/dev/null || true
    modprobe sdhci 2>/dev/null || true
    
    # Update initramfs
    update-initramfs -u -k all
    
    # Mark as fixed
    touch /boot/.initramfs-fixed
    
    echo "Initramfs updated for Pi machine. Continuing boot..."
fi
EOF
    fi

    sudo chmod +x "$root_mount_dir/usr/local/bin/fix-virtio.sh"

    # Add the script to run on boot (but only once) with higher priority
    if [ -f "$root_mount_dir/etc/rc.local" ]; then
        # Insert before the final 'exit 0' line
        sudo sed -i '/^exit 0/i /usr/local/bin/fix-virtio.sh &' "$root_mount_dir/etc/rc.local"
    fi
    
    # Also add to systemd for better compatibility
    if [ -d "$root_mount_dir/etc/systemd/system" ]; then
        sudo tee "$root_mount_dir/etc/systemd/system/virtio-fix.service" > /dev/null << 'EOF'
[Unit]
Description=Fix Virtio Block Device Support
Before=multi-user.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-virtio.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        
        # Enable the service by creating a symlink
        sudo mkdir -p "$root_mount_dir/etc/systemd/system/multi-user.target.wants"
        sudo ln -sf "/etc/systemd/system/virtio-fix.service" "$root_mount_dir/etc/systemd/system/multi-user.target.wants/virtio-fix.service"
        log "Created systemd service for virtio setup"
    fi

    # Unmount root partition and detach loop device
    log "Unmounting root partition..."
    sudo umount "$root_mount_dir"
    sudo losetup -d "$root_loop_device"

    log "Remote access and kernel modules configured for ARM64 ✓"
}

# Resize image
resize_image() {
    log "Resizing ARM64 image..."

    # Check current size
    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 8000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi

    # Specify format explicitly to avoid warnings
    qemu-img resize -f raw "$RPI_IMAGE" 8G
    log "Image resized to 8GB ✓"
}

# Start QEMU with proper interface selection based on machine type
start_qemu() {
    log "Starting QEMU Raspberry Pi ARM64 emulation..."
    log "Using machine type: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage interface: $STORAGE_INTERFACE, root device: $ROOT_DEVICE"
    
    # Build QEMU command
    local qemu_cmd="qemu-system-aarch64"
    local qemu_args=(
        "-machine" "$MACHINE_TYPE"
        "-cpu" "$CPU_TYPE"
        "-m" "$MEMORY"
        "-smp" "4"
    )

    # FIXED: Add storage using the approach that actually works
    if [[ "$STORAGE_INTERFACE" == "sd" ]] && [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # Use the proven working approach from the article
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=sd,index=0")
        log "Using SD card interface for Pi machine (proven working method)"
    elif [[ "$STORAGE_INTERFACE" == "virtio" ]] || [[ "$MACHINE_TYPE" == "virt" ]]; then
        # Use virtio interface for virt machine
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        log "Using virtio interface for virt machine"
    else
        # Fallback
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        warning "Using virtio fallback"
    fi

    # Configure boot using the proven working approach
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # Use the exact approach from the working article
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            
            # Use the exact kernel command line that works
            local cmdline="rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=$ROOT_DEVICE rootdelay=1"
            qemu_args+=("-append" "$cmdline")
            log "Using proven working kernel command line for Pi machine"
        fi

        # Add DTB if available - this is critical for Pi machines
        if [ -n "$DTB_FILE" ] && [ -f "$DTB_FILE" ]; then
            qemu_args+=("-dtb" "$DTB_FILE")
            log "Using DTB: $DTB_FILE (required for Pi machine boot)"
        else
            error "DTB file missing - Pi machine will not boot without it!"
            return 1
        fi
    else
        # For virt machine, use virtio approach
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            local cmdline="root=$ROOT_DEVICE rw console=ttyAMA0,115200 console=tty0 rootdelay=15 rootfstype=ext4"
            qemu_args+=("-append" "$cmdline")
            log "Using virt machine kernel boot"
        fi
    fi

    # Network configuration with VNC and RDP support
    qemu_args+=("-device" "usb-net,netdev=net0")
    
    # Build network forwarding options
    local netdev_options="user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5900"
        log "VNC will be available on port $VNC_PORT (password: raspberry)"
    fi
    
    if [ "$ENABLE_WAYVNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$WAYVNC_PORT-:5901"
        log "WayVNC will be available on port $WAYVNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        netdev_options+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "RDP will be available on port $RDP_PORT (user: pi, password: raspberry)"
    fi
    
    qemu_args+=("-netdev" "$netdev_options")

    # Display configuration - use nographic for proven compatibility
    if [ "$HEADLESS" = true ]; then
        qemu_args+=("-nographic")
        log "Running in headless mode (nographic)"
    else
        qemu_args+=("-nographic")
        log "Using nographic mode for maximum compatibility"
    fi

    # Show connection info
    echo
    log "Connection Information:"
    echo "  SSH: ssh -p $SSH_PORT pi@localhost"
    echo "  Password: $RPI_PASSWORD"
    
    if [ "$ENABLE_VNC" = true ]; then
        echo "  RealVNC: localhost:$VNC_PORT (password: raspberry)"
    fi
    
    if [ "$ENABLE_WAYVNC" = true ]; then
        echo "  WayVNC: localhost:$WAYVNC_PORT (user: pi, password: raspberry)"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        echo "  RDP: localhost:$RDP_PORT (username: pi, password: raspberry)"
    fi
    
    echo
    warning "Machine Type: $MACHINE_TYPE ($CPU_TYPE with $MEMORY RAM)"
    warning "Storage: $STORAGE_INTERFACE interface, root device: $ROOT_DEVICE"
    
    if [[ "$MACHINE_TYPE" == "virt" ]]; then
        warning "Generic ARM64 Virtual Machine Configuration:"
        echo "  - Virtio block device interface (/dev/vda*)"
        echo "  - Better QEMU stability and compatibility"
        echo "  - Pi OS adapted to work with virtio devices"
        echo "  - Root device: $ROOT_DEVICE (adapted from Pi OS)"
    else
        warning "Raspberry Pi ARM64 Features:"
        echo "  - Pi-specific hardware emulation"
        echo "  - Native SD card interface (/dev/mmcblk0*)"
        echo "  - Root device: $ROOT_DEVICE"
    fi
    
    echo
    warning "Boot Process:"
    echo "  - First boot may take 5-10 minutes for system adaptation"
    echo "  - System will configure block device modules automatically"
    echo "  - Wait for login prompt before attempting SSH connection"
    echo "  - If you see kernel messages, the system is booting normally"
    echo
    warning "QEMU Controls:"
    if [ "$HEADLESS" = false ]; then
        echo "  Ctrl+A, X: Exit emulation"
        echo "  Ctrl+A, C: Switch to QEMU monitor"
    else
        echo "  Ctrl+A, X: Exit emulation (in headless mode)"
    fi
    echo "  If QEMU hangs: Kill with Ctrl+C and restart"
    echo
    
    log "Starting ARM64 emulation with fixed block device compatibility..."
    
    echo "QEMU Command:"
    echo "$qemu_cmd ${qemu_args[*]}"
    echo
    
    log "Waiting for boot... (this may take several minutes)"
    
    log "Starting [$DISTRO] emulation..."
    "$qemu_cmd" "${qemu_args[@]}" &
    local qemu_pid=$!
    
    # FIXED: Update the state file with the actual QEMU PID
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            # Update PID in state file using a temporary file to avoid race conditions
            local temp_file=$(mktemp)
            sed "s/PID=PENDING/PID=$qemu_pid/" "$state_file" > "$temp_file"
            mv "$temp_file" "$state_file"
            log "Updated instance $INSTANCE_ID with QEMU PID $qemu_pid"
        else
            warning "State file not found for instance $INSTANCE_ID"
        fi
    fi
    
    # Wait for QEMU process to complete
    wait $qemu_pid
    local exit_code=$?
    
    log "QEMU process $qemu_pid exited with code $exit_code"
    return $exit_code

}

# Cleanup function
cleanup() {
    log "Cleaning up..."
    
    # Standard filesystem cleanup
    sudo umount /tmp/rpi_boot_* 2>/dev/null || true
    sudo umount /tmp/rpi_root_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_boot_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_root_* 2>/dev/null || true
    
    # Distribution-specific cleanup (like Jessie filesystem unmounting)
    # Add distribution-specific cleanup here if needed
    
    # Port cleanup - only if we allocated the ports ourselves
    if [ -n "$INSTANCE_ID" ] && [ "$need_allocation" = true ]; then
        log "Cleaning up ports for instance $INSTANCE_ID (allocated by this script)"
        cleanup_instance_ports "$INSTANCE_ID"
    elif [ -n "$INSTANCE_ID" ]; then
        log "Instance $INSTANCE_ID managed by menu, not cleaning up ports"
    fi
}


# Handle signals for cleanup
trap cleanup EXIT INT TERM

# Main function
main() {
    echo -e "${BLUE}"
    echo "==============================================="
    echo "  QEMU Raspberry Pi - [$DISTRO]"
    echo "==============================================="
    echo -e "${NC}"

    check_dependencies
    download_image
    extract_boot_files
    setup_remote_access
    resize_image

    echo
    log "Setup complete! Starting [$DISTRO] emulation..."
    echo

    # FIXED: Better port allocation logic
    local need_allocation=false
    
    # Check if we need to allocate ports (when called from menu, ports are already allocated)
    if [ -z "$ALLOCATED_SSH_PORT" ]; then
        # We're being called directly, not from menu
        need_allocation=true
        INSTANCE_ID=$(generate_instance_id "$DISTRO")
        
        log "Script called directly, allocating new ports for instance $INSTANCE_ID"
        
        if ! allocate_ports "$INSTANCE_ID" "$ENABLE_VNC" "$ENABLE_RDP" "$ENABLE_WAYVNC" \
                            "$SSH_PORT" "$VNC_PORT" "$RDP_PORT" "$WAYVNC_PORT"; then
            error "Failed to allocate ports for direct script execution"
            exit 1
        fi
        
        # Update variables with allocated ports
        SSH_PORT=$ALLOCATED_SSH_PORT
        if [ "$ENABLE_VNC" = true ]; then VNC_PORT=$ALLOCATED_VNC_PORT; fi
        if [ "$ENABLE_RDP" = true ]; then RDP_PORT=$ALLOCATED_RDP_PORT; fi
        if [ "$ENABLE_WAYVNC" = true ]; then WAYVNC_PORT=$ALLOCATED_WAYVNC_PORT; fi
        
    else
        # We're being called from menu, ports already allocated
        log "Using pre-allocated ports from menu: SSH=$ALLOCATED_SSH_PORT"
        if [ "$ENABLE_VNC" = true ] && [ -n "$ALLOCATED_VNC_PORT" ]; then 
            log "VNC port: $ALLOCATED_VNC_PORT"
        fi
        if [ "$ENABLE_RDP" = true ] && [ -n "$ALLOCATED_RDP_PORT" ]; then 
            log "RDP port: $ALLOCATED_RDP_PORT"
        fi
        if [ "$ENABLE_WAYVNC" = true ] && [ -n "$ALLOCATED_WAYVNC_PORT" ]; then 
            log "WayVNC port: $ALLOCATED_WAYVNC_PORT"
        fi
        
        # Use the allocated ports
        SSH_PORT=$ALLOCATED_SSH_PORT
        if [ "$ENABLE_VNC" = true ]; then VNC_PORT=$ALLOCATED_VNC_PORT; fi
        if [ "$ENABLE_RDP" = true ]; then RDP_PORT=$ALLOCATED_RDP_PORT; fi
        if [ "$ENABLE_WAYVNC" = true ]; then WAYVNC_PORT=$ALLOCATED_WAYVNC_PORT; fi
    fi

    start_qemu
}

# Show help
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: 2222)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi-bullseye)"
    echo "  --vnc [PORT]      Enable RealVNC server (default port: 5900)"
    echo "  --wayvnc [PORT]   Enable WayVNC for Wayland (default port: 5901)"
    echo "  --rdp [PORT]      Enable RDP server (default port: 3389)"
    echo "  --headless        Run without display (headless mode)"
    echo "  --force-virt      Force use of generic ARM64 virt machine"
    echo
    echo "Block Device Compatibility Fixes:"
    echo "  - Uses correct interface for each machine type (SD for Pi, virtio for virt)"
    echo "  - Automatically adapts Pi OS fstab for virtio devices when needed"
    echo "  - Configures appropriate kernel modules for each storage interface"  
    echo "  - Updates root device path based on selected machine and interface"
    echo
    echo "Examples:"
    echo "  $0                               # Auto-detect best machine type"
    echo "  $0 --force-virt                  # Use generic ARM64 machine with virtio"
    echo "  $0 --headless --vnc              # Headless with VNC"
    echo "  $0 --force-virt --headless       # Most compatible headless setup"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p)
            SSH_PORT="$2"
            shift 2
            ;;
        -d)
            WORK_DIR="$2"
            shift 2
            ;;
        --vnc)
            ENABLE_VNC=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                VNC_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --rdp)
            ENABLE_RDP=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                RDP_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --wayvnc)
            ENABLE_WAYVNC=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                WAYVNC_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --headless)
            HEADLESS=true
            shift 1
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main

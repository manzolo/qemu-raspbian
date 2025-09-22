#!/bin/bash

# Script to emulate Raspberry Pi OS Bookworm ARMv7 with QEMU - COMPATIBILITY FIXED VERSION
# This version resolves the SD interface compatibility issues with virt machine

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables - Updated for Bookworm ARMv7
RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_full_armhf/images/raspios_full_armhf-2025-05-13/2025-05-13-raspios-bookworm-armhf-full.img.xz"
RPI_IMAGE_XZ="2025-05-13-raspios-bookworm-armhf-full.img.xz"
RPI_IMAGE="2025-05-13-raspios-bookworm-armhf-full.img"
DISTRO="Bookworm"
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/bookworm"
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

# Detect available QEMU machine types and select the best one for ARMv7
detect_machine_type() {
    log "Detecting available QEMU ARMv7 machine types..."
    
    # Get list of available ARM machines
    local available_machines=$(qemu-system-arm -machine help)
    
    log "Available ARMv7 machines:"
    echo "$available_machines" | grep -E "(raspi|virt)" | head -10
    
    # Prefer raspi machines for better compatibility with Pi OS
    if echo "$available_machines" | grep -q "raspi4b"; then
        MACHINE_TYPE="raspi4b" 
        CPU_TYPE="cortex-a72"
        MEMORY="4G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2711-rpi-4-b.dtb"
        log "Using Raspberry Pi 4B machine type (best compatibility for Bookworm)"
    elif echo "$available_machines" | grep -q "raspi3b"; then
        MACHINE_TYPE="raspi3b" 
        CPU_TYPE="cortex-a53"
        MEMORY="1G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2710-rpi-3-b-plus.dtb"
        log "Using Raspberry Pi 3B machine type"
    elif echo "$available_machines" | grep -q "raspi2b"; then
        MACHINE_TYPE="raspi2b"
        CPU_TYPE="cortex-a15"
        MEMORY="1G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2709-rpi-2-b.dtb"
        log "Using Raspberry Pi 2B machine type"
    elif [ "$FORCE_VIRT" = true ]; then
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a15"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_REQUIRED=""
        warning "Forcing use of generic ARMv7 virt machine"
    else
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a15"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_REQUIRED=""
        warning "No Pi-specific machines found, using generic ARMv7 virt machine"
    fi
    
    log "Selected machine: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage: $STORAGE_INTERFACE interface, root device: $ROOT_DEVICE"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS Bookworm ARMv7..."

    local deps=("qemu-system-arm" "wget" "xz" "fdisk" "openssl")
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
        echo "sudo apt-get install -y qemu-system-arm qemu-user-static wget xz-utils fdisk openssl"
        exit 1
    fi

    log "All dependencies are present ✓"
    detect_machine_type
}

# Download image
download_image() {
    log "Preparing working directory for Bookworm ARMv7..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Bookworm ARMv7 image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_XZ" ]; then
        log "Downloading Raspberry Pi OS Bookworm ARMv7 Full image (approx. 2.8GB compressed)..."
        warning "This is the full desktop version - download may take some time"
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Decompressing the image... (this may take several minutes)"
    xz -d "$RPI_IMAGE_XZ"
    log "Image decompression complete"
}

# Extract boot files with better compatibility for ARMv7
extract_boot_files() {
    log "Extracting kernel and device tree for Bookworm ARMv7..."

    # If the files already exist, skip
    if [ -f "kernel7l.img" ] || [ -f "kernel.img" ]; then
        log "Boot files already extracted, skipping"
        
        # Determine which kernel to use based on machine type
        if [[ "$MACHINE_TYPE" == "raspi4b" ]] && [ -f "kernel7l.img" ]; then
            KERNEL_FILE="kernel7l.img"
        elif [[ "$MACHINE_TYPE" == "raspi3"* ]] && [ -f "kernel7.img" ]; then
            KERNEL_FILE="kernel7.img"
        elif [ -f "kernel7l.img" ]; then
            KERNEL_FILE="kernel7l.img"
        elif [ -f "kernel7.img" ]; then
            KERNEL_FILE="kernel7.img"
        elif [ -f "kernel.img" ]; then
            KERNEL_FILE="kernel.img"
        else
            error "No suitable kernel found"
            exit 1
        fi
        
        # Set DTB file based on machine
        if [[ "$MACHINE_TYPE" == "raspi4b" ]] && [ -f "bcm2711-rpi-4-b.dtb" ]; then
            DTB_FILE="bcm2711-rpi-4-b.dtb"
        elif [[ "$MACHINE_TYPE" == "raspi3"* ]] && [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
            DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
        elif [[ "$MACHINE_TYPE" == "raspi2b" ]] && [ -f "bcm2709-rpi-2-b.dtb" ]; then
            DTB_FILE="bcm2709-rpi-2-b.dtb"
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

    # Copy kernel file based on machine type
    if [[ "$MACHINE_TYPE" == "raspi4b" ]] && [ -f "$mount_dir/kernel7l.img" ]; then
        cp "$mount_dir/kernel7l.img" .
        KERNEL_FILE="kernel7l.img"
        log "Extracted Pi 4 kernel: $KERNEL_FILE"
    elif [[ "$MACHINE_TYPE" == "raspi3"* ]] && [ -f "$mount_dir/kernel7.img" ]; then
        cp "$mount_dir/kernel7.img" .
        KERNEL_FILE="kernel7.img"
        log "Extracted Pi 3 kernel: $KERNEL_FILE"
    elif [ -f "$mount_dir/kernel7l.img" ]; then
        cp "$mount_dir/kernel7l.img" .
        KERNEL_FILE="kernel7l.img"
        log "Extracted ARMv7 kernel: $KERNEL_FILE"
    elif [ -f "$mount_dir/kernel7.img" ]; then
        cp "$mount_dir/kernel7.img" .
        KERNEL_FILE="kernel7.img"
        log "Extracted ARMv7 kernel: $KERNEL_FILE"
    elif [ -f "$mount_dir/kernel.img" ]; then
        cp "$mount_dir/kernel.img" .
        KERNEL_FILE="kernel.img"
        log "Extracted ARM kernel: $KERNEL_FILE"
    else
        error "Could not find suitable ARMv7 kernel file"
        sudo umount "$mount_dir"
        sudo rmdir "$mount_dir"
        exit 1
    fi

    # Copy DTB file based on machine configuration
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # For Pi machines, extract the specific DTB we need
        case "$MACHINE_TYPE" in
            "raspi4b")
                if [ -f "$mount_dir/bcm2711-rpi-4-b.dtb" ]; then
                    cp "$mount_dir/bcm2711-rpi-4-b.dtb" .
                    DTB_FILE="bcm2711-rpi-4-b.dtb"
                    log "Extracted Pi 4B DTB: $DTB_FILE"
                else
                    error "Required DTB file not found for Pi 4B machine!"
                    sudo umount "$mount_dir"
                    sudo rmdir "$mount_dir"
                    exit 1
                fi
                ;;
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
                    error "Required DTB file not found for Pi 3 machine!"
                    sudo umount "$mount_dir"
                    sudo rmdir "$mount_dir"
                    exit 1
                fi
                ;;
            "raspi2b")
                if [ -f "$mount_dir/bcm2709-rpi-2-b.dtb" ]; then
                    cp "$mount_dir/bcm2709-rpi-2-b.dtb" .
                    DTB_FILE="bcm2709-rpi-2-b.dtb"
                    log "Extracted Pi 2B DTB: $DTB_FILE"
                else
                    error "Required DTB file not found for Pi 2B machine!"
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
    log "Configuring remote access and kernel modules for Bookworm ARMv7..."

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

    # Generate password hash for pi user (Bookworm uses userconf.txt)
    log "Configuring user credentials for Bookworm..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf.txt" > /dev/null

    # Configure display settings for Bookworm
    log "Configuring display settings for Bookworm..."
    
    # Backup original config.txt
    if [ -f "$boot_mount_dir/config.txt" ]; then
        sudo cp "$boot_mount_dir/config.txt" "$boot_mount_dir/config.txt.backup"
    fi
    
    echo "" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "# Display Configuration for Bookworm ARMv7" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "disable_overscan=1" | sudo tee -a "$boot_mount_dir/config.txt"

    # Configure GPU and modules for machine compatibility
    if [[ "$MACHINE_TYPE" == "virt" ]]; then
        echo "# ARMv7 Virt Machine Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-bt" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-wifi" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=64" | sudo tee -a "$boot_mount_dir/config.txt"
    elif [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        echo "# Bookworm ARMv7 GPU Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        
        # Bookworm-specific GPU settings
        if [[ "$MACHINE_TYPE" == "raspi4b" ]]; then
            echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "arm_64bit=0" | sudo tee -a "$boot_mount_dir/config.txt"  # Force 32-bit mode
        else
            echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
            echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
        fi
        
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
    log "Configuring kernel modules for Bookworm block device support..."
    
    # Create modules configuration to ensure block devices work
    sudo mkdir -p "$root_mount_dir/etc/modules-load.d"
    
    # Add remote desktop service to systemd if VNC or RDP is enabled
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        sudo tee "$root_mount_dir/etc/systemd/system/setup-remote-desktop.service" > /dev/null << 'EOF'
[Unit]
Description=Setup Remote Desktop Services (VNC/RDP) for Bookworm
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
        
        log "Created and enabled remote desktop setup service for Bookworm"
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

    # Create a comprehensive setup script for remote desktop services (Bookworm-specific)
    sudo mkdir -p "$root_mount_dir/usr/local/bin"
    
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        # Create a comprehensive remote desktop setup script for Bookworm
        sudo tee "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << EOF
#!/bin/bash
# Comprehensive Remote Desktop Setup Script for Pi OS Bookworm ARMv7

# Function to log messages
log_msg() {
    echo "[BOOKWORM-REMOTE-DESKTOP] \$1" | tee -a /var/log/remote-desktop-setup.log
}

log_msg "Starting remote desktop configuration for Bookworm..."

# Update package lists
log_msg "Updating package lists..."
apt-get update -y

# Install desktop environment if not present (Bookworm uses different packages)
if ! dpkg -l | grep -q "raspberry-pi-ui-mods"; then
    log_msg "Installing desktop environment for Bookworm (this may take several minutes)..."
    apt-get install -y --no-install-recommends raspberry-pi-ui-mods lxterminal gvfs
fi

EOF

        # Add VNC configuration if enabled (Bookworm-specific)
        if [ "$ENABLE_VNC" = true ]; then
            sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure VNC Server for Bookworm
if [ "$ENABLE_VNC" != "false" ]; then
    log_msg "Configuring VNC server for Bookworm..."
    
    # Install RealVNC Server (should be pre-installed on Bookworm)
    if ! dpkg -l | grep -q "realvnc-vnc-server"; then
        log_msg "Installing RealVNC server..."
        apt-get install -y realvnc-vnc-server realvnc-vnc-viewer
    fi
    
    # Enable VNC via raspi-config (Bookworm version)
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
    
    # Set the password with legacy compatibility for Bookworm
    log_msg "Setting VNC password with legacy compatibility for Bookworm..."
    echo 'raspberry' | vncpasswd -service -legacy
    
    # Configure VNC settings for better compatibility
    mkdir -p /root/.vnc
    cat > /root/.vnc/config.d/common.custom << 'VNCEOF'
Encryption=PreferOff
Authentication=VncAuth
VNCEOF
    
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

        # Add RDP configuration if enabled (Bookworm-specific)
        if [ "$ENABLE_RDP" = true ]; then
            sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure RDP Server for Bookworm
if [ "$ENABLE_RDP" != "false" ]; then
    log_msg "Configuring RDP server for Bookworm..."
    
    # Install xrdp
    log_msg "Installing xrdp server..."
    apt-get install -y xrdp
    
    # Configure xrdp for Bookworm
    log_msg "Configuring xrdp settings for Bookworm..."
    
    # Add pi user to ssl-cert group for xrdp
    usermod -a -G ssl-cert pi
    
    # Configure xrdp to use the correct session for Bookworm
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
# xrdp X session start script for Bookworm

if test -r /etc/profile; then
    . /etc/profile
fi

if test -r /etc/default/locale; then
    . /etc/default/locale
    test -z "${LANG+x}" || export LANG
    test -z "${LANGUAGE+x}" || export LANGUAGE
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

# Start Wayfire session for Bookworm (default in newer versions)
if command -v wayfire >/dev/null 2>&1; then
    exec wayfire
# Fallback to LXDE session for compatibility
elif command -v startlxde-pi >/dev/null 2>&1; then
    exec startlxde-pi
else
    exec /usr/bin/startlxde
fi
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    
    # Configure xrdp settings for better performance
    sed -i 's/max_bpp=32/max_bpp=16/g' /etc/xrdp/xrdp.ini
    sed -i 's/#tcp_nodelay=1/tcp_nodelay=1/g' /etc/xrdp/xrdp.ini
    sed -i 's/crypt_level=high/crypt_level=low/g' /etc/xrdp/xrdp.ini
    
    # Enable and start xrdp service
    log_msg "Enabling xrdp service..."
    systemctl enable xrdp
    systemctl start xrdp
    
    log_msg "RDP server configured and started on port 3389"
fi
EOF
        fi

        # Complete the setup script for Bookworm
        sudo tee -a "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
# Configure desktop for better remote access on Bookworm
log_msg "Configuring desktop settings for remote access on Bookworm..."

# Create desktop session configuration for pi user (Bookworm-specific)
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
sNet/ThemeName=PiX-Dark
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

# Configure Wayfire for Bookworm if available
sudo -u pi mkdir -p /home/pi/.config/wayfire
sudo -u pi cat > /home/pi/.config/wayfire/wayfire.ini << 'WAYFIREEOF'
[core]
plugins = alpha animate autostart command cube decoration expo fast-switcher fisheye grid idle invert move oswitch place resize switcher vswitch window-rules wm-actions wobbly zoom

[input]
xkb_layout = us

[output:HDMI-A-1]
mode = 1920x1080@60000
position = 0,0
transform = normal
scale = 1.000000

[idle]
screensaver_timeout = 300
dpms_timeout = 600
WAYFIREEOF

# Enable autologin for pi user to start desktop session
log_msg "Configuring autologin for desktop session..."
systemctl set-default graphical.target

# Create marker file to indicate setup is complete
touch /boot/.remote-desktop-configured

log_msg "Remote desktop setup completed successfully for Bookworm!"
log_msg "VNC available on port 5900 (password: raspberry)"
log_msg "RDP available on port 3389 (user: pi, password: raspberry)"
log_msg "Bookworm may use Wayfire or LXDE depending on configuration"
EOF

        # Make the setup script executable
        sudo chmod +x "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh"

        # Set environment variables for the script
        echo "ENABLE_VNC=$ENABLE_VNC" | sudo tee "$root_mount_dir/etc/environment" > /dev/null
        echo "ENABLE_RDP=$ENABLE_RDP" | sudo tee -a "$root_mount_dir/etc/environment" > /dev/null

        log "Created comprehensive remote desktop setup script for Bookworm"
    fi
    
    if [[ "$STORAGE_INTERFACE" == "virtio" ]]; then
        # Special script for virtio compatibility with aggressive module loading
        sudo tee "$root_mount_dir/usr/local/bin/fix-virtio.sh" > /dev/null << 'EOF'
#!/bin/bash
# Critical virtio setup for QEMU compatibility - Bookworm version

# Function to log messages
log_msg() {
    echo "[BOOKWORM-VIRTIO-FIX] $1" | tee -a /var/log/virtio-fix.log
}

log_msg "Starting virtio compatibility setup for Bookworm..."

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

# Rebuild initramfs if needed (Bookworm-specific)
if [ ! -f /boot/.virtio-initramfs-fixed ]; then
    log_msg "Updating initramfs with virtio modules for Bookworm..."
    
    # Force update of all kernels
    update-initramfs -u -k all
    
    # Create marker
    touch /boot/.virtio-initramfs-fixed
    
    log_msg "Initramfs updated for Bookworm. System should reboot for changes to take effect."
    log_msg "Scheduling reboot in 10 seconds..."
    
    # Schedule reboot to apply initramfs changes
    (sleep 10 && reboot) &
    
else
    log_msg "Virtio initramfs already configured for Bookworm"
fi

log_msg "Virtio setup complete for Bookworm"
EOF
    else
        # Standard script for Pi machines (Bookworm)
        sudo tee "$root_mount_dir/usr/local/bin/fix-virtio.sh" > /dev/null << 'EOF'
#!/bin/bash
# Fix initramfs for Pi machine compatibility - Bookworm version
if [ ! -f /boot/.initramfs-fixed ]; then
    echo "Updating initramfs for Pi machine compatibility on Bookworm..."
    
    # Ensure block device modules are loaded
    modprobe mmc_block 2>/dev/null || true
    modprobe sdhci 2>/dev/null || true
    
    # Update initramfs
    update-initramfs -u -k all
    
    # Mark as fixed
    touch /boot/.initramfs-fixed
    
    echo "Initramfs updated for Pi machine on Bookworm. Continuing boot..."
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
Description=Fix Virtio Block Device Support for Bookworm
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

    log "Remote access and kernel modules configured for Bookworm ARMv7 ✓"
}

# Resize image - FIXED for Pi machine SD card requirements
resize_image() {
    log "Resizing Bookworm ARMv7 image..."

    # Check current size (Bookworm full image is larger)
    local current_size=$(stat -c%s "$RPI_IMAGE")
    
    # For Pi machines, SD card size must be power of 2
    local target_size
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # SD card must be power of 2 for Pi machines
        target_size="16G"  # 16 GiB = power of 2
        local target_bytes=17179869184  # 16 * 1024^3
    else
        # Virt machines can use any size
        target_size="12G"
        local target_bytes=12884901888  # 12 * 1000^3
    fi
    
    if [ $current_size -gt $target_bytes ]; then
        log "Image already resized to $target_size, skipping"
        return 0
    fi

    log "Resizing to $target_size (required for $MACHINE_TYPE machine)..."
    
    # Specify format explicitly to avoid warnings
    if ! qemu-img resize -f raw "$RPI_IMAGE" "$target_size"; then
        error "Failed to resize image to $target_size"
        return 1
    fi
    
    log "Image resized to $target_size for Bookworm ✓"
    
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        log "SD card size is now power of 2 as required by Pi machines"
    fi
}

# Start QEMU with proper interface selection based on machine type
start_qemu() {
    log "Starting QEMU Raspberry Pi Bookworm ARMv7 emulation..."
    log "Using machine type: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage interface: $STORAGE_INTERFACE, root device: $ROOT_DEVICE"
    
    # Build QEMU command for ARMv7
    local qemu_cmd="qemu-system-arm"
    local qemu_args=(
        "-machine" "$MACHINE_TYPE"
        "-cpu" "$CPU_TYPE"
        "-m" "$MEMORY"
        "-smp" "4"
    )

    # FIXED: Add storage using the approach that actually works for ARMv7
    if [[ "$STORAGE_INTERFACE" == "sd" ]] && [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # Use the proven working approach from the article for ARMv7 Pi machines
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=sd,index=0")
        log "Using SD card interface for Pi machine (proven working method for ARMv7)"
    elif [[ "$STORAGE_INTERFACE" == "virtio" ]] || [[ "$MACHINE_TYPE" == "virt" ]]; then
        # Use virtio interface for virt machine
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        log "Using virtio interface for virt machine"
    else
        # Fallback
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        warning "Using virtio fallback"
    fi

    # Configure boot using the proven working approach for ARMv7
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # Use the exact approach from the working article for ARMv7
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            
            # Use the exact kernel command line that works for ARMv7
            local cmdline="rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=$ROOT_DEVICE rootdelay=1"
            qemu_args+=("-append" "$cmdline")
            log "Using proven working kernel command line for ARMv7 Pi machine"
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
            log "Using virt machine kernel boot for ARMv7"
        fi
    fi

    # Network configuration with VNC and RDP support - FIXED for Pi machines
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        # Pi machines use USB-based networking or built-in interfaces
        if [[ "$MACHINE_TYPE" == "raspi4b" ]]; then
            # Pi 4 has built-in Ethernet via PCIe
            qemu_args+=("-device" "usb-net,netdev=net0")
        elif [[ "$MACHINE_TYPE" == "raspi3"* ]]; then
            # Pi 3 uses USB-based networking
            qemu_args+=("-device" "usb-net,netdev=net0")
        else
            # Pi 2 and older use USB networking
            qemu_args+=("-device" "usb-net,netdev=net0")
        fi
        log "Using USB network interface for Pi machine"
    else
        # Virt machines can use PCI-based networking
        qemu_args+=("-device" "rtl8139,netdev=net0")
        log "Using PCI network interface for virt machine"
    fi
    
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
    log "Connection Information for Bookworm:"
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
        warning "Generic ARMv7 Virtual Machine Configuration:"
        echo "  - Virtio block device interface (/dev/vda*)"
        echo "  - Better QEMU stability and compatibility"
        echo "  - Bookworm Pi OS adapted to work with virtio devices"
        echo "  - Root device: $ROOT_DEVICE (adapted from Pi OS)"
    else
        warning "Raspberry Pi ARMv7 Features for Bookworm:"
        echo "  - Pi-specific hardware emulation"
        echo "  - Native SD card interface (/dev/mmcblk0*)"
        echo "  - Root device: $ROOT_DEVICE"
        echo "  - Bookworm desktop environment (Wayfire/LXDE)"
    fi
    
    echo
    warning "Boot Process:"
    echo "  - First boot may take 10-15 minutes for Bookworm full desktop setup"
    echo "  - System will configure block device modules automatically"
    echo "  - Bookworm may take longer to boot due to additional desktop components"
    echo "  - SD card resized to 16GB (power of 2 requirement for Pi machines)"
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
    
    log "Starting Bookworm ARMv7 emulation with fixed block device compatibility..."
    
    echo "QEMU Command:"
    echo "$qemu_cmd ${qemu_args[*]}"
    echo
    
    log "Waiting for Bookworm boot... (this may take 10-15 minutes on first boot)"
    
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
    echo "Raspberry Pi OS Bookworm ARMv7 Full Desktop Emulator"
    echo "This version emulates the full desktop version of Bookworm with all applications."
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: 2222)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi-bookworm)"
    echo "  --vnc [PORT]      Enable RealVNC server (default port: 5900)"
    echo "  --wayvnc [PORT]   Enable WayVNC for Wayland (default port: 5901)"
    echo "  --rdp [PORT]      Enable RDP server (default port: 3389)"
    echo "  --headless        Run without display (headless mode)"
    echo "  --force-virt      Force use of generic ARMv7 virt machine"
    echo
    echo "Bookworm-specific Features:"
    echo "  - Full desktop environment with all applications"
    echo "  - Supports both Wayfire (Wayland) and LXDE desktop environments"
    echo "  - Updated package repositories and software"
    echo "  - Enhanced remote desktop compatibility"
    echo "  - Larger image size (12GB) to accommodate full desktop"
    echo
    echo "Block Device Compatibility Fixes:"
    echo "  - Uses correct interface for each machine type (SD for Pi, virtio for virt)"
    echo "  - SD card size automatically set to 16GB (power of 2) for Pi machines"
    echo "  - Automatically adapts Pi OS fstab for virtio devices when needed"
    echo "  - Configures appropriate kernel modules for each storage interface"  
    echo "  - Updates root device path based on selected machine and interface"
    echo
    echo "Examples:"
    echo "  $0                               # Auto-detect best ARMv7 machine type"
    echo "  $0 --force-virt                  # Use generic ARMv7 machine with virtio"
    echo "  $0 --headless --vnc              # Headless with VNC for remote desktop"
    echo "  $0 --force-virt --headless --rdp # Most compatible setup with RDP"
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
        --wayvnc)
            ENABLE_WAYVNC=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                WAYVNC_PORT="$2"
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
        --headless)
            HEADLESS=true
            shift 1
            ;;
        --force-virt)
            FORCE_VIRT=true
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

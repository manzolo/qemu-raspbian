#!/bin/bash

# Script to emulate Raspberry Pi OS Bookworm with QEMU - FIXED VERSION
# Corrected to match Bullseye's working approach with proper architecture detection

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables - Updated for Bookworm
RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_full_arm64/images/raspios_full_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-full.img.xz"
RPI_IMAGE_XZ="2025-05-13-raspios-bookworm-arm64-full.img.xz"
RPI_IMAGE="2025-05-13-raspios-bookworm-arm64-full.img"
DISTRO="Bookworm"
DISTRO_LOWER=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
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
CURRENT_QEMU_PID=""
FORCE_VIRT=false

# Detect machine type and architecture - FIXED to match Bullseye approach
detect_machine_type() {
    log "Detecting available QEMU machine types for Bookworm..."
    
    # First determine if we should use ARM or AARCH64
    # Check if image is 64-bit or 32-bit by examining the URL
    if [[ "$RPI_IMAGE_URL" == *"armhf"* ]]; then
        # 32-bit ARM image - use qemu-system-arm
        QEMU_CMD="qemu-system-arm"
        ARCH_TYPE="armv7"
        log "Detected 32-bit armhf image, using qemu-system-arm"
    else
        # 64-bit ARM image - use qemu-system-aarch64
        QEMU_CMD="qemu-system-aarch64"
        ARCH_TYPE="arm64"
        log "Detected 64-bit image, using qemu-system-aarch64"
    fi
    
    # Get list of available machines for the detected architecture
    local available_machines=$($QEMU_CMD -machine help)
    
    log "Available machines for $ARCH_TYPE:"
    echo "$available_machines" | grep -E "(raspi|virt)" | head -10
    
    # Select appropriate machine based on architecture
    if [ "$ARCH_TYPE" = "arm64" ]; then
        # 64-bit machines (similar to Bullseye)
        if echo "$available_machines" | grep -q "raspi3b"; then
            MACHINE_TYPE="raspi3b" 
            CPU_TYPE="cortex-a72"
            MEMORY="1G"
            STORAGE_INTERFACE="sd"
            ROOT_DEVICE="/dev/mmcblk0p2"
            DTB_REQUIRED="bcm2710-rpi-3-b-plus.dtb"
            log "Using Raspberry Pi 3B machine type for 64-bit"
        elif [ "$FORCE_VIRT" = true ] || ! echo "$available_machines" | grep -q "raspi"; then
            MACHINE_TYPE="virt"
            CPU_TYPE="cortex-a72"
            MEMORY="2G"
            STORAGE_INTERFACE="virtio"
            ROOT_DEVICE="/dev/vda2"
            DTB_REQUIRED=""
            log "Using generic ARM64 virt machine"
        fi
    else
        # 32-bit machines
        if echo "$available_machines" | grep -q "raspi3b"; then
            MACHINE_TYPE="raspi3b" 
            CPU_TYPE="cortex-a53"
            MEMORY="1G"
            STORAGE_INTERFACE="sd"
            ROOT_DEVICE="/dev/mmcblk0p2"
            DTB_REQUIRED="bcm2710-rpi-3-b-plus.dtb"
            log "Using Raspberry Pi 3B machine type for 32-bit"
        elif echo "$available_machines" | grep -q "raspi2b"; then
            MACHINE_TYPE="raspi2b"
            CPU_TYPE="cortex-a15"
            MEMORY="1G"
            STORAGE_INTERFACE="sd"
            ROOT_DEVICE="/dev/mmcblk0p2"
            DTB_REQUIRED="bcm2709-rpi-2-b.dtb"
            log "Using Raspberry Pi 2B machine type for 32-bit"
        elif [ "$FORCE_VIRT" = true ] || ! echo "$available_machines" | grep -q "raspi"; then
            MACHINE_TYPE="virt"
            CPU_TYPE="cortex-a15"
            MEMORY="2G"
            STORAGE_INTERFACE="virtio"
            ROOT_DEVICE="/dev/vda2"
            DTB_REQUIRED=""
            log "Using generic ARMv7 virt machine"
        fi
    fi
    
    log "Selected: $QEMU_CMD with $MACHINE_TYPE machine, $CPU_TYPE CPU, $MEMORY RAM"
    log "Storage: $STORAGE_INTERFACE interface, root device: $ROOT_DEVICE"
}

# Check dependencies - Updated to check both qemu-system-arm and qemu-system-aarch64
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS Bookworm..."

    local deps=("wget" "xz" "fdisk" "openssl")
    local missing=()

    # Check for either qemu-system-arm or qemu-system-aarch64
    if ! command -v qemu-system-arm &> /dev/null && ! command -v qemu-system-aarch64 &> /dev/null; then
        missing+=("qemu-system (arm or aarch64)")
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt-get update"
        echo "sudo apt-get install -y qemu-system-arm qemu-system-aarch64 wget xz-utils fdisk openssl"
        exit 1
    fi

    log "All dependencies are present ✓"
    detect_machine_type
}

# Download image - unchanged
download_image() {
    log "Preparing working directory for Bookworm..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Bookworm image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_XZ" ]; then
        log "Downloading Raspberry Pi OS Bookworm Full image (approx. 2.4GB compressed)..."
        warning "This is the full desktop version - download may take some time"
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Decompressing the image... (this may take several minutes)"
    xz -d "$RPI_IMAGE_XZ"
    log "Image decompression complete"
}

# Extract boot files - Updated to handle both architectures properly
extract_boot_files() {
    log "Extracting kernel and device tree for Bookworm..."

    # Check for existing files
    if [ "$ARCH_TYPE" = "arm64" ]; then
        if [ -f "kernel8.img" ]; then
            log "Boot files already extracted for ARM64"
            KERNEL_FILE="kernel8.img"
            if [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
                DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
            elif [ -f "bcm2710-rpi-3-b.dtb" ]; then
                DTB_FILE="bcm2710-rpi-3-b.dtb"
            fi
            return 0
        fi
    else
        if [ -f "kernel7l.img" ] || [ -f "kernel7.img" ]; then
            log "Boot files already extracted for ARMv7"
            if [ -f "kernel7l.img" ]; then
                KERNEL_FILE="kernel7l.img"
            elif [ -f "kernel7.img" ]; then
                KERNEL_FILE="kernel7.img"
            fi
            
            if [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
                DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
            elif [ -f "bcm2709-rpi-2-b.dtb" ]; then
                DTB_FILE="bcm2709-rpi-2-b.dtb"
            fi
            return 0
        fi
    fi

    # Extract from image
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')
    if [ -z "$offset" ]; then
        error "Could not find the boot partition"
        exit 1
    fi

    log "Boot partition offset: $offset"
    local mount_dir="/tmp/rpi_boot_$$"
    sudo mkdir -p "$mount_dir"
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Extract appropriate kernel based on architecture
    if [ "$ARCH_TYPE" = "arm64" ]; then
        if [ -f "$mount_dir/kernel8.img" ]; then
            cp "$mount_dir/kernel8.img" .
            KERNEL_FILE="kernel8.img"
            log "Extracted ARM64 kernel: $KERNEL_FILE"
        else
            error "Could not find ARM64 kernel in Bookworm image"
            sudo umount "$mount_dir"
            sudo rmdir "$mount_dir"
            exit 1
        fi
    else
        if [ -f "$mount_dir/kernel7l.img" ]; then
            cp "$mount_dir/kernel7l.img" .
            KERNEL_FILE="kernel7l.img"
            log "Extracted ARMv7 long kernel: $KERNEL_FILE"
        elif [ -f "$mount_dir/kernel7.img" ]; then
            cp "$mount_dir/kernel7.img" .
            KERNEL_FILE="kernel7.img"
            log "Extracted ARMv7 kernel: $KERNEL_FILE"
        else
            error "Could not find suitable ARMv7 kernel in Bookworm image"
            sudo umount "$mount_dir"
            sudo rmdir "$mount_dir"
            exit 1
        fi
    fi

    # Extract appropriate DTB
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        if [ -f "$mount_dir/$DTB_REQUIRED" ]; then
            cp "$mount_dir/$DTB_REQUIRED" .
            DTB_FILE="$DTB_REQUIRED"
            log "Extracted required DTB: $DTB_FILE"
        else
            # Try fallback DTBs
            for dtb in "bcm2710-rpi-3-b-plus.dtb" "bcm2710-rpi-3-b.dtb" "bcm2709-rpi-2-b.dtb"; do
                if [ -f "$mount_dir/$dtb" ]; then
                    cp "$mount_dir/$dtb" .
                    DTB_FILE="$dtb"
                    log "Extracted fallback DTB: $DTB_FILE"
                    break
                fi
            done
        fi
    fi

    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"
    log "Boot files extracted successfully ✓"
}

# Setup remote access - Similar to Bullseye's approach
setup_remote_access() {
    log "Configuring remote access and kernel modules for Bookworm..."

    # Find the partition offsets
    local fdisk_output=$(fdisk -l "$RPI_IMAGE")
    local boot_offset=$(echo "$fdisk_output" | awk '/W95 FAT32/ {print $2 * 512}')
    local root_offset=$(echo "$fdisk_output" | awk '/Linux/ {print $2 * 512}')
    
    if [ -z "$boot_offset" ] || [ -z "$root_offset" ]; then
        error "Could not find boot or root partition offsets"
        return 1
    fi

    log "Boot partition offset: $boot_offset"
    log "Root partition offset: $root_offset"

    local boot_mount_dir="/tmp/rpi_boot_$(date +%s)_$$"
    local root_mount_dir="/tmp/rpi_root_$(date +%s)_$$"
    
    cleanup_mounts() {
        sudo umount "$boot_mount_dir" 2>/dev/null || true
        sudo umount "$root_mount_dir" 2>/dev/null || true
        sudo rmdir "$boot_mount_dir" 2>/dev/null || true
        sudo rmdir "$root_mount_dir" 2>/dev/null || true
    }
    
    trap cleanup_mounts RETURN
    
    sudo mkdir -p "$boot_mount_dir"
    sudo mkdir -p "$root_mount_dir"

    # Configure boot partition
    log "Mounting boot partition..."
    if ! sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$boot_mount_dir"; then
        error "Failed to mount boot partition"
        return 1
    fi

    # Enable SSH
    sudo touch "$boot_mount_dir/ssh"

    # Configure user credentials
    log "Configuring user credentials for Bookworm..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf.txt" > /dev/null

    # Configure display settings
    log "Configuring display settings for Bookworm..."
    if [ -f "$boot_mount_dir/config.txt" ]; then
        sudo cp "$boot_mount_dir/config.txt" "$boot_mount_dir/config.txt.backup"
    fi
    
    echo "" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "# Display Configuration for Bookworm" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$boot_mount_dir/config.txt"

    # Configure GPU and modules based on machine type
    if [[ "$MACHINE_TYPE" == "virt" ]]; then
        echo "# Virt Machine Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-bt" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-wifi" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=64" | sudo tee -a "$boot_mount_dir/config.txt"
    else
        echo "# GPU Configuration for Pi Machine" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
    fi

    sudo umount "$boot_mount_dir"

    # Configure root filesystem
    log "Mounting root partition..."
    local root_loop_device=$(sudo losetup -f)
    sudo losetup -o "$root_offset" "$root_loop_device" "$RPI_IMAGE"
    
    if ! sudo mount "$root_loop_device" "$root_mount_dir"; then
        error "Failed to mount root partition"
        sudo losetup -d "$root_loop_device" 2>/dev/null || true
        return 1
    fi

    # Configure kernel modules for block device support
    log "Configuring kernel modules for block device support..."
    sudo mkdir -p "$root_mount_dir/etc/modules-load.d"
    
    if [[ "$STORAGE_INTERFACE" == "virtio" ]]; then
        sudo tee "$root_mount_dir/etc/modules-load.d/virtio-block.conf" > /dev/null << 'EOF'
# Virtio modules for QEMU virt machine
virtio
virtio_ring
virtio_pci
virtio_blk
virtio_scsi
virtio_mmio
EOF
        
        # Update fstab for virtio
        if [[ "$ROOT_DEVICE" == "/dev/vda2" ]]; then
            log "Updating fstab for virtio root device..."
            sudo cp "$root_mount_dir/etc/fstab" "$root_mount_dir/etc/fstab.backup"
            sudo sed -i 's|/dev/mmcblk0p1|/dev/vda1|g' "$root_mount_dir/etc/fstab"
            sudo sed -i 's|/dev/mmcblk0p2|/dev/vda2|g' "$root_mount_dir/etc/fstab"
            log "Updated fstab for virtio devices"
        fi
    else
        sudo tee "$root_mount_dir/etc/modules-load.d/block-devices.conf" > /dev/null << 'EOF'
# Block device modules for Pi machines
mmc_block
sdhci
sdhci_of_arasan
virtio_blk
virtio_scsi
virtio_pci
EOF
    fi

    # Setup remote desktop services if needed (similar to Bullseye)
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        # Create comprehensive setup script
        sudo mkdir -p "$root_mount_dir/usr/local/bin"
        sudo tee "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
#!/bin/bash
# Remote Desktop Setup for Bookworm

log_msg() {
    echo "[BOOKWORM-DESKTOP] $1" | tee -a /var/log/remote-desktop-setup.log
}

# Check if already configured
if [ -f "/boot/.remote-desktop-configured" ]; then
    log_msg "Remote desktop already configured. Exiting."
    exit 0
fi

log_msg "Starting remote desktop configuration..."

# Update package lists
apt update -y

# Install desktop if needed
if ! dpkg -l | grep -q "raspberrypi-ui-mods"; then
    log_msg "Installing desktop environment..."
    apt install -y --no-install-recommends raspberrypi-ui-mods lxterminal gvfs
fi

# Configure VNC if enabled
if [ "$ENABLE_VNC" != "false" ]; then
    log_msg "Configuring VNC server..."
    
    if ! dpkg -l | grep -q "realvnc-vnc-server"; then
        apt install -y realvnc-vnc-server realvnc-vnc-viewer
    fi
    
    raspi-config nonint do_vnc 0
    
    sleep 5
    
    systemctl enable vncserver-x11-serviced.service
    systemctl start vncserver-x11-serviced.service
    
    # Wait for service to be ready
    for i in {1..30}; do
        if systemctl is-active --quiet vncserver-x11-serviced.service; then
            log_msg "VNC service is active"
            break
        fi
        log_msg "Waiting for VNC service... (attempt $i/30)"
        sleep 5
    done
    
    # Set password with legacy compatibility
    echo 'raspberry' | vncpasswd -service -legacy
    
    systemctl restart vncserver-x11-serviced.service
    
    log_msg "VNC configured on port 5900"
fi

# Configure RDP if enabled
if [ "$ENABLE_RDP" != "false" ]; then
    log_msg "Configuring RDP server..."
    
    apt install -y xrdp
    
    usermod -a -G ssl-cert pi
    
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
if test -r /etc/profile; then . /etc/profile; fi
if test -r /etc/default/locale; then . /etc/default/locale; fi
exec /usr/bin/startlxde-pi
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    
    sed -i 's/max_bpp=32/max_bpp=16/g' /etc/xrdp/xrdp.ini
    
    systemctl enable xrdp
    systemctl start xrdp
    
    log_msg "RDP configured on port 3389"
fi

# Mark as configured
touch /boot/.remote-desktop-configured

log_msg "Remote desktop setup completed!"
EOF

        sudo chmod +x "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh"

        # Create systemd service
        sudo tee "$root_mount_dir/etc/systemd/system/setup-remote-desktop.service" > /dev/null << 'EOF'
[Unit]
Description=Setup Remote Desktop Services
After=network.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-remote-desktop.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

        # Enable the service
        sudo mkdir -p "$root_mount_dir/etc/systemd/system/multi-user.target.wants"
        sudo ln -sf "/etc/systemd/system/setup-remote-desktop.service" "$root_mount_dir/etc/systemd/system/multi-user.target.wants/"

        # Set environment variables
        echo "ENABLE_VNC=$ENABLE_VNC" | sudo tee "$root_mount_dir/etc/environment" > /dev/null
        echo "ENABLE_RDP=$ENABLE_RDP" | sudo tee -a "$root_mount_dir/etc/environment" > /dev/null
        
        log "Created remote desktop setup service"
    fi

    setup_first_boot_script "$root_mount_dir" "bookworm"
    
    # Unmount root partition
    sudo umount "$root_mount_dir"
    sudo losetup -d "$root_loop_device"

    log "Remote access configured for Bookworm ✓"
}

# Resize image - unchanged
resize_image() {
    log "Resizing Bookworm image..."

    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 16000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi

    qemu-img resize -f raw "$RPI_IMAGE" 16G
    log "Image resized to 16GB ✓"
}

# Start QEMU - Fixed to use proper command based on architecture
start_qemu() {
    log "Starting QEMU Raspberry Pi Bookworm emulation..."
    log "Using: $QEMU_CMD with $MACHINE_TYPE machine"
    log "CPU: $CPU_TYPE, Memory: $MEMORY"
    log "Storage: $STORAGE_INTERFACE interface, root: $ROOT_DEVICE"
    
    # Build QEMU command
    local qemu_args=(
        "-machine" "$MACHINE_TYPE"
        "-cpu" "$CPU_TYPE"
        "-m" "$MEMORY"
        "-smp" "4"
    )

    # Add storage using the proven approach from Bullseye
    if [[ "$STORAGE_INTERFACE" == "sd" ]] && [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=sd,index=0")
        log "Using SD card interface for Pi machine"
    else
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        log "Using virtio interface"
    fi

    # Configure boot
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            
            # Use proven kernel command line from Bullseye
            local cmdline="rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=$ROOT_DEVICE rootdelay=1"
            qemu_args+=("-append" "$cmdline")
            log "Using Pi machine kernel command line"
        fi

        if [ -n "$DTB_FILE" ] && [ -f "$DTB_FILE" ]; then
            qemu_args+=("-dtb" "$DTB_FILE")
            log "Using DTB: $DTB_FILE"
        else
            warning "DTB file missing - Pi machine may not boot properly"
        fi
    else
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            local cmdline="root=$ROOT_DEVICE rw console=ttyAMA0,115200 console=tty0 rootdelay=15 rootfstype=ext4"
            qemu_args+=("-append" "$cmdline")
            log "Using virt machine kernel boot"
        fi
    fi

    # Network configuration
    qemu_args+=("-device" "usb-net,netdev=net0")
    
    local netdev_options="user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5900"
        log "VNC will be available on port $VNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        netdev_options+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "RDP will be available on port $RDP_PORT"
    fi
    
    if [ "$ENABLE_WAYVNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$WAYVNC_PORT-:5901"
        log "WayVNC will be available on port $WAYVNC_PORT"
    fi
    
    qemu_args+=("-netdev" "$netdev_options")

    # Display configuration
    if [ "$HEADLESS" = true ]; then
        local monitor_port=$(shuf -i 20000-30000 -n 1)
        qemu_args+=("-nographic")
        qemu_args+=("-chardev" "stdio,id=char0,signal=off")
        qemu_args+=("-serial" "chardev:char0")
        qemu_args+=("-monitor" "telnet:127.0.0.1:$monitor_port,server,nowait")
        log "Running in headless mode - monitor on telnet port $monitor_port"
    else
        qemu_args+=("-serial" "stdio")
        qemu_args+=("-monitor" "vc")
        log "Running in GUI mode"
    fi

    # Show connection info
    echo
    log "Connection Information:"
    echo "  SSH: ssh -p $SSH_PORT pi@localhost"
    echo "  Password: $RPI_PASSWORD"
    
    if [ "$ENABLE_VNC" = true ]; then
        echo "  VNC: localhost:$VNC_PORT (password: raspberry)"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        echo "  RDP: localhost:$RDP_PORT (user: pi, password: raspberry)"
    fi
    
    echo
    warning "Architecture: $ARCH_TYPE ($QEMU_CMD)"
    warning "Machine: $MACHINE_TYPE ($CPU_TYPE with $MEMORY RAM)"
    warning "Kernel: $KERNEL_FILE"
    warning "Storage: $STORAGE_INTERFACE interface, root: $ROOT_DEVICE"
    
    echo
    warning "Boot Process:"
    echo "  - First boot may take 5-10 minutes for Bookworm setup"
    echo "  - Wait for login prompt before SSH connection"
    echo "  - Remote desktop services will auto-configure if enabled"
    
    echo
    warning "QEMU Controls:"
    echo "  Ctrl+A, X: Exit emulation"
    echo "  Ctrl+A, C: Switch to QEMU monitor"
    echo "  Ctrl+C: Force stop"
    echo
    
    log "Starting Bookworm emulation..."
    echo "Command: $QEMU_CMD ${qemu_args[*]}"
    echo
    
    "$QEMU_CMD" "${qemu_args[@]}" &
    local qemu_pid=$!
    
    export CURRENT_QEMU_PID=$qemu_pid
    
    # Update PID in state file
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            local temp_file=$(mktemp)
            sed "s/PID=PENDING/PID=$qemu_pid/" "$state_file" > "$temp_file"
            mv "$temp_file" "$state_file"
            log "Updated instance $INSTANCE_ID with QEMU PID $qemu_pid"
        fi
    fi
    
    # Monitor process
    (
        while true; do
            if ! kill -0 $qemu_pid 2>/dev/null; then
                log "QEMU process $qemu_pid has terminated"
                if [ -n "$INSTANCE_ID" ]; then
                    cleanup_instance_ports "$INSTANCE_ID"
                fi
                exit 0
            fi
            sleep 1
        done
    ) &
    local monitor_pid=$!
    
    cleanup_on_exit() {
        kill $monitor_pid 2>/dev/null || true
        if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
            kill -TERM "$qemu_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
        if [ -n "$INSTANCE_ID" ]; then
            cleanup_instance_ports "$INSTANCE_ID"
        fi
    }
    
    trap cleanup_on_exit TERM INT EXIT
    
    # Wait for QEMU process
    wait $qemu_pid
    local exit_code=$?
    
    # Explicit cleanup
    kill $monitor_pid 2>/dev/null || true
    
    if [ -n "$INSTANCE_ID" ]; then
        log "QEMU exited with code $exit_code, cleaning up instance $INSTANCE_ID"
        cleanup_instance_ports "$INSTANCE_ID"
    fi
    
    return $exit_code
}

# Handle shutdown signal
handle_shutdown() {
    local qemu_pid=$1
    local monitor_pid=$2
    
    log "Received shutdown signal (Ctrl+C), cleaning up gracefully..."
    
    if [ -n "$monitor_pid" ]; then
        kill $monitor_pid 2>/dev/null || true
    fi
    
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        log "Sending TERM signal to QEMU process $qemu_pid"
        kill -TERM "$qemu_pid" 2>/dev/null || true
        
        local count=0
        while kill -0 "$qemu_pid" 2>/dev/null && [ $count -lt 10 ]; do
            sleep 1
            ((count++))
        done
        
        if kill -0 "$qemu_pid" 2>/dev/null; then
            log "Force killing QEMU process $qemu_pid"
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
    fi
    
    if [ -n "$INSTANCE_ID" ]; then
        log "Cleaning up instance $INSTANCE_ID"
        cleanup_instance_ports "$INSTANCE_ID"
    fi
    
    log "Cleanup completed, exiting"
    exit 0
}

# Cleanup function
cleanup() {
    log "Running cleanup function..."
    
    # Standard filesystem cleanup
    sudo umount /tmp/rpi_boot_* 2>/dev/null || true
    sudo umount /tmp/rpi_root_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_boot_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_root_* 2>/dev/null || true
    
    # Instance cleanup only if we own it
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$OWNER_PID" = "$" ] || [ "$need_allocation" = "true" ]; then
                log "Cleaning up ports for instance $INSTANCE_ID (we own it)"
                cleanup_instance_ports "$INSTANCE_ID"
            else
                log "Instance $INSTANCE_ID owned by different process, not cleaning up"
            fi
        fi
    fi
    
    # Cleanup orphaned QEMU processes
    if [ -n "$CURRENT_QEMU_PID" ] && kill -0 "$CURRENT_QEMU_PID" 2>/dev/null; then
        log "Terminating orphaned QEMU process $CURRENT_QEMU_PID"
        kill -TERM "$CURRENT_QEMU_PID" 2>/dev/null || true
    fi
}

# Handle signals for cleanup
trap 'cleanup; exit 130' INT     # Ctrl+C
trap 'cleanup; exit 143' TERM    # Terminate signal  
trap 'cleanup' EXIT              # Normal exit

# Main function
main() {
    echo -e "${BLUE}"
    echo "==============================================="
    echo "  QEMU Raspberry Pi - [$DISTRO]"
    echo "==============================================="
    echo -e "${NC}"

    auto_cleanup_dead_instances
    
    check_dependencies
    download_image
    extract_boot_files
    setup_remote_access
    resize_image

    echo
    log "Setup complete! Starting [$DISTRO] emulation..."
    echo

    # Port allocation logic
    local need_allocation=false
    
    if [ -z "$ALLOCATED_SSH_PORT" ]; then
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
        
        export need_allocation=true        
    else
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
        
        export need_allocation=false
    fi

    start_qemu
}

# Show help
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Raspberry Pi OS Bookworm Full Desktop Emulator (FIXED)"
    echo "This version automatically detects the correct architecture."
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: auto-allocated)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi-bookworm)"
    echo "  --vnc [PORT]      Enable RealVNC server (default: auto-allocated)"
    echo "  --rdp [PORT]      Enable RDP server (default: auto-allocated)"
    echo "  --wayvnc [PORT]   Enable WayVNC for Wayland (default: auto-allocated)"
    echo "  --headless        Run without display (headless mode)"
    echo "  --force-virt      Force use of generic virt machine"
    echo
    echo "FIXED Features:"
    echo "  - Automatic architecture detection (ARM vs AARCH64)"
    echo "  - Proper machine selection based on available QEMU support"
    echo "  - Correct kernel selection (kernel8.img for 64-bit, kernel7/7l for 32-bit)"
    echo "  - Compatible with both armhf and arm64 images"
    echo "  - Proven storage interface configuration from Bullseye"
    echo
    echo "Examples:"
    echo "  $0                               # Auto-detect best configuration"
    echo "  $0 --force-virt                  # Use generic virt machine"
    echo "  $0 --headless --vnc              # Headless with VNC"
    echo "  $0 --force-virt --headless --rdp # Most compatible setup"
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
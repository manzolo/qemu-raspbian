#!/bin/bash

# Script to emulate Raspberry Pi OS Bookworm ARMv7 with QEMU - CORRECTED VERSION
# Fixed architecture consistency and machine type selection

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables - CORRECTED for Bookworm ARMv7
RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_full_armhf/images/raspios_full_armhf-2025-05-13/2025-05-13-raspios-bookworm-armhf-full.img.xz"
RPI_IMAGE_XZ="2025-05-13-raspios-bookworm-armhf-full.img.xz"
RPI_IMAGE="2025-05-13-raspios-bookworm-armhf-full.img"
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

# CORRECTED: Detect machine types appropriate for ARMv7
detect_machine_type() {
    log "Detecting available QEMU ARMv7 machine types for Bookworm..."
    
    # Get list of available ARM machines
    local available_machines=$(qemu-system-arm -machine help)
    
    log "Available ARMv7 machines:"
    echo "$available_machines" | grep -E "(raspi|virt)" | head -10
    
    # CORRECTED: Use ARMv7-compatible machines only
    if echo "$available_machines" | grep -q "raspi3ap"; then
        MACHINE_TYPE="raspi3ap" 
        CPU_TYPE="cortex-a53"
        MEMORY="512M"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_REQUIRED="bcm2710-rpi-3-a-plus.dtb"
        log "Using Raspberry Pi 3A+ machine type (optimal for Bookworm ARMv7)"
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
        log "Downloading Raspberry Pi OS Bookworm ARMv7 Full image (approx. 2.4GB compressed)..."
        warning "This is the full desktop version - download may take some time"
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Decompressing the image... (this may take several minutes)"
    xz -d "$RPI_IMAGE_XZ"
    log "Image decompression complete"
}

# CORRECTED: Extract boot files for ARMv7 consistency
extract_boot_files() {
    log "Extracting kernel and device tree for Bookworm ARMv7..."

    # Check for existing files and select correct kernel
    if [ -f "kernel7l.img" ] || [ -f "kernel7.img" ]; then
        log "Boot files already extracted, selecting appropriate kernel"
        
        # CORRECTED: Prioritize ARMv7 kernels
        if [ -f "kernel7l.img" ]; then
            KERNEL_FILE="kernel7l.img"
            log "Using kernel7l.img (ARMv7 long-mode)"
        elif [ -f "kernel7.img" ]; then
            KERNEL_FILE="kernel7.img"
            log "Using kernel7.img (ARMv7 standard)"
        else
            error "No suitable ARMv7 kernel found"
            exit 1
        fi
        
        # Set appropriate DTB
        case "$MACHINE_TYPE" in
            "raspi3"*)
                if [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
                    DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
                elif [ -f "bcm2710-rpi-3-b.dtb" ]; then
                    DTB_FILE="bcm2710-rpi-3-b.dtb"
                fi
                ;;
            "raspi2b")
                if [ -f "bcm2709-rpi-2-b.dtb" ]; then
                    DTB_FILE="bcm2709-rpi-2-b.dtb"
                fi
                ;;
            *)
                DTB_FILE=""
                ;;
        esac
        
        return 0
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

    # CORRECTED: Extract appropriate ARMv7 kernel
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

    # Extract appropriate DTB
    case "$MACHINE_TYPE" in
        "raspi3"*)
            if [ -f "$mount_dir/bcm2710-rpi-3-b-plus.dtb" ]; then
                cp "$mount_dir/bcm2710-rpi-3-b-plus.dtb" .
                DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
                log "Extracted Pi 3B+ DTB: $DTB_FILE"
            elif [ -f "$mount_dir/bcm2710-rpi-3-b.dtb" ]; then
                cp "$mount_dir/bcm2710-rpi-3-b.dtb" .
                DTB_FILE="bcm2710-rpi-3-b.dtb"
                log "Extracted Pi 3B DTB: $DTB_FILE"
            fi
            ;;
        "raspi2b")
            if [ -f "$mount_dir/bcm2709-rpi-2-b.dtb" ]; then
                cp "$mount_dir/bcm2709-rpi-2-b.dtb" .
                DTB_FILE="bcm2709-rpi-2-b.dtb"
                log "Extracted Pi 2B DTB: $DTB_FILE"
            fi
            ;;
        *)
            DTB_FILE=""
            log "DTB not needed for virt machine"
            ;;
    esac

    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"
    log "ARMv7 boot files extracted successfully ✓"
}

# Configure remote access and kernel modules
setup_remote_access() {
    log "Configuring remote access and kernel modules for Bookworm ARMv7..."

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

    # Configure user credentials for Bookworm
    log "Configuring user credentials for Bookworm..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf.txt" > /dev/null

    # Configure display settings for Bookworm
    log "Configuring display settings for Bookworm ARMv7..."
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

    # CORRECTED: GPU configuration for ARMv7
    if [[ "$MACHINE_TYPE" == "virt" ]]; then
        echo "# ARMv7 Virt Machine Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-bt" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=disable-wifi" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=64" | sudo tee -a "$boot_mount_dir/config.txt"
    else
        echo "# Bookworm ARMv7 GPU Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
        # REMOVED: arm_64bit=0 (not needed for ARMv7 emulation)
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
    log "Configuring kernel modules for Bookworm ARMv7 block device support..."
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
EOF
    fi

    # Create basic setup script for remote desktop if needed
    sudo mkdir -p "$root_mount_dir/usr/local/bin"
    
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        sudo tee "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh" > /dev/null << 'EOF'
#!/bin/bash
# Basic Remote Desktop Setup for Bookworm ARMv7

log_msg() {
    echo "[BOOKWORM-DESKTOP] $1" | tee -a /var/log/remote-desktop-setup.log
}

log_msg "Starting remote desktop configuration for Bookworm ARMv7..."

# Update package lists
apt-get update -y

# Install desktop if needed
if ! dpkg -l | grep -q "raspberry-pi-ui-mods"; then
    log_msg "Installing desktop environment..."
    apt-get install -y --no-install-recommends raspberry-pi-ui-mods lxterminal
fi

# Configure VNC if enabled
if [ "${ENABLE_VNC:-false}" = "true" ]; then
    log_msg "Setting up VNC server..."
    if ! dpkg -l | grep -q "realvnc-vnc-server"; then
        apt-get install -y realvnc-vnc-server
    fi
    
    raspi-config nonint do_vnc 0
    systemctl enable vncserver-x11-serviced.service
    systemctl start vncserver-x11-serviced.service
    
    # Set VNC password
    echo 'raspberry' | vncpasswd -service
    systemctl restart vncserver-x11-serviced.service
    
    log_msg "VNC configured on port 5900 (password: raspberry)"
fi

# Configure RDP if enabled
if [ "${ENABLE_RDP:-false}" = "true" ]; then
    log_msg "Setting up RDP server..."
    apt-get install -y xrdp
    
    # Configure xrdp for Bookworm
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
if test -r /etc/profile; then . /etc/profile; fi
if test -r /etc/default/locale; then . /etc/default/locale; fi

# Start LXDE desktop
exec /usr/bin/startlxde-pi
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    systemctl enable xrdp
    systemctl start xrdp
    
    log_msg "RDP configured on port 3389"
fi

log_msg "Remote desktop setup complete!"
EOF
        
        sudo chmod +x "$root_mount_dir/usr/local/bin/setup-remote-desktop.sh"
        
        # Create systemd service
        sudo tee "$root_mount_dir/etc/systemd/system/setup-remote-desktop.service" > /dev/null << 'EOF'
[Unit]
Description=Setup Remote Desktop Services for Bookworm
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-remote-desktop.sh
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
        
        # Enable the service
        sudo mkdir -p "$root_mount_dir/etc/systemd/system/multi-user.target.wants"
        sudo ln -sf "/etc/systemd/system/setup-remote-desktop.service" "$root_mount_dir/etc/systemd/system/multi-user.target.wants/"
        
        # Set environment variables
        echo "ENABLE_VNC=$ENABLE_VNC" | sudo tee "$root_mount_dir/etc/environment" > /dev/null
        echo "ENABLE_RDP=$ENABLE_RDP" | sudo tee -a "$root_mount_dir/etc/environment" > /dev/null
    fi

    sudo umount "$root_mount_dir"
    sudo losetup -d "$root_loop_device"

    log "Remote access configured for Bookworm ARMv7 ✓"
}

# Resize image
resize_image() {
    log "Resizing Bookworm ARMv7 image..."

    local current_size=$(stat -c%s "$RPI_IMAGE")
    local target_size="8G"
    local target_bytes=8589934592  # 8 * 1000^3
    
    if [ $current_size -gt $target_bytes ]; then
        log "Image already resized to $target_size, skipping"
        return 0
    fi

    log "Resizing to $target_size..."
    if ! qemu-img resize -f raw "$RPI_IMAGE" "$target_size"; then
        error "Failed to resize image to $target_size"
        return 1
    fi
    
    log "Image resized to $target_size for Bookworm ✓"
}

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

# CORRECTED: Start QEMU with consistent ARMv7 configuration
start_qemu() {
    log "Starting QEMU Raspberry Pi Bookworm ARMv7 emulation..."
    log "Using machine type: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage interface: $STORAGE_INTERFACE, root device: $ROOT_DEVICE"
    
    # CORRECTED: Use qemu-system-arm consistently
    local qemu_cmd="qemu-system-arm"
    local qemu_args=(
        "-machine" "$MACHINE_TYPE"
        "-cpu" "$CPU_TYPE"
        "-m" "$MEMORY"
        "-smp" "4"
    )

    # Add storage
    if [[ "$STORAGE_INTERFACE" == "sd" ]] && [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=sd,index=0")
        log "Using SD card interface for Pi machine"
    else
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        log "Using virtio interface for virt machine"
    fi

    # Configure boot
    if [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
            qemu_args+=("-kernel" "$KERNEL_FILE")
            
            # CORRECTED: Kernel command line for ARMv7 Pi machines
            local cmdline="rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=$ROOT_DEVICE rootdelay=1"
            qemu_args+=("-append" "$cmdline")
            log "Using ARMv7 Pi machine kernel command line"
        fi

        if [ -n "$DTB_FILE" ] && [ -f "$DTB_FILE" ]; then
            qemu_args+=("-dtb" "$DTB_FILE")
            log "Using DTB: $DTB_FILE"
        else
            warning "DTB file missing - may affect Pi machine boot"
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
    qemu_args+=("-device" "usb-net,netdev=net0")

    # Display configuration
    if [ "$HEADLESS" = true ]; then
        qemu_args+=("-nographic")
        log "Running in headless mode (nographic)"
    fi
    
    # Show connection info
    echo
    log "Connection Information for Bookworm ARMv7:"
    echo "  SSH: ssh -p $SSH_PORT pi@localhost"
    echo "  Password: $RPI_PASSWORD"
    
    if [ "$ENABLE_VNC" = true ]; then
        echo "  VNC: localhost:$VNC_PORT (password: raspberry)"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        echo "  RDP: localhost:$RDP_PORT (user: pi, password: raspberry)"
    fi
    
    if [ "$ENABLE_WAYVNC" = true ]; then
        echo "  WayVNC: localhost:$WAYVNC_PORT"
    fi
    
    echo
    warning "Machine: $MACHINE_TYPE ($CPU_TYPE with $MEMORY RAM)"
    warning "Kernel: $KERNEL_FILE (ARMv7 compatible)"
    warning "Storage: $STORAGE_INTERFACE interface, root: $ROOT_DEVICE"
    
    echo
    warning "Boot Process:"
    echo "  - First boot may take 5-10 minutes for Bookworm setup"
    echo "  - ARMv7 architecture ensures compatibility"
    echo "  - Wait for login prompt before SSH connection"
    echo "  - System will auto-configure desktop services if enabled"
    
    echo
    warning "QEMU Controls:"
    echo "  Ctrl+A, X: Exit emulation"
    echo "  Ctrl+A, C: Switch to QEMU monitor"
    echo "  Ctrl+C: Force stop"
    echo
    
    log "Starting Bookworm ARMv7 emulation..."
    echo "QEMU Command: $qemu_cmd ${qemu_args[*]}"
    echo
    
    log "Starting [$DISTRO] emulation..."
    "$qemu_cmd" "${qemu_args[@]}" &
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
    echo "  QEMU Raspberry Pi - [$DISTRO] ARMv7"
    echo "==============================================="
    echo -e "${NC}"

    auto_cleanup_dead_instances
    
    check_dependencies
    download_image
    extract_boot_files
    setup_remote_access
    resize_image

    echo
    log "Setup complete! Starting [$DISTRO] ARMv7 emulation..."
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
    echo "Raspberry Pi OS Bookworm ARMv7 Full Desktop Emulator (CORRECTED)"
    echo "This version uses consistent ARMv7 architecture throughout."
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: auto-allocated)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi-bookworm)"
    echo "  --vnc [PORT]      Enable RealVNC server (default: auto-allocated)"
    echo "  --wayvnc [PORT]   Enable WayVNC for Wayland (default: auto-allocated)"
    echo "  --rdp [PORT]      Enable RDP server (default: auto-allocated)"
    echo "  --headless        Run without display (headless mode)"
    echo "  --force-virt      Force use of generic ARMv7 virt machine"
    echo
    echo "CORRECTED Features:"
    echo "  - Consistent ARMv7 32-bit architecture"
    echo "  - Proper kernel selection (kernel7l.img or kernel7.img)"
    echo "  - Compatible machine types (raspi3b/raspi2b, not raspi4b)"
    echo "  - Uses qemu-system-arm throughout"
    echo "  - Appropriate DTB files for selected machines"
    echo
    echo "Examples:"
    echo "  $0                               # Auto-detect best ARMv7 machine"
    echo "  $0 --force-virt                  # Use generic ARMv7 virt machine"
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
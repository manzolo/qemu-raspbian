#!/bin/bash

# Script to emulate Raspberry Pi OS Buster (2020) with QEMU - CORRECTED VERSION
# Fixed architecture consistency for stable ARMv7 emulation

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables for Buster 2020
RPI_IMAGE_URL="http://downloads.raspberrypi.org/raspbian/images/raspbian-2020-02-14/2020-02-13-raspbian-buster.zip"
RPI_IMAGE_ZIP="2020-02-13-raspbian-buster.zip"
RPI_IMAGE="2020-02-13-raspbian-buster.img"
DISTRO="Buster"
DISTRO_LOWER=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/buster"
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

# CORRECTED: Detect appropriate ARMv7 machine types
detect_machine_type() {
    log "Detecting available QEMU ARMv7 machine types for Buster..."
    
    # Get list of available ARM machines
    local available_machines=$(qemu-system-arm -machine help)
    
    log "Available ARMv7 machines:"
    echo "$available_machines" | grep -E "(raspi|virt)" | head -5
    
    # Select appropriate ARMv7 machines
    if echo "$available_machines" | grep -q "raspi3b"; then
        MACHINE_TYPE="raspi3b" 
        CPU_TYPE="cortex-a53"
        MEMORY="1G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
        log "Using Raspberry Pi 3B machine type (optimal for Buster)"
    elif echo "$available_machines" | grep -q "raspi2b"; then
        MACHINE_TYPE="raspi2b"
        CPU_TYPE="cortex-a15"
        MEMORY="1G"
        STORAGE_INTERFACE="sd"
        ROOT_DEVICE="/dev/mmcblk0p2"
        DTB_FILE="bcm2709-rpi-2-b.dtb"
        log "Using Raspberry Pi 2B machine type"
    elif [ "$FORCE_VIRT" = true ]; then
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a15"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_FILE=""
        warning "Forcing use of generic ARMv7 virt machine"
    else
        MACHINE_TYPE="virt"
        CPU_TYPE="cortex-a15"
        MEMORY="2G"
        STORAGE_INTERFACE="virtio"
        ROOT_DEVICE="/dev/vda2"
        DTB_FILE=""
        warning "No Pi-specific machines found, using generic ARMv7 virt machine"
    fi
    
    log "Selected machine: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage: $STORAGE_INTERFACE interface, root device: $ROOT_DEVICE"
}

# CORRECTED: Check dependencies for ARMv7 only
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS Buster ARMv7..."

    local deps=("qemu-system-arm" "wget" "unzip" "fdisk" "openssl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt-get install -y qemu-system-arm wget unzip fdisk openssl"
        exit 1
    fi

    log "All dependencies are present ✓"
    detect_machine_type
}

# Download the Raspberry Pi OS Buster image
download_image() {
    log "Preparing working directory for Buster..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Buster image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_ZIP" ]; then
        log "Downloading Raspberry Pi OS Buster image (approx. 1.1GB)..."
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Extracting the image..."
    unzip -o "$RPI_IMAGE_ZIP"
}

# CORRECTED: Extract boot files for consistent ARMv7 setup
extract_boot_files() {
    log "Extracting kernel and device tree for Buster ARMv7..."

    # Check for existing extracted files
    if [ -f "kernel7.img" ] || [ -f "kernel-qemu-4.14.79-stretch" ]; then
        log "Boot files already extracted, using existing files"
        
        if [ -f "kernel7.img" ]; then
            KERNEL_FILE="kernel7.img"
            log "Using extracted kernel7.img from Buster image"
        elif [ -f "kernel-qemu-4.14.79-stretch" ]; then
            KERNEL_FILE="kernel-qemu-4.14.79-stretch"
            log "Using external QEMU kernel for compatibility"
        fi
        
        # Set DTB based on machine type
        case "$MACHINE_TYPE" in
            "raspi3b")
                if [ -f "bcm2710-rpi-3-b-plus.dtb" ]; then
                    DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
                elif [ -f "versatile-pb.dtb" ]; then
                    DTB_FILE="versatile-pb.dtb"
                fi
                ;;
            "raspi2b")
                if [ -f "bcm2709-rpi-2-b.dtb" ]; then
                    DTB_FILE="bcm2709-rpi-2-b.dtb"
                elif [ -f "versatile-pb.dtb" ]; then
                    DTB_FILE="versatile-pb.dtb"
                fi
                ;;
            *)
                DTB_FILE=""
                ;;
        esac
        
        return 0
    fi

    # Try to extract from image first
    local extracted_kernel=false
    local boot_offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')
    
    if [ -n "$boot_offset" ]; then
        log "Attempting to extract kernel from Buster image..."
        
        local mount_dir="/tmp/rpi_boot_extract_$$"
        sudo mkdir -p "$mount_dir"
        
        if sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$mount_dir" 2>/dev/null; then
            # Extract ARMv7 kernel
            if [ -f "$mount_dir/kernel7.img" ]; then
                cp "$mount_dir/kernel7.img" .
                KERNEL_FILE="kernel7.img"
                extracted_kernel=true
                log "Extracted kernel7.img from Buster image"
            fi
            
            # Extract appropriate DTB files
            case "$MACHINE_TYPE" in
                "raspi3b")
                    if [ -f "$mount_dir/bcm2710-rpi-3-b-plus.dtb" ]; then
                        cp "$mount_dir/bcm2710-rpi-3-b-plus.dtb" .
                        DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
                        log "Extracted Pi 3B+ DTB from Buster image"
                    elif [ -f "$mount_dir/bcm2710-rpi-3-b.dtb" ]; then
                        cp "$mount_dir/bcm2710-rpi-3-b.dtb" .
                        DTB_FILE="bcm2710-rpi-3-b.dtb"
                        log "Extracted Pi 3B DTB from Buster image"
                    fi
                    ;;
                "raspi2b")
                    if [ -f "$mount_dir/bcm2709-rpi-2-b.dtb" ]; then
                        cp "$mount_dir/bcm2709-rpi-2-b.dtb" .
                        DTB_FILE="bcm2709-rpi-2-b.dtb"
                        log "Extracted Pi 2B DTB from Buster image"
                    fi
                    ;;
            esac
            
            sudo umount "$mount_dir"
        fi
        
        sudo rmdir "$mount_dir" 2>/dev/null || true
    fi
    
    # Fallback to external kernel if extraction failed
    if [ "$extracted_kernel" = false ]; then
        log "Falling back to external QEMU kernel for compatibility..."
        
        # Download external kernel and DTB for better compatibility
        if [ ! -f "kernel-qemu-4.14.79-stretch" ]; then
            log "Downloading QEMU kernel for Buster (Stretch kernel for compatibility)..."
            wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.14.79-stretch
        fi
        
        if [ ! -f "versatile-pb.dtb" ]; then
            log "Downloading device tree blob (compatible with Buster)..."
            wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/versatile-pb.dtb
        fi
        
        KERNEL_FILE="kernel-qemu-4.14.79-stretch"
        DTB_FILE="versatile-pb.dtb"
        log "Using external kernel and DTB for maximum compatibility"
    fi

    log "Boot files prepared successfully ✓"
}

# Configure SSH and services for Buster
setup_remote_access() {
    log "Configuring remote access for Buster ARMv7..."

    # Find the offset of the boot partition
    local boot_offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')

    if [ -z "$boot_offset" ]; then
        error "Could not find the boot partition"
        exit 1
    fi

    # Create a temporary mount directory
    local boot_mount_dir="/tmp/rpi_boot_$$"
    sudo mkdir -p "$boot_mount_dir"

    # Mount the boot partition
    sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$boot_mount_dir"

    # Enable SSH (required for Buster)
    sudo touch "$boot_mount_dir/ssh"

    # Configure user credentials for Buster
    log "Configuring user credentials for Buster..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf.txt" > /dev/null

    # Configure display settings for Buster
    log "Configuring display settings for Buster..."
    if [ -f "$boot_mount_dir/config.txt" ]; then
        sudo cp "$boot_mount_dir/config.txt" "$boot_mount_dir/config.txt.backup"
    fi
    
    echo "" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "# Display Configuration for Buster ARMv7" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"

    # Configure VNC for Buster (improved VNC support)
    if [ "$ENABLE_VNC" = true ]; then
        log "Configuring VNC for Buster..."
        echo "# VNC Configuration for Buster" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=vc4-fkms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
    fi

    sudo umount "$boot_mount_dir"
    sudo rmdir "$boot_mount_dir"

    # Configure desktop services if needed
    if [ "$ENABLE_RDP" = true ] || [ "$ENABLE_VNC" = true ]; then
        setup_desktop_services
        
        # NEW: Also setup first boot script for better initialization
        local root_offset=$(fdisk -l "$RPI_IMAGE" | awk '/Linux/ {print $2 * 512}')
        if [ -n "$root_offset" ]; then
            local root_mount_dir="/tmp/rpi_root_$$"
            sudo mkdir -p "$root_mount_dir"
            sudo mount -o loop,offset="$root_offset" "$RPI_IMAGE" "$root_mount_dir"
            
            # Call the function from port_management.sh
            setup_first_boot_script "$root_mount_dir" "buster"
            
            sudo umount "$root_mount_dir"
            sudo rmdir "$root_mount_dir"
        fi
    fi

    log "Remote access configured for Buster ✓"
}

# Setup desktop services for Buster
setup_desktop_services() {
    log "Setting up desktop services for Buster..."

    local root_offset=$(fdisk -l "$RPI_IMAGE" | awk '/Linux/ {print $2 * 512}')

    if [ -z "$root_offset" ]; then
        error "Could not find the root partition"
        return 1
    fi

    local root_mount_dir="/tmp/rpi_root_$$"
    sudo mkdir -p "$root_mount_dir"
    sudo mount -o loop,offset="$root_offset" "$RPI_IMAGE" "$root_mount_dir"

    # Abilita SSH
    sudo ln -sf /lib/systemd/system/ssh.service \
        "$root_mount_dir/etc/systemd/system/multi-user.target.wants/ssh.service"

    # Abilita VNC (se RealVNC è installato nell’immagine Jessie)
    sudo ln -sf /lib/systemd/system/vncserver-x11-serviced.service \
        "$root_mount_dir/etc/systemd/system/multi-user.target.wants/vncserver-x11-serviced.service"

    # Create setup script for desktop services
    sudo tee "$root_mount_dir/home/pi/setup_desktop_buster.sh" > /dev/null << 'EOF'
#!/bin/bash
# Setup script for Buster desktop services (ARMv7)

log_msg() {
    echo "[BUSTER-DESKTOP] $1" | tee -a /var/log/buster-desktop-setup.log
}

log_msg "Starting desktop services setup for Buster ARMv7..."

# Enable RDP if requested
if [ "$1" = "rdp" ] || [ "$1" = "both" ]; then
    log_msg "Setting up RDP for Buster..."
    apt-get install -y xrdp
    
    # Configure xrdp for Buster LXDE
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
if test -r /etc/profile; then . /etc/profile; fi
if test -r /etc/default/locale; then . /etc/default/locale; fi

# Start LXDE desktop for Pi OS Buster
exec /usr/bin/startlxde-pi
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    
    # Add pi user to ssl-cert group
    usermod -a -G ssl-cert pi
    
    # Optimize xrdp settings
    sed -i 's/max_bpp=32/max_bpp=16/g' /etc/xrdp/xrdp.ini
    sed -i 's/#tcp_nodelay=1/tcp_nodelay=1/g' /etc/xrdp/xrdp.ini
    
    systemctl enable xrdp
    systemctl start xrdp
    
    log_msg "RDP configured on port 3389"
fi

log_msg "Desktop services setup complete for Buster!"
EOF

    sudo chmod +x "$root_mount_dir/home/pi/setup_desktop_buster.sh"
    sudo chown 1000:1000 "$root_mount_dir/home/pi/setup_desktop_buster.sh" 2>/dev/null || true

    sudo umount "$root_mount_dir"
    sudo rmdir "$root_mount_dir"
}

# Resize the image
resize_image() {
    log "Resizing Buster image..."

    local current_size=$(stat -c%s "$RPI_IMAGE")
    local target_size="8G"
    local target_bytes=8589934592  # 6 * 1000^3
    
    if [ $current_size -gt $target_bytes ]; then
        log "Image already resized to $target_size, skipping"
        return 0
    fi

    qemu-img resize -f raw "$RPI_IMAGE" "$target_size"
    log "Image resized to $target_size ✓"
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
    log "Starting QEMU Raspberry Pi Buster ARMv7 emulation..."
    log "Using machine type: $MACHINE_TYPE with $CPU_TYPE CPU and $MEMORY RAM"
    log "Storage interface: $STORAGE_INTERFACE, root device: $ROOT_DEVICE"
    
    # CORRECTED: Use qemu-system-arm consistently for ARMv7
    local qemu_cmd="qemu-system-arm"
    
    # Build QEMU arguments for ARMv7 Buster
    local qemu_args=(
        "-machine" "$MACHINE_TYPE"
        "-cpu" "$CPU_TYPE"
        "-m" "$MEMORY"
        "-smp" "4"
    )
    
    # Add storage based on interface
    if [[ "$STORAGE_INTERFACE" == "sd" ]] && [[ "$MACHINE_TYPE" == "raspi"* ]]; then
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=sd,index=0")
        log "Using SD card interface for Pi machine"
    else
        qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=virtio")
        log "Using virtio interface for virt machine"
        
        # Update fstab for virtio if needed (simple approach)
        if [[ "$ROOT_DEVICE" == "/dev/vda2" ]]; then
            log "Note: System will auto-adapt fstab for virtio devices on first boot"
        fi
    fi

    # Configure boot with appropriate kernel
    if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
        qemu_args+=("-kernel" "$KERNEL_FILE")
        
        # CORRECTED: Kernel command line for ARMv7
        local cmdline="root=$ROOT_DEVICE rw console=ttyAMA0,115200 rootfstype=ext4 rootdelay=1"
        
        # Add specific options based on kernel type
        if [[ "$KERNEL_FILE" == "kernel7.img" ]]; then
            # Native Pi kernel
            cmdline="rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=$ROOT_DEVICE rootdelay=1"
        fi
        
        qemu_args+=("-append" "$cmdline")
        log "Using ARMv7 kernel: $KERNEL_FILE"
    fi

    # Add DTB if available and needed
    if [ -n "$DTB_FILE" ] && [ -f "$DTB_FILE" ]; then
        qemu_args+=("-dtb" "$DTB_FILE")
        log "Using DTB: $DTB_FILE"
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
    log "Connection Information for Buster ARMv7:"
    echo "  SSH: ssh -p $SSH_PORT pi@localhost"
    echo "  Password: $RPI_PASSWORD"
    
    if [ "$ENABLE_VNC" = true ]; then
        echo "  VNC: localhost:$VNC_PORT (password: raspberry)"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        echo "  RDP: localhost:$RDP_PORT (username: pi, password: raspberry)"
    fi
    
    if [ "$ENABLE_WAYVNC" = true ]; then
        echo "  WayVNC: localhost:$WAYVNC_PORT"
    fi
    
    echo
    warning "Machine: $MACHINE_TYPE ($CPU_TYPE with $MEMORY RAM)"
    warning "Kernel: $KERNEL_FILE (ARMv7 compatible)"
    warning "Storage: $STORAGE_INTERFACE interface, root: $ROOT_DEVICE"
    
    echo
    warning "After first boot, run inside the Pi:"
    if [ "$ENABLE_VNC" = true ] && [ "$ENABLE_RDP" = true ]; then
        echo "  ./setup_desktop_buster.sh both"
    elif [ "$ENABLE_VNC" = true ]; then
        echo "  ./setup_desktop_buster.sh vnc"
    elif [ "$ENABLE_RDP" = true ]; then
        echo "  ./setup_desktop_buster.sh rdp"
    fi
    
    echo
    warning "Buster Features:"
    echo "  - RealVNC server built-in"
    echo "  - Python 3.7 default"
    echo "  - ARMv7 32-bit architecture"
    echo "  - Improved stability over earlier versions"
    
    echo
    warning "QEMU Controls:"
    echo "  Ctrl+A, X: Exit emulation"
    echo "  Ctrl+A, C: Switch to QEMU monitor"
    echo "  Ctrl+C: Force stop"
    echo
    
    log "Starting Buster ARMv7 emulation..."
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
            if [ "$OWNER_PID" = "$$" ] || [ "$need_allocation" = "true" ]; then
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
    echo "Raspberry Pi OS Buster ARMv7 Emulator (CORRECTED)"
    echo "This version uses consistent ARMv7 architecture throughout."
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: auto-allocated)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi-buster)"
    echo "  --vnc [PORT]      Enable RealVNC server (default: auto-allocated)"
    echo "  --rdp [PORT]      Enable RDP server (default: auto-allocated)"
    echo "  --wayvnc [PORT]   Enable WayVNC server (default: auto-allocated)"
    echo "  --headless        Run without display (headless mode)"
    echo "  --force-virt      Force use of generic ARMv7 virt machine"
    echo
    echo "CORRECTED Features:"
    echo "  - Consistent ARMv7 32-bit architecture"
    echo "  - Uses qemu-system-arm (not aarch64)"
    echo "  - Compatible machine types (raspi3b/raspi2b)"
    echo "  - Proper kernel selection (kernel7.img or external kernel)"
    echo "  - RealVNC server built-in support"
    echo "  - Python 3.7 default"
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
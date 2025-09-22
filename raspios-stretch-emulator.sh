#!/bin/bash

# Script to emulate Raspberry Pi OS Stretch (2018) with QEMU
# Optimized for Raspbian Stretch distribution

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables for Stretch 2018
RPI_IMAGE_URL="http://downloads.raspberrypi.org/raspbian/images/raspbian-2018-11-15/2018-11-13-raspbian-stretch.zip"
RPI_IMAGE_ZIP="2018-11-13-raspbian-stretch.zip"
RPI_IMAGE="2018-11-13-raspbian-stretch.img"
DISTRO="Stretch"
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/stretch"
SSH_PORT="auto"
VNC_PORT="auto"
RDP_PORT="auto"
WAYVNC_PORT="auto"
ENABLE_VNC=false
ENABLE_RDP=false
ENABLE_WAYVNC=false
HEADLESS=false
INSTANCE_ID=""
# Check if necessary tools are installed
check_dependencies() {
    log "Checking dependencies for Raspbian Stretch..."

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
}

# Download the Raspberry Pi OS Stretch image
download_image() {
    log "Preparing working directory for Stretch..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Stretch image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_ZIP" ]; then
        log "Downloading Raspberry Pi OS Stretch image (approx. 1.7GB)..."
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Extracting the image..."
    unzip -o "$RPI_IMAGE_ZIP"
}

# Extract kernel and device tree from the image (Stretch specific)
extract_boot_files() {
    log "Extracting kernel and device tree for Stretch..."

    # Stretch uses the same kernel files as other versions
    if [ -f "kernel-qemu-4.14.79-stretch" ] && [ -f "versatile-pb.dtb" ]; then
        log "Boot files already extracted, skipping"
        return 0
    fi

    # Download pre-compiled kernel for Stretch QEMU
    if [ ! -f "kernel-qemu-4.14.79-stretch" ]; then
        log "Downloading QEMU kernel for Stretch..."
        wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.14.79-stretch
    fi

    # Use the same DTB as other versions (compatible)
    if [ ! -f "versatile-pb.dtb" ]; then
        log "Downloading device tree blob (compatible with Stretch)..."
        wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/versatile-pb.dtb
    fi

    log "Boot files prepared successfully ✓"
}

# Configure SSH and basic services for Stretch
setup_remote_access() {
    log "Configuring remote access for Stretch..."

    # Find the offset of the boot partition
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')

    if [ -z "$offset" ]; then
        error "Could not find the boot partition"
        exit 1
    fi

    # Create a temporary mount directory
    local mount_dir="/tmp/rpi_boot_$$"
    sudo mkdir -p "$mount_dir"

    # Mount the boot partition
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Enable SSH (required for Stretch and later)
    sudo touch "$mount_dir/ssh"

    # Generate password hash for pi user
    log "Generating password hash for user 'pi'..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$mount_dir/userconf" > /dev/null

    # Configure display settings for Stretch
    log "Configuring display settings..."
    echo "" | sudo tee -a "$mount_dir/config.txt"
    echo "# Display Configuration for Stretch" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$mount_dir/config.txt"
    echo "gpu_mem=64" | sudo tee -a "$mount_dir/config.txt"

    # Configure VNC if enabled
    if [ "$ENABLE_VNC" = true ]; then
        log "Configuring VNC for Stretch..."
        echo "# VNC Configuration" | sudo tee -a "$mount_dir/config.txt"
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$mount_dir/config.txt"
    fi

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"

    # Configure desktop services in the root filesystem if needed
    if [ "$ENABLE_RDP" = true ] || [ "$ENABLE_VNC" = true ]; then
        setup_desktop_services
    fi

    log "Remote access configured for Stretch ✓"
}

# Setup desktop services for Stretch
setup_desktop_services() {
    log "Setting up desktop services for Stretch..."

    # Find the offset of the root partition
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/Linux/ {print $2 * 512}')

    if [ -z "$offset" ]; then
        error "Could not find the root partition"
        return 1
    fi

    # Create a temporary mount directory
    local mount_dir="/tmp/rpi_root_$$"
    sudo mkdir -p "$mount_dir"

    # Mount the root partition
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Create init script for desktop services (Stretch specific)
    cat << 'EOF' | sudo tee "$mount_dir/home/pi/setup_desktop_stretch.sh" > /dev/null
#!/bin/bash

# Setup script for Stretch desktop services

# Enable VNC if requested
if [ "$1" = "vnc" ] || [ "$1" = "both" ]; then
    echo "Setting up VNC for Stretch..."
    
    # Enable VNC server (Stretch has built-in VNC)
    sudo raspi-config nonint do_vnc 0
    
    # Configure VNC password
    echo -n "raspberry" | sudo tee /root/.vncpasswd > /dev/null
    
    # Start VNC server
    sudo systemctl enable vncserver-x11-serviced.service
    sudo systemctl start vncserver-x11-serviced.service
fi

# Enable RDP if requested
if [ "$1" = "rdp" ] || [ "$1" = "both" ]; then
    echo "Setting up RDP for Stretch..."
    sudo apt-get update -qq
    sudo apt-get install -y xrdp
    sudo systemctl enable xrdp
    sudo systemctl start xrdp
    
    # Configure xrdp for Stretch
    echo "lxsession -s LXDE-pi -e LXDE" > ~/.xsession
    sudo sed -i 's/port=3389/port=3389/g' /etc/xrdp/xrdp.ini
fi

echo "Desktop services setup complete for Stretch!"
EOF

    sudo chmod +x "$mount_dir/home/pi/setup_desktop_stretch.sh"
    sudo chown 1000:1000 "$mount_dir/home/pi/setup_desktop_stretch.sh" 2>/dev/null || true

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"
}

# Resize the image
resize_image() {
    log "Resizing Stretch image..."

    # Check if the image has already been resized
    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 6000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi

    qemu-img resize -f raw "$RPI_IMAGE" 6G
    log "Image resized to 6GB ✓"
}

# Start QEMU for Stretch
start_qemu() {
    log "Starting QEMU Raspberry Pi 3 emulation for Stretch..."
    
    # Build QEMU command for Stretch
    local qemu_cmd="qemu-system-arm"

    # Network configuration
    local netdev_options="user,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5901"
        log "VNC will be available on port $VNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        netdev_options+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "VNC will be available on port $RDP_PORT"
    fi
    
    # Build basic arguments
    local qemu_args=(
        "-kernel" "kernel-qemu-4.14.79-stretch"
        "-cpu" "arm1176"
        "-m" "256"
        "-M" "versatilepb"
        "-dtb" "versatile-pb.dtb"
        "-serial" "stdio"
        "-append" "root=/dev/sda2 rootfstype=ext4 rw"
        "-drive" "format=raw,file=$RPI_IMAGE"
        "-nic" "$netdev_options"
        "-no-reboot"
    )
    
    # Display configuration
    if [ "$HEADLESS" = true ]; then
        qemu_args+=("-nographic")
        log "Running in headless mode"
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
        echo "  RDP: localhost:$RDP_PORT (username: pi, password: raspberry)"
    fi
    
    echo
    warning "After first boot, run the following inside the Pi to set up desktop services:"
    
    if [ "$ENABLE_VNC" = true ] && [ "$ENABLE_RDP" = true ]; then
        echo "  ./setup_desktop_stretch.sh both"
    elif [ "$ENABLE_VNC" = true ]; then
        echo "  ./setup_desktop_stretch.sh vnc"
    elif [ "$ENABLE_RDP" = true ]; then
        echo "  ./setup_desktop_stretch.sh rdp"
    fi
    
    echo
    warning "Stretch Notes:"
    echo "  - SSH requires explicit enabling via 'ssh' file"
    echo "  - Built-in VNC server available"
    echo "  - Improved hardware support"
    echo "  - Uses ARM1176 CPU with 512MB RAM"
    echo "  - Fixed network and image format issues"
    echo
    warning "QEMU Controls:"
    echo "  Ctrl+A, X: Exit emulation"
    echo "  Ctrl+A, C: Switch to QEMU monitor"
    echo
    
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
    echo "  -h, --help      Show this help message"
    echo "  -p PORT         Set SSH port (default: 2222)"
    echo "  -d DIR          Set working directory (default: ~/qemu-rpi-stretch)"
    echo "  --vnc [PORT]    Enable VNC server (default port: 5900)"
    echo "  --rdp [PORT]    Enable RDP server (default port: 3389)"
    echo "  --headless      Run without display"
    echo
    echo "Stretch-specific features:"
    echo "  - Built-in VNC server support"
    echo "  - SSH requires explicit enabling"
    echo "  - ARM1176 CPU with 512MB RAM"
    echo "  - Improved display support"
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

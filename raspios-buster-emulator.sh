#!/bin/bash

# Script to emulate Raspberry Pi OS Buster (2020) with QEMU
# Optimized for Raspbian Buster distribution

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

# Check if necessary tools are installed
check_dependencies() {
    log "Checking dependencies for Raspbian Buster..."

    local deps=("qemu-system-arm" "qemu-system-aarch64" "wget" "unzip" "fdisk" "openssl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt-get install -y qemu-system-arm qemu-system-aarch64 wget unzip fdisk openssl"
        exit 1
    fi

    log "All dependencies are present ✓"
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

# Extract kernel and device tree from the image (Buster specific)
extract_boot_files() {
    log "Extracting kernel and device tree for Buster..."

    # Try to extract from image first (modern approach)
    local extracted_kernel=false
    
    # Find the offset of the boot partition to extract kernel
    local boot_offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')
    
    if [ -n "$boot_offset" ]; then
        log "Attempting to extract kernel from Buster image..."
        
        # Create temporary mount directory
        local mount_dir="/tmp/rpi_boot_extract_$"
        sudo mkdir -p "$mount_dir"
        
        # Mount and extract
        if sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$mount_dir" 2>/dev/null; then
            # Copy kernel files if they exist
            if [ -f "$mount_dir/kernel7.img" ]; then
                cp "$mount_dir/kernel7.img" .
                extracted_kernel=true
                log "Extracted kernel7.img from Buster image"
            fi
            
            # Copy DTB files
            if [ -f "$mount_dir/bcm2710-rpi-3-b-plus.dtb" ]; then
                cp "$mount_dir/bcm2710-rpi-3-b-plus.dtb" .
                log "Extracted DTB from Buster image"
            elif [ -f "$mount_dir/bcm2711-rpi-4-b.dtb" ]; then
                cp "$mount_dir/bcm2711-rpi-4-b.dtb" .
                log "Extracted Pi4 DTB from Buster image"
            fi
            
            sudo umount "$mount_dir"
        fi
        
        sudo rmdir "$mount_dir" 2>/dev/null || true
    fi
    
    # Fallback to external kernel if extraction failed
    if [ "$extracted_kernel" = false ]; then
        log "Falling back to external kernel for compatibility..."
        
        # Use same DTB as other versions (compatible)
        if [ ! -f "versatile-pb.dtb" ]; then
            log "Downloading device tree blob (compatible with Buster)..."
            wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/versatile-pb.dtb
        fi

        # Download pre-compiled kernel for Buster QEMU - use Stretch kernel (more stable)
        if [ ! -f "kernel-qemu-4.14.79-stretch" ]; then
            log "Downloading QEMU kernel for Buster (using Stretch kernel for compatibility)..."
            wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.14.79-stretch
        fi
    fi

    log "Boot files prepared successfully ✓"
}

# Configure SSH and services for Buster
setup_remote_access() {
    log "Configuring remote access for Buster..."

    # Find the offset of the boot partition
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2 * 512}')

    if [ -z "$offset" ]; then
        error "Could not find the boot partition"
        exit 1
    fi

    # Create a temporary mount directory
    local mount_dir="/tmp/rpi_boot_$"
    sudo mkdir -p "$mount_dir"

    # Mount the boot partition
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Enable SSH (required for Buster)
    sudo touch "$mount_dir/ssh"

    # Generate password hash for pi user (Buster specific)
    log "Generating password hash for user 'pi'..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$mount_dir/userconf" > /dev/null

    # Configure display settings for Buster
    log "Configuring display settings..."
    echo "" | sudo tee -a "$mount_dir/config.txt"
    echo "# Display Configuration for Buster" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$mount_dir/config.txt"
    echo "gpu_mem=128" | sudo tee -a "$mount_dir/config.txt"

    # Configure VNC if enabled (Buster has improved VNC)
    if [ "$ENABLE_VNC" = true ]; then
        log "Configuring VNC for Buster..."
        echo "# VNC Configuration" | sudo tee -a "$mount_dir/config.txt"
        echo "dtoverlay=vc4-fkms-v3d" | sudo tee -a "$mount_dir/config.txt"
        echo "gpu_mem=128" | sudo tee -a "$mount_dir/config.txt"
    fi

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"

    # Configure desktop services in the root filesystem if needed
    if [ "$ENABLE_RDP" = true ] || [ "$ENABLE_VNC" = true ]; then
        setup_desktop_services
    fi

    log "Remote access configured for Buster ✓"
}

# Setup desktop services for Buster
setup_desktop_services() {
    log "Setting up desktop services for Buster..."

    # Find the offset of the root partition
    local offset=$(fdisk -l "$RPI_IMAGE" | awk '/Linux/ {print $2 * 512}')

    if [ -z "$offset" ]; then
        error "Could not find the root partition"
        return 1
    fi

    # Create a temporary mount directory
    local mount_dir="/tmp/rpi_root_$"
    sudo mkdir -p "$mount_dir"

    # Mount the root partition
    sudo mount -o loop,offset="$offset" "$RPI_IMAGE" "$mount_dir"

    # Create init script for desktop services (Buster specific)
    cat << 'EOF' | sudo tee "$mount_dir/home/pi/setup_desktop_buster.sh" > /dev/null
#!/bin/bash

# Setup script for Buster desktop services

# Enable VNC if requested
if [ "$1" = "vnc" ] || [ "$1" = "both" ]; then
    echo "Setting up VNC for Buster..."
    
    # Enable VNC server (Buster has RealVNC)
    sudo raspi-config nonint do_vnc 0
    
    # Configure VNC service
    sudo systemctl enable vncserver-x11-serviced.service
    sudo systemctl start vncserver-x11-serviced.service
    
    # Set VNC password
    sudo vncpasswd -service <<< raspberry\nraspberry\nn'
fi

# Enable RDP if requested
if [ "$1" = "rdp" ] || [ "$1" = "both" ]; then
    echo "Setting up RDP for Buster..."
    sudo apt-get update -qq
    sudo apt-get install -y xrdp
    sudo systemctl enable xrdp
    sudo systemctl start xrdp
    
    # Configure xrdp for Buster LXDE
    echo "startlxde-pi" > ~/.xsession
    sudo adduser xrdp ssl-cert
    
    # Configure xrdp.ini
    sudo sed -i 's/max_bpp=32/max_bpp=128/g' /etc/xrdp/xrdp.ini
    sudo sed -i 's/xserverbpp=24/xserverbpp=128/g' /etc/xrdp/xrdp.ini
fi

echo "Desktop services setup complete for Buster!"
EOF

    sudo chmod +x "$mount_dir/home/pi/setup_desktop_buster.sh"
    sudo chown 1000:1000 "$mount_dir/home/pi/setup_desktop_buster.sh" 2>/dev/null || true

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"
}

# Resize the image
resize_image() {
    log "Resizing Buster image..."

    # Check if the image has already been resized
    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 6000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi

    qemu-img resize -f raw "$RPI_IMAGE" 8G
    log "Image resized to 8GB ✓"
}

# Start QEMU for Buster
start_qemu() {
    log "Starting QEMU Raspberry Pi 3B+ emulation for Buster..."
    
    # Build QEMU command for Buster
    #"-serial" "stdio"
    local qemu_cmd="qemu-system-aarch64"
    local qemu_args=(
        "-kernel" "kernel7.img"
        "-cpu" "cortex-a72"
        "-m" "1G"
        "-machine" "raspi3b" 
        "-dtb" "bcm2710-rpi-3-b-plus.dtb"
        "-sd" "$RPI_IMAGE"
        "-no-reboot"
        "-nographic"
        "-append" "rw console=ttyAMA0,115200 console=tty1 root=/dev/mmcblk0p2 rootdelay=1"
    )

    # Network configuration with port forwarding
    local netdev_options="user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5901"
        log "VNC will be available on port $VNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        netdev_options+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "RDP will be available on port $RDP_PORT"
    fi

    qemu_args+=("-netdev" "$netdev_options")
    qemu_args+=("-device" "usb-net,netdev=net0")

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
        echo "  ./setup_desktop_buster.sh both"
    elif [ "$ENABLE_VNC" = true ]; then
        echo "  ./setup_desktop_buster.sh vnc"
    elif [ "$ENABLE_RDP" = true ]; then
        echo "  ./setup_desktop_buster.sh rdp"
    fi
    
    echo
    warning "Buster Notes:"
    echo "  - RealVNC server built-in"
    echo "  - Improved performance and stability"
    echo "  - Better hardware acceleration support"
    echo "  - Uses ARM1176 CPU with 1GB RAM"
    echo "  - Python 3.7 default"
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
    echo "  -d DIR          Set working directory (default: ~/qemu-rpi-buster)"
    echo "  --vnc [PORT]    Enable VNC server (default port: 5900)"
    echo "  --rdp [PORT]    Enable RDP server (default port: 3389)"
    echo "  --headless      Run without display"
    echo
    echo "Buster-specific features:"
    echo "  - RealVNC server built-in"
    echo "  - Better performance and stability"
    echo "  - Python 3.7 as default"
    echo "  - ARM1176 CPU with 1GB RAM"
    echo "  - Improved hardware acceleration"
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

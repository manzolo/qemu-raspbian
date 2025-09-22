#!/bin/bash

# Script to emulate Raspberry Pi OS Jessie (2017) with QEMU
# Optimized for older Raspbian Jessie distribution

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables for Jessie 2017
RPI_IMAGE_URL="http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
RPI_IMAGE_ZIP="2017-04-10-raspbian-jessie.zip"
RPI_IMAGE="2017-04-10-raspbian-jessie.img"
DISTRO="Jessie"
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/jessie"
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
    log "Checking dependencies for Raspbian Jessie..."

    local deps=("qemu-system-arm" "wget" "unzip" "fdisk")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt-get install -y qemu-system-arm wget unzip fdisk"
        exit 1
    fi

    log "All dependencies are present ✓"
}

# Download the Raspberry Pi OS Jessie image
download_image() {
    log "Preparing working directory for Jessie..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Jessie image already present, skipping download"
        return 0
    fi

    if [ ! -f "$RPI_IMAGE_ZIP" ]; then
        log "Downloading Raspberry Pi OS Jessie image (approx. 1.4GB)..."
        wget -c "$RPI_IMAGE_URL"
    fi

    log "Extracting the image..."
    unzip -o "$RPI_IMAGE_ZIP"
}

# Extract kernel and device tree from the image (Jessie specific)
extract_boot_files() {
    log "Extracting kernel and device tree for Jessie..."

    # Jessie uses different kernel files
    if [ -f "kernel-qemu-4.4.34-jessie" ] && [ -f "versatile-pb.dtb" ]; then
        log "Boot files already extracted, skipping"
        return 0
    fi

    # Download pre-compiled kernel for Jessie QEMU
    if [ ! -f "kernel-qemu-4.4.34-jessie" ]; then
        log "Downloading QEMU kernel for Jessie..."
        wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.4.34-jessie
    fi

    if [ ! -f "versatile-pb.dtb" ]; then
        log "Downloading device tree blob..."
        wget -c https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/versatile-pb.dtb
    fi

    log "Boot files prepared successfully ✓"
}

# Configure SSH for Jessie (no SSH enabled by default)
setup_remote_access() {
    log "Configuring remote access for Jessie..."

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

    # Enable SSH (Jessie has SSH enabled by default, but we ensure it)
    sudo touch "$mount_dir/ssh"

    # Configure basic display settings
    log "Configuring display settings..."
    echo "" | sudo tee -a "$mount_dir/config.txt"
    echo "# Basic Display Configuration for Jessie" | sudo tee -a "$mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$mount_dir/config.txt"
    echo "gpu_mem=64" | sudo tee -a "$mount_dir/config.txt"

    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"

    log "Remote access configured for Jessie ✓"
}

# Resize the image
resize_image() {
    log "Resizing Jessie image..."

    # Check if the image has already been resized
    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 4000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi

    qemu-img resize "$RPI_IMAGE" 4G
    log "Image resized to 4GB ✓"
}

# Pre-mount filesystem (CRITICAL FOR JESSIE)
prepare_filesystem() {
    log "Preparing filesystem for Jessie (critical step)..."
    
    # Find the offset of the root partition (partition 2)
    local start_offset=$(fdisk -l "$RPI_IMAGE" | grep "${RPI_IMAGE}2" | awk '{print $2}')
    
    if [ -z "$start_offset" ]; then
        error "Could not find root partition in $RPI_IMAGE"
        exit 1
    fi
    
    local offset=$((start_offset * 512))
    log "Root partition offset: $offset"
    
    # Create mount directory
    local mount_dir="$WORK_DIR/jessie_root"
    mkdir -p "$mount_dir"
    
    # Unmount if already mounted
    sudo umount "$mount_dir" 2>/dev/null || true
    sleep 2
    
    # Mount the root partition
    log "Mounting root filesystem..."
    sudo mount -v -o offset=$offset -t ext4 "$RPI_IMAGE" "$mount_dir"
    
    # Store mount point for cleanup
    echo "$mount_dir" > "$WORK_DIR/.jessie_mount"
    
    log "Filesystem prepared and mounted at $mount_dir ✓"
}

# Start QEMU for Jessie (uses different machine type)
start_qemu() {
    log "Starting QEMU Raspberry Pi emulation for Jessie..."
    
    # Build QEMU command exactly like the working version
    local qemu_cmd="qemu-system-arm"
    
    # Network configuration
    local netdev_options="user,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5901"
        log "VNC will be available on port $VNC_PORT"
    fi
    
    local qemu_args=(
        "-kernel" "kernel-qemu-4.4.34-jessie"
        "-cpu" "arm1176"
        "-m" "256"
        "-M" "versatilepb"
        "-serial" "stdio"
        "-append" "root=/dev/sda2 rootfstype=ext4 rw"
        "-hda" "$RPI_IMAGE"
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
    echo "  Default password: $RPI_PASSWORD"
    echo
    warning "Jessie Notes:"
    echo "  - SSH is enabled by default in this version"
    echo "  - Default user: pi, password: raspberry"  
    echo "  - Filesystem has been pre-mounted (required for Jessie)"
    echo "  - Using exact parameters from working configuration"
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
    echo "  -d DIR          Set working directory (default: ~/qemu-rpi-jessie)"
    echo "  --vnc [PORT]    Enable VNC server (default port: 5900)"
    echo "  --headless      Run without display"
    echo
    echo "Jessie-specific notes:"
    echo "  - Uses ARM1176 CPU emulation"
    echo "  - Limited to 256MB RAM"
    echo "  - SSH enabled by default"
    echo "  - No GPU acceleration"
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

#!/bin/bash

# Script to emulate Raspberry Pi OS Buster using QEMU

set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi

source "$PORT_MGMT_SCRIPT"

# Configurable variables
RPI_IMAGE_URL="http://downloads.raspberrypi.org/raspbian/images/raspbian-2020-02-14/2020-02-13-raspbian-buster.zip"
RPI_IMAGE_ZIP="2020-02-13-raspbian-buster.zip"
RPI_IMAGE="2020-02-13-raspbian-buster.img"
KERNEL_URL="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/native-emulation/5.4.51%20kernels/kernel8.img"
DTB_URL="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/native-emulation/dtbs/bcm2710-rpi-3-b-plus.dtb"
KERNEL_FILE="kernel8.img"
DTB_FILE="bcm2710-rpi-3-b-plus.dtb"
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

MACHINE_TYPE="raspi3b"
CPU_TYPE="cortex-a72"
MEMORY="1G"
STORAGE_INTERFACE="sd"
ROOT_DEVICE="/dev/mmcblk0p2"

# Check dependencies
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS Buster..."

    # FIXED: Require qemu-system-arm for ARMv7 Buster
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
        echo "sudo apt-get install -y qemu-system-arm qemu-user-static wget unzip fdisk openssl"
        exit 1
    fi

    log "All dependencies for ARMv7 Buster are present ✓"
    log "Using NATIVE ARMv7 configuration: versatilepb with arm1176 CPU"
}

# Download Buster image - ORIGINAL ARMv7 VERSION
download_image() {
    log "Preparing working directory for Buster..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if [ -f "$RPI_IMAGE" ]; then
        log "Buster image already present, skipping download"
    else
        if [ ! -f "$RPI_IMAGE_ZIP" ]; then
            log "Downloading original Raspberry Pi OS Buster ARMv7 image (approx. 1.1GB)..."
            wget -c "$RPI_IMAGE_URL"
        fi

        log "Extracting the image..."
        unzip -o "$RPI_IMAGE_ZIP"
    fi
}

# Download optimized kernel and DTB
download_kernel_dtb() {
    log "Downloading WORKING ARMv7 kernel with NETWORK SUPPORT for Buster..."
    
    cd "$WORK_DIR"
    
    # NUOVO KERNEL con supporto di rete completo
    KERNEL_FILE="kernel-qemu-4.14.79-stretch"
    DTB_FILE="versatile-pb.dtb" 
    
    # Download kernel con supporto rete (da Stretch che funziona con Buster)
    if [ ! -f "$KERNEL_FILE" ]; then
        log "Downloading kernel with WORKING network drivers..."
        wget -c "https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.14.79-stretch" -O "$KERNEL_FILE"
        log "Downloaded working kernel: $KERNEL_FILE"
    else
        log "Working kernel already present: $KERNEL_FILE"
    fi
    
    # Download DTB compatibile
    if [ ! -f "$DTB_FILE" ]; then
        log "Downloading compatible DTB..."
        wget -c "https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/versatile-pb.dtb" -O "$DTB_FILE"
        log "Downloaded DTB: $DTB_FILE"
    else
        log "DTB already present: $DTB_FILE"
    fi
    
    log "WORKING kernel and DTB files ready for Buster ✓"
}

# Setup remote access - ADAPTED FOR BUSTER
setup_remote_access() {
    log "Configuring remote access for Buster..."

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

    # Create temporary mount directories with unique names
    local boot_mount_dir="/tmp/rpi_boot_$(date +%s)_$$"
    local root_mount_dir="/tmp/rpi_root_$(date +%s)_$$"
    
    # Cleanup function
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

    # Configure boot partition
    log "Mounting boot partition..."
    if ! sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$boot_mount_dir"; then
        error "Failed to mount boot partition"
        return 1
    fi

    # Enable SSH
    sudo touch "$boot_mount_dir/ssh"

    # Configure user credentials for Buster
    log "Configuring user credentials for Buster..."
    local password_hash='$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0'
    echo "pi:$password_hash" | sudo tee "$boot_mount_dir/userconf.txt" > /dev/null

    # Configure display settings
    log "Configuring display settings for Buster emulation..."
    echo "" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "# Emulation Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_force_hotplug=1" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_group=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_mode=82" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "hdmi_drive=2" | sudo tee -a "$boot_mount_dir/config.txt"
    echo "gpu_mem=128" | sudo tee -a "$boot_mount_dir/config.txt"
    
    # Add remote desktop configuration if needed
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        echo "# Remote Desktop Configuration" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "dtoverlay=vc4-fkms-v3d" | sudo tee -a "$boot_mount_dir/config.txt"
        echo "disable_overscan=1" | sudo tee -a "$boot_mount_dir/config.txt"
    fi

    # Unmount boot partition
    log "Unmounting boot partition..."
    sudo umount "$boot_mount_dir"

    # Mount root partition for additional configuration
    log "Mounting root partition..."
    local root_loop_device=$(sudo losetup -f)
    sudo losetup -o "$root_offset" "$root_loop_device" "$RPI_IMAGE"
    
    if ! sudo mount "$root_loop_device" "$root_mount_dir"; then
        error "Failed to mount root partition"
        sudo losetup -d "$root_loop_device" 2>/dev/null || true
        return 1
    fi

    # Add remote desktop setup if needed
    if [ "$ENABLE_VNC" = true ] || [ "$ENABLE_RDP" = true ]; then
        setup_remote_desktop_buster "$root_mount_dir"
    fi
    
    # Setup first boot script for additional configuration
    setup_first_boot_script "$root_mount_dir" "buster"
    
    # Unmount root partition and detach loop device
    log "Unmounting root partition..."
    sudo umount "$root_mount_dir"
    sudo losetup -d "$root_loop_device"

    log "Remote access configured for Buster ✓"
}

# Setup remote desktop for Buster - SIMPLIFIED APPROACH
setup_remote_desktop_buster() {
    local root_mount_dir="$1"
    
    log "Setting up remote desktop services for Buster..."
    
    # Create simple setup script for Buster
    sudo mkdir -p "$root_mount_dir/usr/local/bin"
    
    sudo tee "$root_mount_dir/usr/local/bin/setup-buster-desktop.sh" > /dev/null << 'EOF'
#!/bin/bash
# Simple Remote Desktop Setup for Buster

log_setup() {
    echo "[BUSTER-SETUP] $1" | tee -a /var/log/buster-setup.log
}

if [ -f "/boot/.buster-setup-done" ]; then
    log_setup "Setup already completed, skipping"
    exit 0
fi

log_setup "Configuring Buster for remote access..."

# Update system
apt update -y

# Enable SSH
systemctl enable ssh
systemctl start ssh

# Install and configure VNC if requested
if [ "$ENABLE_VNC" = "true" ]; then
    log_setup "Setting up VNC for Buster..."
    
    # Enable VNC via raspi-config
    raspi-config nonint do_vnc 0
    
    # Set VNC password
    echo 'raspberry' | vncpasswd -service -legacy
    
    log_setup "VNC configured for Buster"
fi

# Install and configure RDP if requested
if [ "$ENABLE_RDP" = "true" ]; then
    log_setup "Setting up RDP for Buster..."
    
    # Install xrdp
    apt install -y xrdp
    
    # Configure xrdp for Buster
    usermod -a -G ssl-cert pi
    
    # Simple startwm.sh for Buster
    cat > /etc/xrdp/startwm.sh << 'RDPEOF'
#!/bin/sh
if test -r /etc/profile; then . /etc/profile; fi
exec /usr/bin/startlxde-pi
RDPEOF
    
    chmod +x /etc/xrdp/startwm.sh
    
    # Enable xrdp
    systemctl enable xrdp
    systemctl start xrdp
    
    log_setup "RDP configured for Buster"
fi

# Mark setup as complete
touch /boot/.buster-setup-done

log_setup "Buster setup completed successfully!"
EOF

    sudo chmod +x "$root_mount_dir/usr/local/bin/setup-buster-desktop.sh"
    
    # Create systemd service for first boot
    sudo tee "$root_mount_dir/etc/systemd/system/buster-setup.service" > /dev/null << 'EOF'
[Unit]
Description=Buster First Boot Setup
After=network.target
ConditionPathExists=!/boot/.buster-setup-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-buster-desktop.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service
    sudo mkdir -p "$root_mount_dir/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/etc/systemd/system/buster-setup.service" \
        "$root_mount_dir/etc/systemd/system/multi-user.target.wants/buster-setup.service"
    
    # Set environment variables
    echo "ENABLE_VNC=$ENABLE_VNC" | sudo tee "$root_mount_dir/etc/environment" > /dev/null
    echo "ENABLE_RDP=$ENABLE_RDP" | sudo tee -a "$root_mount_dir/etc/environment" > /dev/null
    
    log "Remote desktop setup configured for Buster"
}

# Resize image
resize_image() {
    log "Resizing Buster image..."

    local current_size=$(stat -c%s "$RPI_IMAGE")
    local target_bytes=8589934592  # 8GB
    
    if [ $current_size -gt $target_bytes ]; then
        log "Image already resized to 8GB, skipping"
        return 0
    fi

    qemu-img resize -f raw "$RPI_IMAGE" 8G
    log "Image resized to 8GB ✓"
}

# Start QEMU
start_qemu() {
    log "Starting QEMU Raspberry Pi Buster emulation (NETWORK FIXED)..."
    
    local qemu_cmd="qemu-system-arm"
    
    # Configurazione che FUNZIONA
    local qemu_args=(
        "-M" "versatilepb"
        "-cpu" "arm1176"
        "-m" "256"
        "-smp" "1" 
        "-kernel" "$KERNEL_FILE"
        "-dtb" "$DTB_FILE"
        "-drive" "format=raw,file=$RPI_IMAGE"
        "-append" "root=/dev/sda2 panic=1 rootfstype=ext4 rw"
        "-nic" "$netdev_options"
        "-no-reboot"
    )
    
    # Configurazione di rete SEMPLIFICATA che funziona
    local netdev_options="user,hostfwd=tcp::$SSH_PORT-:22"
    
    if [ "$ENABLE_VNC" = true ]; then
        netdev_options+=",hostfwd=tcp::$VNC_PORT-:5901"
        log "VNC will be available on port $VNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        netdev_options+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "RDP will be available on port $RDP_PORT"
    fi
    

    # Resto della configurazione display...
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

    echo
    log "Connection Information for Buster (NETWORK SHOULD WORK NOW):"
    echo "  SSH: ssh -p $SSH_PORT pi@localhost"
    echo "  Password: $RPI_PASSWORD"
    
    if [ "$ENABLE_VNC" = true ]; then
        echo "  VNC: localhost:$VNC_PORT"
    fi
    
    if [ "$ENABLE_RDP" = true ]; then
        echo "  RDP: localhost:$RDP_PORT"
    fi
    
    echo
    warning "KERNEL FIX APPLIED:"
    echo "  - Using kernel-qemu-4.14.79-stretch (has working network drivers)"
    echo "  - This kernel supports both Stretch AND Buster userlands"
    echo "  - RTL8139 driver is included and working"
    
    echo
    log "Starting Buster with WORKING network kernel..."
    echo "QEMU Command: $qemu_cmd ${qemu_args[*]}"
    echo
    
    # Resto della funzione rimane uguale...
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
    
    # Process monitoring with cleanup
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
    
    # Cleanup on exit
    cleanup_on_exit() {
        log "Cleaning up QEMU processes..."
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
    echo "  QEMU Raspberry Pi - [$DISTRO]"
    echo "==============================================="
    echo -e "${NC}"

    auto_cleanup_dead_instances
    
    check_dependencies
    download_image
    download_kernel_dtb
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
    echo "Raspberry Pi OS Buster Emulator"
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -p PORT           Set SSH port (default: auto-allocated)"
    echo "  -d DIR            Set working directory (default: ~/qemu-rpi/buster)"
    echo "  --vnc [PORT]      Enable RealVNC server (default: auto-allocated)"
    echo "  --rdp [PORT]      Enable RDP server (default: auto-allocated)"
    echo "  --wayvnc [PORT]   Enable WayVNC server (default: auto-allocated)"
    echo "  --headless        Run without display (headless mode)"
    echo
    echo "Method Features:"
    echo "  - Uses original Buster ARMv7 image (2020-02-13)"
    echo "  - Downloads optimized ARM64 kernel from qemu-rpi-kernel repo"
    echo "  - Downloads optimized DTB for Pi 3B+ emulation"
    echo "  - Fixed machine configuration: raspi3b with cortex-a72"
    echo
    echo "Requirements:"
    echo "  - QEMU 6.2+ recommended (compile from source for best results)"
    echo "  - qemu-system-aarch64 available in PATH"
    echo
    echo "Examples:"
    echo "  $0                    # Basic emulation"
    echo "  $0 --vnc              # With VNC access"
    echo "  $0 --headless --rdp   # Headless with RDP"
    echo "  $0 --vnc --rdp        # Full remote desktop support"
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
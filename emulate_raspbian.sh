#!/bin/bash
ZIP_FILE=raspbian
IMG_FILE=2017-04-10-raspbian-jessie
RASPBIAN_FILE=http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/$IMG_FILE.zip
DEST_DIR=qemu_vms
KERNEL_URL=https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.4.34-jessie
KERNEL_FILE=kernel-qemu-4.4.34-jessie

# Install Qemu
echo "Install Qemu..."
sudo apt-get install qemu-system

if test -f "$IMG_FILE.img"; then
    echo "$IMG_FILE.img exists, skip download..."
else
    wget -O $ZIP_FILE.zip $RASPBIAN_FILE
    unzip $ZIP_FILE
fi

if test -f "$KERNEL_FILE"; then
    echo "$KERNEL_FILE exists, skip download..."
else
    wget -O $KERNEL_FILE $KERNEL_URL
fi

#fdisk -l $IMG_FILE.img

START_OFFSET=`fdisk -l $IMG_FILE.img | grep $IMG_FILE.img2 | awk '{print $2}'`
OFFSET=$(($START_OFFSET * 512))
mkdir -p $DEST_DIR/
sudo umount $DEST_DIR
sleep 2
sudo mount -v -o offset=$OFFSET -t ext4 $IMG_FILE.img $DEST_DIR

qemu-system-arm -kernel $KERNEL_FILE -cpu arm1176 -m 256 -M versatilepb -serial stdio -append "root=/dev/sda2 rootfstype=ext4 rw" -hda $IMG_FILE.img -nic user,hostfwd=tcp::5022-:22 -no-reboot

sudo umount $DEST_DIR

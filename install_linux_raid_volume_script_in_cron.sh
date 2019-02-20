#!/bin/bash

# This script is intended only to be used to install create_linux_raid_volume.sh script and
# configure it to be executed when the machine is rebooted via cron as root
# Notice that this can be modified to include extra settings that the create_linux_raid_volume.sh script supports

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 3 ]; then
    echo "Usage: $0 <Mount Point> <File System Type = ext4|xfs> <data disk count>"
    exit 1
fi

MOUNT_POINT=$1
FS_TYPE=$2
DEVICE_COUNT=$3

install_script_in_cron()
{
	cp ./create_linux_raid_volume.sh /root
	chmod 700 /root/create_linux_raid_volume.sh
	! crontab -l > cron_content
	echo "@reboot /root/create_linux_raid_volume.sh -m $MOUNT_POINT -f $FS_TYPE -d -e $DEVICE_COUNT >>/root/create_linux_raid_volume.txt" >> cron_content
	crontab cron_content
	rm cron_content
}

SETUP_MARKER=/var/local/install_linux_raid_volume_script_in_cron.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

install_script_in_cron

# Create marker file so we know we're configured
sudo touch $SETUP_MARKER
#!/bin/bash

# Remember current directory
CURRENT_DIR="$PWD"

# Function to ask user for generating Secure Boot certificate
function ask_to_generate_certificate {
    while true; do
        read -p "Do you want to generate the certificate required for Secure Boot? (Y/N): " yn
        case $yn in
            [Yy]* ) return 0;;  # User agreed
            [Nn]* ) return 1;;  # User declined
            * ) echo "Please answer Y or N.";;
        esac
    done
}

# Function to import certificate
function import_certificate {
    mokutil --import /var/lib/shim-signed/mok/MOK.der
}

# Function to ask user to shutdown
function ask_to_shutdown {
    while true; do
        read -p "Do you want to shutdown the system now? (Y/N): " yn
        case $yn in
            [Yy]* ) shutdown now; break;;
            [Nn]* ) echo "System will not be shutdown."; break;;
            * ) echo "Please answer Y or N.";;
        esac
    done
}

# Ask user for Git repository clone path
read -p "Enter the path where Git repository should be cloned: " GIT_PATH

# Create directory if it doesn't exist
mkdir -p "$GIT_PATH"

# Change directory to specified path
cd "$GIT_PATH" || { echo "Cannot change to directory $GIT_PATH"; exit 1; }

# Update and install necessary packages
apt update && apt install git dkms -y

# Clone Git repository
git clone https://github.com/michael-pptf/i915-sriov-dkms

# Change directory to cloned repository
cd "./i915-sriov-dkms" || { echo "Cannot change to directory i915-sriov-dkms"; exit 1; }

# Backup dkms.conf file
cp -a dkms.conf{,.bak}

# Get current kernel version (major and minor only)
KERNEL=$(uname -r | cut -d'.' -f1,2)

# Update dkms.conf file
sed -i 's/"@_PKGBASE@"/"i915-sriov-dkms"/g' dkms.conf
sed -i 's/"@PKGVER@"/"'"$KERNEL"'"/g' dkms.conf
sed -i 's/ -j$(nproc)//g' dkms.conf

# Path to guc_version_abi.h file
GUC_VERSION_ABI_H="drivers/gpu/drm/i915/gt/uc/abi/guc_version_abi.h"

# Backup guc_version_abi.h file
cp -a "$GUC_VERSION_ABI_H"{,.bak}

# Additional edits to guc_version_abi.h file
sed -i 's/\(#define GUC_VF_VERSION_LATEST_MINOR[[:space:]]*\)[0-9]\+/\19/' "$GUC_VERSION_ABI_H"

# Display updated dkms.conf file contents
cat dkms.conf

# Return to initial working directory
cd "$CURRENT_DIR"

# Backup /etc/default/grub file
cp /etc/default/grub /etc/default/grub.bak

# Edit /etc/default/grub file
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet i915.enable_guc=3"/' /etc/default/grub

# Backup kernel configuration file
CONFIG_FILE="/boot/config-$(uname -r)"
BACKUP_FILE="${CONFIG_FILE}.bak"
cp "$CONFIG_FILE" "$BACKUP_FILE"

# Function to check and update entries in kernel configuration file
function check_and_update() {
    local CONFIG_KEY=$1
    local DESIRED_VALUE=$2
    local CURRENT_VALUE=$(grep -E "^$CONFIG_KEY=" "$CONFIG_FILE")

    if [ -z "$CURRENT_VALUE" ]; then
        echo "$CONFIG_KEY not found, adding entry"
        echo "$CONFIG_KEY=$DESIRED_VALUE" | sudo tee -a "$CONFIG_FILE" > /dev/null
    else
        if [ "$CURRENT_VALUE" != "$CONFIG_KEY=$DESIRED_VALUE" ]; then
            echo "Updating $CONFIG_KEY from '$CURRENT_VALUE' to '$CONFIG_KEY=$DESIRED_VALUE'"
            sudo sed -i "s/^$CONFIG_KEY=.*/$CONFIG_KEY=$DESIRED_VALUE/" "$CONFIG_FILE"
        else
            echo "$CONFIG_KEY already set to '$DESIRED_VALUE'"
        fi
    fi
}

# Check and update entries in kernel configuration file
check_and_update "CONFIG_INTEL_MEI_PXP" "m"
check_and_update "CONFIG_DRM_I915_PXP" "y"

# Display message if changes were made
if [ -f "$BACKUP_FILE" ]; then
    echo "Changes have been made and saved in $CONFIG_FILE. Backup is located at $BACKUP_FILE."
else
    echo "No changes made. Entries are already compliant."
fi

# Return to initial working directory
cd "$CURRENT_DIR"

# Copy i915-sriov-dkms directory to /usr/src/i915-sriov-dkms-KERNEL
cp -r "$GIT_PATH/i915-sriov-dkms" "/usr/src/i915-sriov-dkms-$KERNEL"

dkms install --force -m i915-sriov-dkms -v "$KERNEL"

# Ask to generate certificate
if ask_to_generate_certificate; then
    import_certificate
else
    echo "Skipping certificate generation."
fi

# Get orginal current kernel version
KERNEL_ORG=$(uname -r)

# Hold kernel in ubuntu 23.10 (linux-image-6.5.0-41-generic)
apt-mark hold "linux-image-$KERNEL_ORG"

# Update and upgrade to new release '24.04 LTS'
apt update && apt upgrade -y
apt dist-upgrade -y
apt install update-manager-core -y

# Note to avoid restarting machine after upgrade
echo "Remember not to restart the machine after upgrading to a higher version. I'll let you know when to do it :)"
echo "Press any key to continue..."
read -n 1 -s -r -p ""

# Install new release
/usr/bin/do-release-upgrade

# Get list of installed kernels, headers, and modules excluding current kernel
kernels=$(dpkg --list | grep 'linux-image-[0-9]' | awk '{ print $2 }' | grep -v $(uname -r))
headers=$(dpkg --list | grep 'linux-headers-[0-9]' | awk '{ print $2 }' | grep -v $(uname -r | sed 's/-generic//'))
modules=$(dpkg --list | grep 'linux-modules-[0-9]' | awk '{ print $2 }' | grep -v $(uname -r))

# Display list to be removed
echo "The following kernels, headers, and modules will be removed:"
echo "$kernels"
echo "$headers"
echo "$modules"

# Ask for confirmation
read -p "Are you sure you want to remove these packages? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Removal canceled."
    exit 1
fi

# Remove kernels
for kernel in $kernels; do
    sudo apt-get remove --purge -y $kernel
done

# Remove headers
for header in $headers; do
    sudo apt-get remove --purge -y $header
done

# Remove modules
for module in $modules; do
    sudo apt-get remove --purge -y $module
done

# Cleanup
sudo apt autoremove -y
sudo update-grub

echo "Removal completed."

# Update GRUB and initramfs
update-grub
update-initramfs -c -k all

echo "Updated dkms.conf file is located in $GIT_PATH/i915-sriov-dkms"
echo "guc_version_abi.h file has been updated in $GIT_PATH/i915-sriov-dkms/drivers/gpu/drm/i915/gt/uc/abi/"
echo "Backup of guc_version_abi.h file is located in $GIT_PATH/i915-sriov-dkms/drivers/gpu/drm/i915/gt/uc/abi/guc_version_abi.h.bak"
echo "i915-sriov-dkms directory has been copied to /usr/src/i915-sriov-dkms-$KERNEL"
echo "Updated /etc/default/grub file is located in /etc/default/grub.bak"
echo "GRUB configuration has been updated."

# Ask to shutdown system
RED='\033[0;31m'
NC='\033[0m' # No Color
message="Remember that if you use secureboot, you must first start the machine without any changes to the display or adding graphics, to load the certificate into the virtual machine."
echo -e "${RED}${message}${NC}"
echo "You can now shut down the system to add a graphics card to the machine and disable the display."
ask_to_shutdown

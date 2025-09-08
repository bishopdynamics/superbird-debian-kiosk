#!/bin/bash
# shellcheck disable=SC2129

# build debian image, intended to run on a debian 11 arm64 host
# expects an existing dump at ./dumps/debian_current/
#   ./dumps is ignored by git
# add --local_proxy flag argument to try to use local instance of apt-cacher-ng at localhost:3142

set -e  # bail on any errors



# all config lives in image_config.sh
source ./image_config.sh

# log this script's actions to a file
exec > >(tee ${EXISTING_DUMP}/build.log) 2>&1

################################################ Additional Packages ################################################

# init system, either systemd or sysvinit
#   without systemd-sysv, no reboot/shutdown commands
PACKAGES="systemd systemd-sysv dbus kmod"
# base packages
PACKAGES="$PACKAGES usbutils htop nano tree file less locales sudo dialog apt systemd-sysv"
# stuff for networking
PACKAGES="$PACKAGES wget curl iputils-ping iputils-tracepath iputils-arping iproute2 net-tools openssh-server ntpsec"
# minimal xorg
PACKAGES="$PACKAGES xserver-xorg-core xserver-xorg-video-fbdev xterm xinit x11-xserver-utils shared-mime-info"
# xorg input
PACKAGES="$PACKAGES xserver-xorg-input-evdev libinput-bin xserver-xorg-input-libinput xinput"
# additional required tools
PACKAGES="$PACKAGES fbset tigervnc-scraping-server"

# NOTE: we cannot install chromium at at the debootstrap stage
#   so we install chromium and other packages in a separate stage using chroot

STAGE2_PACKAGES="python3-minimal python3-pip $EXTRA_PACKAGES"
STAGE2_PACKAGES="$STAGE2_PACKAGES chromium"
# STAGE2_PACKAGES="$STAGE2_PACKAGES firefox-esr"

################################################ Running Variables ################################################

KERNEL_VERSION="4.9.113"  # this is the kernel that comes with superbird, we dont have any other kernel

ENV_FILE="./files/env/env_switchable.txt"  # env file to replace existing
FILES_SYS="./files/system_a"
FILES_DATA="./files/data"
LOGO_IMAGES="./files/logo"
LOGO_SOURCES="./logos_sources"
TEMP_DIR="./temp"

SYS_PATH="${TEMP_DIR}/system_a"  # this is where we will mount system_a partition to modify, and get modules
INSTALL_PATH="${TEMP_DIR}/data"  # this is where we will mount data partition to perform install

CSV_PACKAGES=$(echo "$PACKAGES"| tr ' ' ',')  # need comma-separated list of packages for debootstrap


################################################ Functions ################################################

in_target() {
	# run command(s) within the chroot
	chroot "${INSTALL_PATH}" "$@"
}

install_script() {
	# copy the named script into target /scripts/ and make it executable, owned by superbird
	local SCR_NAME="$1"
	echo "Installing script: $SCR_NAME"
	cp "${FILES_DATA}/scripts/$SCR_NAME" "${INSTALL_PATH}/scripts/$SCR_NAME"
	chmod +x "${INSTALL_PATH}/scripts/$SCR_NAME"
	in_target chown "$USER_NAME" "/scripts/$SCR_NAME"
}

install_service() {
	# copy named service file into taret /lib/systemd/system/, symlink it into multi-user.target.wants, and make it owned by superbird
	local SVC_NAME="$1"
	echo "Installing service: $SVC_NAME"
	cp "${FILES_DATA}/lib/systemd/system/$SVC_NAME" "${INSTALL_PATH}/lib/systemd/system/$SVC_NAME"
	in_target chown "$USER_NAME" "/lib/systemd/system/$SVC_NAME"
	in_target ln -s "/lib/systemd/system/$SVC_NAME" "/etc/systemd/system/multi-user.target.wants/$SVC_NAME"
}

function make_user_dir {
	# create a folder owned by the user, with given chmod
	local path="$1"
	local mode="$2"
	echo "Creating folder $path ($mode)"
	in_target mkdir -p "$path"
	in_target chown -R "${USER_NAME}":"${USER_NAME}" "$path"
	in_target chmod "$mode" "$path"
}

function make_user_file {
	# create a file owned by the user, with given chmod
	local path="$1"
	local mode="$2"
	echo "Creating file $path ($mode)"
	in_target touch "$path"
	in_target chown "${USER_NAME}":"${USER_NAME}" "$path"
	in_target chmod "$mode" "$path"
}

################################################ Entrypoint ################################################

echo "Going to install Debian $DISTRO_BRANCH $DISTRO_VARIANT $ARCHITECTURE into image at $EXISTING_DUMP"

# need to be root
if [ "$(id -u)" != "0" ]; then
	echo "Must be run as root"
	exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "Only works on Linux!"
    exit 1
fi

if [ -z "$EXISTING_DUMP" ] || [ ! -d "$EXISTING_DUMP" ]; then
	echo "Need to provide an existing dump for us to modify"
	echo "ex: $0 ./dumps/debian_current"
	exit 1
fi
if [ ! -f "${EXISTING_DUMP}/data.ext4" ]; then
    echo "Missing expected ${EXISTING_DUMP}/data.ext4"
    exit 1
fi
if [ ! -f "${EXISTING_DUMP}/system_a.ext2" ]; then
    echo "Missing expected ${EXISTING_DUMP}/system_a.ext2"
    exit 1
fi
if [ ! -f "${EXISTING_DUMP}/settings.ext4" ]; then
    echo "Missing expected ${EXISTING_DUMP}/settings.ext4"
    exit 1
fi

mkdir -p ${TEMP_DIR}

################################################ Parse arguments ################################################

SCREEN_MODE="portrait"
USE_PROXY="False"

# screen mode

if [ "$1" == "landscape" ] || [ "$2" == "landscape" ]; then
	SCREEN_MODE="landscape"
fi

# local proxy

if [ "$1" == "--local_proxy" ] || [ "$2" == "--local_proxy" ]; then
	USE_PROXY="True"
fi


echo "Building for screen mode: ${SCREEN_MODE}"
echo "Using proxy: $USE_PROXY"

################################################ Modify env ################################################

cp "$ENV_FILE" "${EXISTING_DUMP}/env.txt"
# we dont need to keep env.dump, superbird_tool prefers env.txt, safer way to deal with env
if [ -f "${EXISTING_DUMP}/env.dump" ]; then
	rm "${EXISTING_DUMP}/env.dump"
fi

################################################ Rebuild logo.dump using custom images ################################################

echo "Packing logo images"
if [ "$SCREEN_MODE" == "landscape" ]; then
	cp ${LOGO_SOURCES}/upgrade_success_landscape.bmp ${LOGO_IMAGES}/upgrade_success.bmp
else
	cp ${LOGO_SOURCES}/upgrade_success_portrait.bmp ${LOGO_IMAGES}/upgrade_success.bmp
fi
./aml-imgpack.py --pack "${EXISTING_DUMP}/logo.dump" ${LOGO_IMAGES}/*.bmp && echo "all images have been packed into ${EXISTING_DUMP}/logo.dump"

################################################ Format Partitions ################################################

echo "formatting ${EXISTING_DUMP}/data.ext4"
mountpoint "$INSTALL_PATH" && umount "$INSTALL_PATH"
mkfs.ext4 -F "${EXISTING_DUMP}/data.ext4" || {
	echo "failed to format data (or user cancelled format), quitting"
	exit 1
}

mountpoint "$SYS_PATH" && umount "$SYS_PATH"
mkfs.ext4 -F "${EXISTING_DUMP}/settings.ext4" || {
	echo "failed to format settings (or user cancelled format), quitting"
	exit 1
}

################################################ Mount Partitions ################################################

mkdir -p "$INSTALL_PATH"
mount -o loop "${EXISTING_DUMP}/data.ext4" "$INSTALL_PATH"
mkdir -p "$SYS_PATH"
mount -o loop "${EXISTING_DUMP}/system_a.ext2" "$SYS_PATH"


################################################ Install Packages ################################################
echo "Installing packages: $CSV_PACKAGES"
echo ""

# use local apt-cacher-ng instance
if [ "$USE_PROXY" == "True" ]; then
	export http_proxy=http://127.0.0.1:3142
	echo "Using local apt-cacher-ng proxy at: ${http_proxy}"
	echo ""
fi

echo "Debootstrap: debootstrap --variant=$DISTRO_VARIANT --no-check-gpg --arch=$ARCHITECTURE $DISTRO_BRANCH $INSTALL_PATH $DISTRO_REPO_URL"
echo ""

debootstrap --verbose --variant="$DISTRO_VARIANT" --no-check-gpg --include="$CSV_PACKAGES" --arch="$ARCHITECTURE" "$DISTRO_BRANCH" "$INSTALL_PATH" "$DISTRO_REPO_URL"

in_target apt update
# shellcheck disable=SC2086
in_target apt install -y --no-install-recommends --no-install-suggests $STAGE2_PACKAGES

mkdir -p "${INSTALL_PATH}/scripts"
cp "${FILES_DATA}/scripts/requirements.txt" "${INSTALL_PATH}/scripts/requirements.txt"
if [ "$DISTRO_BRANCH" == "bullseye" ]; then
	in_target python3 -m pip install -r /scripts/requirements.txt
else
	in_target python3 -m pip install -r /scripts/requirements.txt --break-system-packages
fi

################################################ Configure partition mountpoints and serial console ##############################

cp ${FILES_DATA}/etc/fstab "${INSTALL_PATH}/etc/fstab"
cp ${FILES_DATA}/etc/inittab "${INSTALL_PATH}/etc/inittab"

################################################ Copy Kernel Modules from system_a ################################################

mkdir -p "${INSTALL_PATH}/lib/modules"
cp -r "${SYS_PATH}/lib/modules/${KERNEL_VERSION}" "${INSTALL_PATH}/lib/modules/"


################################################ Modify system_a for Utility Mode ################################################

cp ${FILES_SYS}/etc/fstab ${SYS_PATH}/etc/
cp ${FILES_SYS}/etc/inittab ${SYS_PATH}/etc/
cp ${FILES_SYS}/etc/init.d/S49usbgadget ${SYS_PATH}/etc/init.d/
chmod +x ${SYS_PATH}/etc/init.d/S49usbgadget



################################################ Done with system_a, unmount it ################################################

umount "$SYS_PATH"
rmdir "$SYS_PATH"


################################################ Setup Xorg ################################################

echo "creating xorg.conf"
mkdir -p "${INSTALL_PATH}/etc/X11"

if [ "$SCREEN_MODE" == "landscape" ]; then
	cp ${FILES_DATA}/etc/X11/xorg.conf.landscape "${INSTALL_PATH}/etc/X11/xorg.conf"
else
	cp ${FILES_DATA}/etc/X11/xorg.conf.portrait "${INSTALL_PATH}/etc/X11/xorg.conf"
fi

# need to disable the scripts that try to autodetect input devices, they cause double input
# 	this is particularly evident when in landscape mode, as only one of the two inputs is correctly transformed for the rotation
# 	these files were installed by xserver-xorg-input-libinput
in_target mv /usr/share/X11/xorg.conf.d /usr/share/X11/xorg.conf.d.bak


################################################ Setup Hostname and Hosts ################################################

echo "Setting hostname"
echo "$HOST_NAME" > "${INSTALL_PATH}/etc/hostname"

echo "Generating /etc/hosts"

HOSTS_CONTENT=$(
	cat <<- EOHF
	# generated by $0
	127.0.0.1     localhost
	127.0.0.1     $HOST_NAME
	::1           localhost $HOST_NAME ip6-localhost ip6-loopback
	ff02::1		ip6-allnodes
	ff02::2       ip6-allrouters
	${USBNET_PREFIX}.1   host
	EOHF
)
echo "$HOSTS_CONTENT" > "${INSTALL_PATH}/etc/hosts"


################################################ Setup user accounts ################################################

# NOTE: you could set the root password here, but you need to do it interactively
# in_target passwd

echo "Creating regular user (with sudo rights): $USER_NAME"

in_target useradd -p "$USER_PASS_HASH" --shell /bin/bash "$USER_NAME"

make_user_dir "/home/${USER_NAME}" 700
make_user_dir "/home/${USER_NAME}/.ssh" 700

# let user use sudo without password
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" >> "${INSTALL_PATH}/etc/sudoers"

set +e  # ok if some of these fail
in_target usermod -aG cdrom "$USER_NAME"
in_target usermod -aG floppy "$USER_NAME"
in_target usermod -aG sudo "$USER_NAME"
in_target usermod -aG audio "$USER_NAME"
in_target usermod -aG dip "$USER_NAME"
in_target usermod -aG video "$USER_NAME"
in_target usermod -aG plugdev "$USER_NAME"
# in_target usermod -aG netdev "$USER_NAME"
# in_target usermod -aG ssh "$USER_NAME"
set -e

################################################ install ssh key for host->superbird ###########################################

make_user_file "/home/${USER_NAME}/.ssh/authorized_keys" 600
echo "$SSH_KEY_PUBLIC" > "${INSTALL_PATH}/home/${USER_NAME}/.ssh/authorized_keys"

################################################ Setup scripts and services ################################################

install_script setup_usbgadget.sh
install_service usbgadget.service

install_script setup_display.sh
install_script clear_display.sh

install_script vnc_passwd
install_script setup_vnc.sh
install_service vnc.service

install_script start_buttons.sh
install_script buttons_app.py
install_script buttons_settings.py
install_service buttons.service

install_script setup_backlight.sh
install_service backlight.service

install_script start_browser.sh
install_script browser_settings.sh
install_service browser.service

in_target chown -R "$USER_NAME" /scripts


################################################ Cleanup systemd and timezone stuff ################################################

echo "making sure symlinks exist for systemd"
in_target ln -sf "/lib/systemd/system/getty@.service" "/etc/systemd/system/getty.target.wants/getty@ttyS0.service"

echo "Generating locales for $LOCALE"
sed -i -e 's/# '"$LOCALE"' UTF-8/'"$LOCALE"' UTF-8/' "${INSTALL_PATH}/etc/locale.gen"
echo "LANG=\"${LOCALE}\"" > "${INSTALL_PATH}/etc/default/locale"
in_target dpkg-reconfigure --frontend=noninteractive locales

echo "Setting timezone to $TIMEZONE"
in_target ln -sf "/usr/share/zoneinfo/$TIMEZONE" "/etc/localtime"
in_target dpkg-reconfigure --frontend=noninteractive tzdata


################################################ Done! ################################################

echo "syncing changes to disk"
sync

echo "Filesystem      Size  Used Avail Use% Mounted on"
df -h |grep "$INSTALL_PATH"

echo "Un-mounting $INSTALL_PATH"
umount "$INSTALL_PATH"

echo "Generating checksums.txt"
pushd "$EXISTING_DUMP"
md5sum ./* > checksums.txt
popd

set +e  # ok if cleanup fails
# cleanup temp
rm -r ${TEMP_DIR}

echo "Done installing debian to: ${EXISTING_DUMP}"

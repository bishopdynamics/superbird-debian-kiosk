#!/usr/bin/bash

# prepare host by upgrading packages, installing git, and cloning the repo
#   copy/paste this script into a file named "prep.sh" on the freshly-flashed raspberry pi
#   then run with: sudo bash prep.sh
#   next, run setup_host.sh from the repo


set -e

# need to be root
if [ "$(id -u)" != "0" ]; then
	echo "Must be run as root"
	exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "Only works on Linux!"
    exit 1
fi

apt update
apt upgrade -y

apt install -y htop git

# git config --global credential.helper store
git clone https://github.com/bishopdynamics/superbird-debian-kiosk.git

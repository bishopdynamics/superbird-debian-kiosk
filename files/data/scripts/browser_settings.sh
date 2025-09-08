#!/bin/bash
# settings for /scripts/start_browser.sh
# shellcheck disable=SC2034

URL="https://192.168.1.144:8123/lovelace/"
SCALE="1.0"
EXTRA_CHROMIUM_ARGS=""
EXTRA_XORG_ARGS="-nocursor"
USER_DATA_DIR="/config"
DISK_CACHE_DIR="/dev/null"  # set to "/dev/null" to prevent browser from caching anything

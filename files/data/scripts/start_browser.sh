#!/bin/bash
# Start X with just a browser
#	fullscreen, kiosk mode, tweaked for touchscreen, with given url

# ## Variables expected from browser_settings.sh
# URL="https://192.168.1.144:8123/lovelace/"
# SCALE="1.0"
# EXTRA_CHROMIUM_ARGS=""
# EXTRA_XORG_ARGS="-nocursor"
# USER_DATA_DIR="/config"
# DISK_CACHE_DIR="/dev/null"  # prevent browser from caching anything

# log this script's actions to a file
exec 1>/var/log/browser.log 2>&1

echo "Starting browser kiosk"

# shellcheck source=./browser_settings.sh
source /scripts/browser_settings.sh

## Browser choice
# NOTE: earlier versions of trixie(sid) + chromium worked fine, but release version is broken
# 	firefox works better on bookworm than trixie, but not ideal
# 	firefox unfortunately does not have --ignore-certificate-errors, so self-signed certs will have to be accepted manually
#	firefox actually doesnt work well period, needs more ram

USE_FIREFOX="False"  # set to True to use firefox instead (needs to be included in the image)
if [ "$USE_FIREFOX" == "True" ]; then
	BROWSER_BINARY="/usr/bin/firefox"
	USER_DATA_DIR="${USER_DATA_DIR}/firefox"
else
	BROWSER_BINARY="/usr/bin/chromium"
	USER_DATA_DIR="${USER_DATA_DIR}/chromium"
fi
command -v "$BROWSER_BINARY" >/dev/null || {
	echo "Need to install browser! Could not find: ${BROWSER_BINARY}"
	exit 1
}
mkdir -p ${USER_DATA_DIR}


# does not get cleaned up properly after previous exit
if [ -f "${USER_DATA_DIR}/SingletonLock" ]; then
	rm ${USER_DATA_DIR}/SingletonLock
fi

# get current resolution so we can match it
#	if you don't set --window-size, chromium will go almost-fullscreen, about 10px shy on all sides
#	if you don't set --window-position, chromium will start at about 10,10 instead of 0,0
#	why does chromium do this??!?!
# here we detect resolution by briefly starting X11 and then parsing output of xrandr
#	this is simpler and more reliable than parsing xorg.conf
#	by avoiding a hardcoded resolution here, we only need to make changes in xorg.conf if we want to change resolution or rotate
# if you have issues where SCALE (--force-device-scale-factor) is not working as expected
#	try removing --window-size and --window-position arguments completely, and see if chromium will go fullscreen-enough for your use-case

# setup the display hardware
/scripts/setup_display.sh

echo "Briefly starting X11 in order to detect configured resolution"
DISP_REZ=$(xinit /usr/bin/xrandr 2>/dev/null|grep "\*"|awk '{print $1}'|tr 'x' ',')
DISP_WIDTH=$(echo "$DISP_REZ"|tr ',' ' '|awk '{print $1}')
DISP_HEIGHT=$(echo "$DISP_REZ"|tr ',' ' '|awk '{print $2}')
echo "Detected resolution: $DISP_REZ ($DISP_WIDTH x $DISP_HEIGHT)"


if [ "$USE_FIREFOX" == "True" ]; then
	# Use Firefox instead. Peformance is bad, but kept around for further experimentation later
	# 	firefox does not have as many flags like chromium
	cat << 'EOF' > ${USER_DATA_DIR}/user.js
	user_pref("browser.preferences.defaultPerformanceSettings.enabled", false);
	user_pref("layers.acceleration.disabled", true);
	user_pref("network.http.use-cache", false);
	user_pref("browser.ssl_override_behavior", 1);
	user_pref("security.ssl.enable_ocsp_stapling", false);
	user_pref("security.ssl.errorReporting.enabled", false);
	user_pref("security.enterprise_roots.enabled", true);
EOF
	BROWSER_CMD="xinit $BROWSER_BINARY \
		--height $DISP_HEIGHT \
		--width $DISP_WIDTH \
		--no-remote \
		--profile ${USER_DATA_DIR} \
		--kiosk $URL -- $EXTRA_XORG_ARGS"

else
	# Use Chromium
	mkdir -p ${USER_DATA_DIR}
	BROWSER_CMD="xinit $BROWSER_BINARY \
		--no-gpu \
		--disable-gpu \
		--no-sandbox \
		--autoplay-policy=no-user-gesture-required \
		--use-fake-ui-for-media-stream \
		--use-fake-device-for-media-stream \
		--disable-sync \
		--remote-debugging-port=9222 \
		--window-size=$DISP_REZ \
		--window-position=0,0 \
		--force-device-scale-factor=$SCALE \
		--pull-to-refresh=1 \
		--disable-smooth-scrolling \
		--disable-login-animations \
		--disable-modal-animations \
		--noerrdialogs \
		--no-first-run \
		--disable-infobars \
		--fast \
		--fast-start \
		--disable-pinch \
		--overscroll-history-navigation=0 \
		--disable-translate \
		--hide-scrollbars \
		--disable-overlay-scrollbar \
		--disable-features=OverlayScrollbar \
		--disable-features=TranslateUI \
		--disk-cache-dir=$DISK_CACHE_DIR \
		--password-store=basic \
		--touch-events=enabled \
		--ignore-certificate-errors \
		--user-data-dir=${USER_DATA_DIR} \
		--kiosk $EXTRA_CHROMIUM_ARGS \
		--app=$URL -- $EXTRA_XORG_ARGS"

fi


echo ""
echo "running browser command: $BROWSER_CMD"
echo ""
$BROWSER_CMD

# clear the display after browser is killed, otherwise the last image will remain frozen
/scripts/clear_display.sh

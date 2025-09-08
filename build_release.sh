#!/bin/bash
# Build and package both release files

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

# all config lives in image_config.sh
source ./image_config.sh

VERSION="$(cat ./VERSION |head -n 1 | tr -d '[:space:]')"

ORIENTATIONS="landscape portrait"

TIMESTAMP=$(date +"%Y-%m-%d")

FILENAME_BASE="debian_${DISTRO_BRANCH}_${ARCHITECTURE}_v${VERSION}"

mkdir -p ./dist

echo "Building release: ${FILENAME_BASE}_${TIMESTAMP}"

for ORIENT in $ORIENTATIONS; do
    VER_NAME="${FILENAME_BASE}_${ORIENT}_${TIMESTAMP}"

    time ./build_image.sh --local_proxy "$ORIENT"
    pushd ./dumps

    echo " temporarily rename folder for creating archive"
    mv "$EXISTING_DUMP_NAME" "$VER_NAME"

    echo " create release archive: ${VER_NAME}.tar.gz"
    time tar czf "${VER_NAME}.tar.gz" "$VER_NAME"

    echo " put folder back"
    mv "$VER_NAME" "$EXISTING_DUMP_NAME"

    echo " move release archive into dist folder"
    mv "${VER_NAME}.tar.gz" ../dist/
    echo " done with $VER_NAME"
    popd
done

echo "Done Building!"
for ORIENT in $ORIENTATIONS; do
    VER_NAME="${FILENAME_BASE}_${ORIENT}_${TIMESTAMP}"
    echo "  Built image: ./dist/${VER_NAME}.tar.gz"
done

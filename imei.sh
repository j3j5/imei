#!/usr/bin/env bash

##############################################################
# Title          : IMEI - ImageMagick Easy Install           #
# Description    : ImageMagick® for Debian/Ubuntu,           #
#                  including advanced delegate support.      #
#                                                            #
# Author         : Sascha Greuel <hello@1-2.dev>             #
# Date           : 2020-05-11 19:51                          #
# License        : ISC                                       #
# Version        : 6.1.1                                     #
#                                                            #
# Usage          : bash ./imei.sh                            #
##############################################################

######################
# Check requirements #
######################

# Check if user is root
[ "$(id -u)" != "0" ] && {
  echo "Error: You must be root or use sudo to run this script"
  exit 1
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

# Make sure, that we are on Debian or Ubuntu
if ! command_exists apt-get; then
  echo "This script cannot run on any other system than Debian or Ubuntu"
  exit 1
fi

# Checking if lsb_release is installed or install it
if ! command_exists lsb_release; then
  apt-get update && apt-get install -qq lsb-release >/dev/null 2>&1
fi

####################
# Script arguments #
####################

while [ "$#" -gt 0 ]; do
  case "$1" in
  --force)
    FORCE="yes"
    ;;
  --imagemagick-version|--im-version)
    IMAGEMAGICK_VER=$2
    ;;
  --skip-aom)
    SKIP_AOM="yes"
    ;;
  --aom-version)
    AOM_VER=$2
    ;;
  --skip-libheif|--skip-heif)
    SKIP_LIBHEIF="yes"
    ;;
  --libheif-version|--heif-version)
    LIBHEIF_VER=$2
    ;;
  --skip-jpeg-xl|--skip-jxl)
    SKIP_JXL="yes"
    ;;
  --jpeg-xl-version|--jxl-version)
    JXL_VER=$2
    ;;
  --skip-dependencies|--skip-deps)
    SKIP_DEPS="yes"
    ;;
  --log-file)
    LOG_FILE=$2
    ;;
  --work-dir)
    WORK_DIR=$2
    ;;
  --build-dir)
    BUILD_DIR=$2
    ;;
  --ci)
    CI_BUILD="yes"
    ;;
  --no-sig-verify|--dev)
    VERIFY_SIGNATURE="${CYELLOW}disabled${CEND}"
    ;;
  *) ;;
  esac
  shift
done

export DEBIAN_FRONTEND=noninteractive

#############
# Variables #
#############

if [ -z "$WORK_DIR" ]; then
  WORK_DIR=/usr/local/src/imei
fi

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR=/usr/local
fi

if [ -z "$LOG_FILE" ]; then
  LOG_FILE=/var/log/imei.log
fi

START=$(date +%s)
OS_DISTRO="$(lsb_release -ds)"
OS_SHORT_CODENAME="$(lsb_release -sc)"
OS_ARCH="$(uname -m)"
SIGNATURE_FILE="/tmp/imei.sh.sig"
PUBLIC_KEY_FILE="/tmp/imei.pem"
GH_FILE_BASE="https://codeload.github.com"
SOURCE_LIST="/etc/apt/sources.list.d/imei.list"
LIB_DIR="/usr/local"
CMAKE_VERSION=""

# Colors
CSI='\033['
CRED="${CSI}1;31m"
CGREEN="${CSI}1;32m"
CYELLOW="${CSI}1;33m"
CBLUE="${CSI}1;36m"
CEND="${CSI}0m"

####################
# Helper functions #
####################

displaytime() {
  local T=$1
  local D=$((T / 60 / 60 / 24))
  local H=$((T / 60 / 60 % 24))
  local M=$((T / 60 % 60))
  local S=$((T % 60))

  ((D > 0)) && printf '%d days ' $D
  ((H > 0)) && printf '%d hours ' $H
  ((M > 0)) && printf '%d minutes ' $M
  ((D > 0 || H > 0 || M > 0)) && printf 'and '

  printf '%d seconds\n' $S
}

str_repeat() {
  printf -v v "%-*s" "$1" ""
  echo "${v// /$2}"
}

version() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

cleanup() {
  if [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi

  if [ -f "$SOURCE_LIST" ]; then
    rm "$SOURCE_LIST"
  fi

  return 0
}

getClient() {
  if command -v curl &>/dev/null; then
    CLIENT="curl"
  elif command -v wget &>/dev/null; then
    CLIENT="wget"
  elif command -v http &>/dev/null; then
    CLIENT="httpie"
  else
    echo -e "${CRED}This tool requires either curl, wget or httpie to be installed.${CEND}" >&2
    return 1
  fi
}

httpGet() {
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    AUTHORIZATION='{"Authorization": "Bearer '"$GITHUB_TOKEN"'}"}'
  fi

  case "$CLIENT" in
  curl) curl -A curl -s -H "$AUTHORIZATION" "$@" ;;
  wget) wget -qO- --header="$AUTHORIZATION" "$@" ;;
  httpie) http -b GET "$@" "$AUTHORIZATION" ;;
  esac
}

########
# Init #
########

# Display execution time and clean up on exit
trap cleanup 0 1 2 3 6 15

# Clean up on execution
cleanup

if [ -f "$LOG_FILE" ]; then
  rm "$LOG_FILE"
fi

# Create working directory
[ ! -d "$WORK_DIR" ] && mkdir -p "$WORK_DIR"

# Check if working directory was created
if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
  echo -e "${CRED}Could not create temp directory $WORK_DIR${CEND}"
  exit 1
fi

if [ -z "$CLIENT" ]; then
  getClient || exit 1
fi

###################
# Integrity check #
###################

if [ -z "$VERIFY_SIGNATURE" ] && [ -f "$0" ]; then
  sigCleanup() {
    if [ -f "$SIGNATURE_FILE" ]; then
      rm "$SIGNATURE_FILE"
    fi

    if [ -f "$PUBLIC_KEY_FILE" ]; then
      rm "$PUBLIC_KEY_FILE"
    fi
  }

  # Install OpenSSL, if it's not already installed
  if ! command_exists openssl; then
    apt-get update && apt-get install -qq openssl >/dev/null 2>&1
  fi

  if {
    httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/imei.sh.sig" >"$SIGNATURE_FILE"

    if [ ! -f "$PUBLIC_KEY_FILE" ]; then
      httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/public.pem" >"$PUBLIC_KEY_FILE"
    fi

    openssl dgst -sha512 -verify "$PUBLIC_KEY_FILE" -signature "$SIGNATURE_FILE" "$0"
  } >>"$LOG_FILE" 2>&1; then
    sigCleanup

    echo -ne "\ec"
  else
    sigCleanup

    echo -ne "\ec"

    echo -e " ${CRED}Signature verification failed!${CEND}"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    exit 1
  fi
fi

##################
# Version checks #
##################

if [ -f "$0" ]; then
  INSTALLER_VER=$(grep -oP 'Version\s+:\s+\K([\d\.]+)' "$0")
  INSTALLER_LATEST_VER=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/imei.sh" | grep -oP 'Version\s+:\s+\K([\d\.]+)')
fi

if [ -z "$IMAGEMAGICK_VER" ]; then
  IMAGEMAGICK_VER=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/imagemagick.version")
  IMAGEMAGICK_HASH=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/imagemagick.hash")
fi

if [ -z "$AOM_VER" ]; then
  AOM_VER=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/aom.version")
  AOM_HASH=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/aom.hash")
fi

if [ -z "$LIBHEIF_VER" ]; then
  LIBHEIF_VER=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/libheif.version")
  LIBHEIF_HASH=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/libheif.hash")
fi

if [ -z "$JXL_VER" ]; then
  JXL_VER=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/jpeg-xl.version")
  JXL_HASH=$(httpGet "https://raw.githubusercontent.com/SoftCreatR/imei/main/versions/jpeg-xl.hash")
fi

# Make sure, that a version number for ImageMagick has been set
if [ -z "$IMAGEMAGICK_VER" ]; then
  echo -e "${CRED}Unable to determine version number for ImageMagick${CEND}"

  exit 1
fi

# Make sure, that a version number for aom has been set
if [ -z "$AOM_VER" ]; then
  echo -e "${CRED}Unable to determine version number for aom${CEND}"

  exit 1
fi

# Make sure, that a version number for libheif has been set
if [ -z "$LIBHEIF_VER" ]; then
  echo -e "${CRED}Unable to determine version number for libheif${CEND}"

  exit 1
fi

# Make sure, that a version number for JPEG XL has been set
if [ -z "$JXL_VER" ]; then
  echo -e "${CRED}Unable to determine version number for JPEG XL${CEND}"

  exit 1
fi

if command_exists magick; then
  INSTALLED_IMAGEMAGICK_VER=$(magick -version | grep -oP 'Version: ImageMagick \K([\d\.\-]+)')
fi

if [ -L "$LIB_DIR/lib/libaom.so" ]; then
  INSTALLED_AOM_VER=$(readlink -f "$LIB_DIR/lib/libaom.so" | xargs basename | grep -oP 'libaom.so.\K([\d\.]+)')
fi

if [ -L "$LIB_DIR/lib/libheif.so" ]; then
  INSTALLED_LIBHEIF_VER=$(readlink -f "$LIB_DIR/lib/libheif.so" | xargs basename | grep -oP 'libheif.so.\K([\d\.]+)')
fi

if [ -L "$LIB_DIR/lib/libjxl.so" ]; then
  INSTALLED_JXL_VER=$(readlink -f "$LIB_DIR/lib/libjxl.so" | xargs basename | grep -oP 'libjxl.so.\K([\d\.]+)')
fi

#######################
# Installer functions #
#######################

# Speed up the compilation process
NUM_CORES=$(nproc || echo 1)
export CC=gcc CXX=g++ MAKEFLAGS="-j$((NUM_CORES + 1)) -l${NUM_CORES}"

# Build dependencies
install_deps() {
  echo -ne ' Installing dependencies       [..]\r'

  if [ -n "$SKIP_DEPS" ]; then
    echo -ne " Installing dependencies       [${CYELLOW}SKIPPED${CEND}]\\r"
    echo ""

    return
  fi

  if {
    if [ -f "$SOURCE_LIST" ]; then
      rm "$SOURCE_LIST"
    fi

    # Allow installation of source files
    {
      if [[ "${OS_DISTRO,,}" == *"ubuntu"* ]]; then
        echo 'deb http://archive.ubuntu.com/ubuntu '"$OS_SHORT_CODENAME"' main restricted'
        echo 'deb-src http://archive.ubuntu.com/ubuntu '"$OS_SHORT_CODENAME"' main restricted universe multiverse'
      elif [[ "${OS_DISTRO,,}" == *"debian"* ]]; then
        echo 'deb http://deb.debian.org/debian '"$OS_SHORT_CODENAME"' main contrib non-free'
        echo 'deb-src http://deb.debian.org/debian '"$OS_SHORT_CODENAME"' main contrib non-free'
      elif [[ "${OS_DISTRO,,}" == *"raspbian"* ]]; then
        echo 'deb http://archive.raspbian.org/raspbian '"$OS_SHORT_CODENAME"' main contrib non-free'
        echo 'deb-src http://archive.raspbian.org/raspbian '"$OS_SHORT_CODENAME"' main contrib non-free'
      else
        SKIP_BUILD_DEP="yes"
      fi
    } >>"$SOURCE_LIST"

    # Update package list and satisfy build dependencies for imagemagick
    if [ -n "$SKIP_BUILD_DEP" ]; then
      apt-get update -qq &&
      apt-get build-dep -qq imagemagick -y
    elif [ -z "$CI_BUILD" ]; then
      apt-get update -qq
    fi

    # Install other build dependencies
    PKG_LIST=(git curl make cmake automake libtool yasm g++ pkg-config perl libde265-dev libx265-dev libltdl-dev libopenjp2-7-dev liblcms2-dev libbrotli-dev libzip-dev libbz2-dev liblqr-1-0-dev libzstd-dev libgif-dev libjpeg-dev libopenexr-dev libpng-dev libwebp-dev librsvg2-dev libwmf-dev libxml2-dev libtiff-dev libraw-dev ghostscript gsfonts ffmpeg libpango1.0-dev libdjvulibre-dev libfftw3-dev libgs-dev libgraphviz-dev libjemalloc-dev)

    if [[ "${OS_SHORT_CODENAME,,}" != *"stretch"* && "${OS_SHORT_CODENAME,,}" != *"xenial"* ]]; then
      PKG_LIST+=(libraqm-dev libraqm0)
    fi

    apt-get install -y "${PKG_LIST[@]}"

    CMAKE_VERSION=$(cmake --version | head -n1 | cut -d" " -f3)
  } >>"$LOG_FILE" 2>&1; then
    echo -ne " Installing dependencies       [${CGREEN}OK${CEND}]\\r"
    echo ""
  else
    echo -ne " Installing dependencies       [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""

    exit 1
  fi
}

# Build aom
install_aom() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building aom                  [..]\r'

    if [ "$(version "$CMAKE_VERSION")" -lt "$(version 3.6)" ]; then
        echo -ne " Building aom                  [${CYELLOW}SKIPPED (CMAKE version not sufficient)${CEND}]\\r"
        echo ""

        return
    fi

    if [ -z "$SKIP_AOM" ]; then
      if [ -z "$FORCE" ] && [ -n "$INSTALLED_AOM_VER" ] && [ "$(version "$INSTALLED_AOM_VER")" -ge "$(version "$AOM_VER")" ]; then
        echo -ne " Building aom                  [${CYELLOW}SKIPPED${CEND}]\\r"
        echo ""

        return
      fi
    else
      echo -ne " Building aom                  [${CYELLOW}SKIPPED${CEND}]\\r"
      echo ""

      return
    fi

    {
      if [ -n "$AOM_VER" ]; then
        httpGet "$GH_FILE_BASE/jbeich/aom/tar.gz/v$AOM_VER" >"aom-$AOM_VER.tar.gz"

        if [ -n "$AOM_HASH" ]; then
          if [ "$(sha1sum "aom-$AOM_VER.tar.gz" | cut -b-40)" != "$AOM_HASH" ]; then
            echo -ne " Building aom                  [${CRED}FAILURE${CEND}]\\r"
            echo ""
            echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
            echo ""
          fi
        fi

        # see https://github.com/SoftCreatR/imei/issues/9
        CMAKE_FLAGS="-DBUILD_SHARED_LIBS=1"

        if [[ "${OS_DISTRO,,}" == *"raspbian"* ]]; then
          CMAKE_FLAGS+=' -DCMAKE_C_FLAGS="-mfloat-abi=hard -march=armv7-a -marm -mfpu=neon"'
        fi

        tar -xf "aom-$AOM_VER.tar.gz" &&
          mkdir "$WORK_DIR/build_aom" &&
          cd "$WORK_DIR/build_aom" &&
          cmake "../aom-$AOM_VER/" "$CMAKE_FLAGS" &&
          make &&
          make install &&
          ldconfig
      fi
    } >>"$LOG_FILE" 2>&1
  }; then
    UPDATE_LIBHEIF="yes"

    echo -ne " Building aom                  [${CGREEN}OK${CEND}]\\r"
    echo ""
  else
    echo -ne " Building aom                  [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""

    exit 1
  fi
}

# Build libheif
install_libheif() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building libheif              [..]\r'

    if [ ! -L "$LIB_DIR/lib/libaom.so" ]; then
        echo -ne " Building libheif              [${CYELLOW}SKIPPED (aom is required but not installed)${CEND}]\\r"
        echo ""

        return
    fi

    if [ -z "$SKIP_LIBHEIF" ]; then
      if [ -z "$FORCE" ] && [ -z "$UPDATE_LIBHEIF" ] && [ -n "$INSTALLED_LIBHEIF_VER" ] && [ "$(version "$INSTALLED_LIBHEIF_VER")" -ge "$(version "$LIBHEIF_VER")" ]; then
        echo -ne " Building libheif              [${CYELLOW}SKIPPED${CEND}]\\r"
        echo ""

        return
      fi
    else
      echo -ne " Building libheif              [${CYELLOW}SKIPPED${CEND}]\\r"
      echo ""

      return
    fi

    {
      if [ -n "$LIBHEIF_VER" ]; then
        httpGet "$GH_FILE_BASE/strukturag/libheif/tar.gz/v$LIBHEIF_VER" > "libheif-$LIBHEIF_VER.tar.gz"

        if [ -n "$LIBHEIF_HASH" ]; then
          if [ "$(sha1sum "libheif-$LIBHEIF_VER.tar.gz" | cut -b-40)" != "$LIBHEIF_HASH" ]; then
            echo -e " Building libheif              [${CRED}FAILURE${CEND}]\\r"
            echo ""
            echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
            echo ""
          fi
        fi

        tar -xf "libheif-$LIBHEIF_VER.tar.gz" &&
          cd "libheif-$LIBHEIF_VER" &&
          ./autogen.sh &&
          ./configure &&
          make &&
          make install &&
          ldconfig
      fi
    } >>"$LOG_FILE" 2>&1
  }; then
    UPDATE_IMAGEMAGICK="yes"

    echo -ne " Building libheif              [${CGREEN}OK${CEND}]\\r"
    echo ""
  else
    echo -e " Building libheif              [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""

    exit 1
  fi
}

# Build JPEG XL
install_jxl() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building jpegxl               [..]\r'

    if [ "$(version "$CMAKE_VERSION")" -lt "$(version 3.10)" ]; then
        echo -ne " Building jpegxl               [${CYELLOW}SKIPPED (CMAKE version not sufficient)${CEND}]\\r"
        echo ""

        return
    fi

    if [ -z "$SKIP_JXL" ]; then
      if [ -z "$FORCE" ] && [ -z "$UPDATE_LIBHEIF" ] && [ -n "$INSTALLED_JXL_VER" ] && [ "$(version "$INSTALLED_JXL_VER")" -ge "$(version "$JXL_VER")" ]; then
        echo -ne " Building jpegxl               [${CYELLOW}SKIPPED${CEND}]\\r"
        echo ""

        return
      fi
    else
      echo -ne " Building jpegxl               [${CYELLOW}SKIPPED${CEND}]\\r"
      echo ""

      return
    fi

    {
      if [ -n "$JXL_VER" ]; then
        httpGet "https://gitlab.com/wg1/jpeg-xl/-/archive/v$JXL_VER/jpeg-xl-v$JXL_VER.tar" > "jpeg-xl-v$JXL_VER.tar"

        if [ -n "$JXL_HASH" ]; then
          if [ "$(sha1sum "jpeg-xl-v$JXL_VER.tar" | cut -b-40)" != "$JXL_HASH" ]; then
            echo -e " Building jpegxl               [${CRED}FAILURE${CEND}]\\r"
            echo ""
            echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
            echo ""
          fi
        fi

        tar -xf "jpeg-xl-v$JXL_VER.tar" &&
          cd "jpeg-xl-v$JXL_VER" &&
          ./deps.sh &&
          mkdir "build" &&
          cd "build" &&
          cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF ..
          make &&
          make install &&
          ldconfig
      fi
    } >>"$LOG_FILE" 2>&1
  }; then
    UPDATE_IMAGEMAGICK="yes"

    echo -ne " Building jpegxl               [${CGREEN}OK${CEND}]\\r"
    echo ""
  else
    echo -e " Building jpegxl               [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""

    exit 1
  fi
}

# Build ImageMagick
install_imagemagick() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building ImageMagick          [..]\r'

    if [ -z "$FORCE" ] && [ -z "$UPDATE_IMAGEMAGICK" ] && [ -n "$INSTALLED_IMAGEMAGICK_VER" ] && [ "$(version "${INSTALLED_IMAGEMAGICK_VER//-/}")" -ge "$(version "${IMAGEMAGICK_VER//-/}")" ]; then
      echo -ne " Building ImageMagick          [${CYELLOW}SKIPPED${CEND}]\\r"
      echo ""

      return
    fi

    {
      if [ -n "$IMAGEMAGICK_VER" ]; then
        httpGet "$GH_FILE_BASE/ImageMagick/ImageMagick/tar.gz/$IMAGEMAGICK_VER" >"ImageMagick-$IMAGEMAGICK_VER.tar.gz"

        if [ -n "$IMAGEMAGICK_HASH" ]; then
          if [ "$(sha1sum "ImageMagick-$IMAGEMAGICK_VER.tar.gz" | cut -b-40)" != "$IMAGEMAGICK_HASH" ]; then
            echo -e " Building ImageMagick          [${CRED}FAILURE${CEND}]\\r"
            echo ""
            echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
            echo ""
          fi
        fi

        tar -xf "ImageMagick-$IMAGEMAGICK_VER.tar.gz" &&
          cd "ImageMagick-$IMAGEMAGICK_VER" &&
          ./configure --prefix="$BUILD_DIR" \
            CFLAGS="-O3 -march=native" \
            CXXFLAGS="-O3 -march=native" \
            --disable-static \
            --enable-shared \
            --enable-openmp \
            --enable-opencl \
            --enable-cipher \
            --enable-hdri \
            --enable-docs \
            --with-threads \
            --with-modules \
            --with-quantum-depth="32" \
            --with-magick-plus-plus \
            --with-perl \
            --with-jemalloc \
            --without-tcmalloc \
            --without-umem \
            --without-autotrace \
            --with-bzlib \
            --with-x \
            --with-zlib \
            --with-zstd \
            --without-dps \
            --with-fftw \
            --without-flif \
            --without-fpx \
            --with-djvu \
            --with-fontconfig \
            --with-freetype \
            --with-raqm \
            --with-gslib \
            --with-gvc \
            --with-heic \
            --with-jbig \
            --with-jpeg \
            --with-jxl=yes \
            --with-lcms \
            --with-openjp2 \
            --with-lqr \
            --with-lzma \
            --with-openexr \
            --with-pango \
            --with-png \
            --with-raw \
            --with-rsvg \
            --with-tiff \
            --with-webp \
            --with-wmf \
            --with-xml \
            --with-dejavu-font-dir='/usr/share/fonts/truetype/ttf-dejavu' \
            --with-gs-font-dir='/usr/share/fonts/type1/gsfonts' \
            --with-urw-base35-font-dir='/usr/share/fonts/type1/urw-base35' \
            --with-fontpath='/usr/share/fonts/type1' \
            PSDelegate='/usr/bin/gs' &&
          make &&
          make install &&
          ldconfig
      fi
    } >>"$LOG_FILE" 2>&1
  }; then
    echo -ne " Building ImageMagick          [${CGREEN}OK${CEND}]\\r"
    echo ""
  else
    echo -e " Building ImageMagick          [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""

    exit 1
  fi
}

finish_installation() {
  echo -ne ' Verifying installation        [..]\r'

  # Check if ImageMagick version matches
  {
    VERIFY_INSTALLATION=$("$BUILD_DIR/bin/magick" -version | grep -oP "$IMAGEMAGICK_VER")
  } >>"$LOG_FILE" 2>&1

  if [ -n "$VERIFY_INSTALLATION" ]; then
    echo -ne " Verifying installation        [${CGREEN}OK${CEND}]\\r"
    echo ""
    echo -e " ${CGREEN}Process has been finished successfully after $(displaytime $(($(date +%s) - START)))!${CEND}"
    echo ""
  else
    echo -ne " Verifying installation        [${CRED}FAILURE${CEND}]\\r"
    echo ""
    echo -e " ${CBLUE}Please check $LOG_FILE for details.${CEND}"
    echo ""
  fi
}

######################
# Install everything #
######################

echo -ne "\ec"

WELCOME_TXT="Welcome to IMEI - ImageMagick Easy Install ${INSTALLER_VER}"
WELCOME_LEN=${#WELCOME_TXT}

echo ""
echo " $(str_repeat "$WELCOME_LEN" "#")"
echo " $WELCOME_TXT"
echo " $(str_repeat "$WELCOME_LEN" "#")"
echo ""

if [ -z "$CI_BUILD" ] && [ -n "$INSTALLER_VER" ] && [ "$(version "$INSTALLER_VER")" -lt "$(version "$INSTALLER_LATEST_VER")" ]; then
  echo -e " ${CYELLOW}A newer installer version ($INSTALLER_LATEST_VER) is available!${CEND}"
  echo ""
fi

echo " Detected OS     : $OS_DISTRO"
echo " Detected Arch   : $OS_ARCH"
echo " Detected Cores  : $NUM_CORES"
echo ""
echo " Used web client : $CLIENT"
echo ""
echo " Work Dir        : $WORK_DIR"
echo " Build Dir       : $BUILD_DIR"
echo " Log File        : $LOG_FILE"
echo ""
echo " Force Build     : ${FORCE:-"no"}"
echo " CI Build        : ${CI_BUILD:-"no"}"
echo " Signature Check : ${VERIFY_SIGNATURE:-"yes"}"
echo ""

echo " #####################"
echo " Installation Process"
echo " #####################"
echo ""

# Run installer functions
install_deps
install_aom
install_libheif
install_jxl
install_imagemagick
finish_installation

exit 0

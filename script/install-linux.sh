#!/bin/bash

PASSKEEZ_VERSION="0.5.3"
ZIGENITY_VERSION="0.5.0"
ZIG_VERSION="0.14.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ARCH=$(uname -m)

debian_dependencies=(
    curl
)

arches=(
    x86_64
    aarch64
)

function get_package_manager {
    declare -A osInfo;
    osInfo[/etc/redhat-release]=yum
    osInfo[/etc/arch-release]=pacman
    osInfo[/etc/gentoo-release]=emerge
    osInfo[/etc/SuSE-release]=zypp
    osInfo[/etc/debian_version]=apt-get
    osInfo[/etc/alpine-release]=apk

    for f in ${!osInfo[@]}
    do
        if [[ -f $f ]];then
            echo ${osInfo[$f]}
            break
        fi
    done
}

function download_zig {
    cd /tmp
    sub=$(ls | grep "zig-")

    curl -# -C - -o "zig.tar.xz" "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz"
    tar -xf "zig.tar.xz"
    sub=$(ls | grep "zig-")

    zig="$sub/zig"
    echo ${zig}
}

# Verify that all dependencies are met
function check_dependencies {
    case $1 in
        apt-get) 
            for i in "${debian_dependencies[@]}"; do
                if ! command -v "$i" &> /dev/null
                then
                    apt-get install -y "$i"
                fi
            done
            ;;
        *)
            echo -e "${RED}Unknown package manager $1${NC}" 
            echo "Please make sure that the following dependencies are met:"
            echo "    * curl"
            ;;
    esac

    echo -e "${GREEN}Ok${NC}"
}

function install_passkeez {
    #curl -L -# -C - -o "/usr/local/bin/passkeez" "https://github.com/r4gus/keypass/releases/download/$PASSKEEZ_VERSION/passkeez-linux-$ARCH-$PASSKEEZ_VERSION"
    #chmod +x /usr/local/bin/passkeez
    cd /tmp

    # Install the application
    if [ ! -d "./PassKeeZ" ]; then
        git clone https://github.com/Zig-Sec/PassKeeZ --branch $PASSKEEZ_VERSION
    fi
    cd PassKeeZ
    ../$1 build -Doptimize=ReleaseSmall
    cp zig-out/bin/passkeez /usr/local/bin/passkeez
 
    # Install the static files 
    #mkdir -p /usr/share/passkeez
    #cp src/static/*.png /usr/share/passkeez/

    # So we can do the following
    # systemctl --user enable passkeez.service
    # systemctl --user start passkeez.service
    # systemctl --user stop passkeez.service
    # systemctl --user status passkeez.service
    #cp script/passkeez.service /etc/systemd/user/passkeez.service
    mkdir -p /home/${SUDO_USER}/.local/share/systemd/user
    curl -L -# -C - -o "/home/${SUDO_USER}/.local/share/systemd/user/passkeez.service" "https://raw.githubusercontent.com/r4gus/keypass/refs/heads/master/script/passkeez.service"
}

function install_zigenity {
    #curl -L -# -C - -o "/usr/local/bin/zigenity" "https://github.com/r4gus/keypass/releases/download/$PASSKEEZ_VERSION/zigenity-linux-$ARCH-$PASSKEEZ_VERSION"
    #chmod +x /usr/local/bin/zigenity

    cd /tmp

    if [ ! -d "./zigenity" ]; then
        git clone https://github.com/r4gus/zigenity --branch $ZIGENITY_VERSION
    fi

    cd zigenity
    ../$1 build -Doptimize=ReleaseSmall
    cp zig-out/bin/zigenity /usr/local/bin/zigenity
}

function check_config_folder {
    # This is where all configuration files will live
    if [ ! -d /home/${SUDO_USER}/.passkeez ]; then
        sudo -E -u $SUDO_USER mkdir /home/${SUDO_USER}/.passkeez
        sudo chown ${SUDO_USER}:${SUDO_USER} /home/${SUDO_USER}/.passkeez
    fi

    if [ ! -e /home/${SUDO_USER}/.passkeez/config.json ]; then 
        echo '{"db_path":"~/.passkeez/db.kdbx", "lang":"english"}' > /home/${SUDO_USER}/.passkeez/config.json
        sudo chown ${SUDO_USER}:${SUDO_USER} /home/${SUDO_USER}/.passkeez/config.json
    fi
}

function postinst {
    # Create a new group called fido
    getent group fido || (groupadd fido && usermod -a -G fido $SUDO_USER)

    # Add uhid to the list of modules to load during boot
    echo "uhid" > /etc/modules-load.d/fido.conf

    # Create a udev rule that allows all users that belong to the group fido to access /dev/uhid
    echo 'KERNEL=="uhid", GROUP="fido", MODE="0660"' > /etc/udev/rules.d/90-uinput.rules
    udevadm control --reload-rules && udevadm trigger
}

MODE="Installer"

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--uninstall)
            MODE="Uninstaller"
            shift
            ;;
        --vpasskeez)
            PASSKEEZ_VERSION="$2"
            shift
            shift
            ;;
        --vzig)
            ZIG_VERSION="$2"
            shift
            shift
            ;;
        --vzigenity)
            ZIGENITY_VERSION="$2"
            shift
            shift
            ;;
        -h|--help)
            echo "usage: install-linux.sh [Option...]"
            echo "  -u|--uninstall        uninstall PassKeeZ"
            echo "  --vpasskeez           define the PassKeeZ version to install"
            echo "  --vzigenity           define the zigenity version to install"
            echo "  --vzig                define the Zig version to use for installation"
            echo "  -h|--help             display this help message"
            exit 1
            ;;
        -*|--*)
            echo -e "{RED}Unknown option{NC} $1"  
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Exit immediately if any command returns a non-zero exit status
set -e

echo '______              _   __           ______'
echo '| ___ \            | | / /          |___  /'
echo '| |_/ /_ _ ___ ___ | |/ /  ___  ___    / /'
echo '|  __/ _` / __/ __||    \ / _ \/ _ \  / /'
echo '| | | (_| \__ \__ \| |\  \  __/  __/./ /___'
echo "\_|  \__,_|___/___/\_| \_/\___|\___|\_____/ v$PASSKEEZ_VERSION"
echo -e "${GREEN}PassKeeZ ${MODE}${NC}"
echo "------------------"

if [ ! `id -u` = 0 ]; then
    echo -e "${YELLOW}please run script with sudo${NC}"
    exit 1
fi

# First we make sure that all dependencies are met
PKG=$(get_package_manager)

echo "Architecture:    ${ARCH}"
echo "Package manager: ${PKG}"

echo "Stopping PassKeeZ service..."
systemctl --user --machine=${SUDO_USER}@ stop passkeez.service || true
echo "Disabling PassKeeZ service..."
systemctl --user --machine=${SUDO_USER}@ disable passkeez.service || true

if [ "$MODE" = "Installer" ]; then
    echo "Checking dependencies... "
    check_dependencies $PKG $ARCH

    echo "Downloading Zig..."
    zig=$(download_zig)
    echo -e "${GREEN}OK${NC}"

    echo "Installing PassKeeZ... "
    install_passkeez $zig
    echo -e "${GREEN}OK${NC}"

    echo "Installing zigenity... "
    install_zigenity $zig
    echo -e "${GREEN}OK${NC}"

    echo "Checking configuration folder... "
    check_config_folder
    echo -e "${GREEN}OK${NC}"

    echo "Configuring... "
    postinst
    echo -e "${GREEN}OK${NC}"

    echo "Enabling PassKeeZ service..."
    systemctl --user --machine=${SUDO_USER}@ enable passkeez.service || true
    echo "Starting PassKeeZ service..."
    systemctl --user --machine=${SUDO_USER}@ start passkeez.service || true
    systemctl --user --machine=${SUDO_USER}@ status --no-pager passkeez.service || true

    echo -e "${GREEN}PassKeeZ installed successfully.${NC}"
    echo "To enable PassKeeZ permanently you can run the following commands:"
    echo -e "    ${YELLOW}systemctl --user enable passkeez.service${NC}"
    echo -e "    ${YELLOW}systemctl --user start passkeez.service${NC}"
    echo "To stop PassKeeZ run:"
    echo -e "    ${YELLOW}systemctl --user stop passkeez.service${NC}"
    echo "To disable PassKeeZ run:"
    echo -e "    ${YELLOW}systemctl --user disable passkeez.service${NC}"
    echo "For further details visit https://github.com/Zig-Sec/PassKeeZ/wiki"
    echo -e "${YELLOW}If this is the first time running this script, please reboot...${NC}"
else
    echo "Uninstalling PassKeeZ..."
    echo -e "${YELLOW}removing${NC} passkeez"
    rm /usr/local/bin/passkeez
    echo -e "${YELLOW}removing${NC} passkeez.service"
    rm "/home/${SUDO_USER}/.local/share/systemd/user/passkeez.service"
    echo -e "${YELLOW}removing${NC} zigenity"
    rm /usr/local/bin/zigenity
    echo -e "${GREEN}uninstall successful${NC}"
fi

# Exit successfully
exit 0

#!/bin/bash

# This script installs the cloudwatch agent and configures with some generic
# defaults. The goal of the script is to be idempotent.

set -euo pipefail

AWS_DOWNLOAD_URL_PREFIX=https://s3.amazonaws.com/amazoncloudwatch-agent/
DOWNLOAD_FILE_PATH_PREFIX=/tmp/amazon-cloudwatch-agent

CWAGENT_INSTALL_DIR=/opt/aws/amazon-cloudwatch-agent
CWAGENT_CTL=${CWAGENT_INSTALL_DIR}/bin/amazon-cloudwatch-agent-ctl
CWAGENT_BIN=${CWAGENT_INSTALL_DIR}/bin/amazon-cloudwatch-agent
DEFAULT_CONFIG_FILE=/opt/aws/amazon-cloudwatch-agent/config.json

CWAGENT_MODE=auto
CWAGENT_CONFIG=file:${DEFAULT_CONFIG_FILE}
START_AGENT=true

# set default recommended config
CWAGENT_CONFIG_CONTENTS=$(cat << 'EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "cpu": {
        "measurement": [
          "cpu_usage_idle",
          "cpu_usage_iowait",
          "cpu_usage_user",
          "cpu_usage_system"
        ],
        "metrics_collection_interval": 60,
        "resources": ["*"],
        "totalcpu": false
      },
      "disk": {
        "measurement": ["used_percent", "inodes_free"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "diskio": {
        "measurement": ["io_time"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF
)


check_if_root () {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: $0 script requires root privileges"
        exit 1
    fi
}

cleanup () {
    rm "${DOWNLOAD_FILE_PATH_PREFIX}"*
}

download_installer () {
    local os=$1
    local arch=$2
    local pkg_type=$3

    local source="${AWS_DOWNLOAD_URL_PREFIX}${os}/${arch}/latest/amazon-cloudwatch-agent.${pkg_type}"
    local destination="${DOWNLOAD_FILE_PATH_PREFIX}.${pkg_type}"

    if command -v curl &> /dev/null; then
        curl -o "${destination}" "${source}"
    elif command -v wget &> /dev/null; then
        wget -O "${destination}" "${source}"
    else
        echo "ERROR: no suitable download utility. Install either wget or curl"
        exit 2
    fi
}

install_centos () {
    download_installer centos amd64 rpm
    rpm -U "${DOWNLOAD_FILE_PATH_PREFIX}.rpm"
}

install_by_os () {
    if ! [[ -x ${CWAGENT_BIN} ]]; then
        local os_name=$(grep "NAME=" /etc/os-release | awk -F '=' '{print $2}')
        case $os_name in
            *CentOS* )
                install_centos
                ;;
        esac
    else
        echo "amazon-cloudwatch-agent is already installed"
    fi

    # validate that the installed files exist
    if ! [[ -d ${CWAGENT_INSTALL_DIR} ]]; then
        echo "ERROR: /opt/aws/amazon-cloudwatch-agent directory does not exist after install, something went wrong"
    fi

    # write config file
    echo "writing new config file"
    echo "${CWAGENT_CONFIG_CONTENTS}" > "${DEFAULT_CONFIG_FILE}"

    echo "appending config to cloudwatch agent"
    $CWAGENT_CTL -a fetch-config -m "${CWAGENT_MODE}" -c "${CWAGENT_CONFIG}" -s

    # start the agent
    if [[ $START_AGENT == true ]]; then
        echo "starting agent"
        $CWAGENT_CTL -a start -m "${CWAGENT_MODE}"
    fi
}

usage () {
    echo "Usage: $0 [-h] [-m <mode>] [-c <config type>] [-f <file>]"
    echo ""
    echo "Options:"
    echo "  -h           display help"
    echo "  -d           disables starting the agent"
    echo "  -m <mode>    cloudwatch agent mode to use when starting the agent"
    echo "               defaults to auto"
    echo "  -c <config>  cloudwatch agent config to use when starting the agent"
    echo "               defaults to file:${DEFAULT_CONFIG_FILE}"
    echo "  -f <file>    config file to override default config"
    echo ""
    exit
}


while getopts ":hdm:c:f:" opt; do
    case $opt in
        h)
            usage
            ;;
        d)
            START_AGENT=false
            ;;
        m)
            CWAGENT_MODE="$OPTARG"
            ;;
        c)
            CWAGENT_CONFIG="$OPTARG"
            ;;
        f)
            if [[ -r $OPTARG ]]; then
                CWAGENT_CONFIG_CONTENTS="$(cat "$OPTARG")"
            else
                echo "Invalid filename supplied, no such file"
                exit 1
            fi
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done

check_if_root
trap "cleanup" ERR
install_by_os

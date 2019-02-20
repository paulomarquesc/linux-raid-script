#!/bin/bash

# This is a sample script that adds data disks (managed disk) to a list of VMs from the same resource group.
#
# Requirements
#   - Azure CLI 2.0 or greater is required in order to run this script
#   - jq
#
# Config File Format (semicolon separated)
#
#    <Azure VM Name>;<# of disks>;<disk size in GB>;<disk type>
# 
#    E.g.
#       vm01;3;1024;Premium_LRS
#       vm02;2;512;Premium_LRS
# 
# Output:
# 
#   detached_managed_disks_list.txt - List of managed disks that are detached from VMs (if there are already data disks attached) 
#                                     for further analysis and to be used for deletion after decided there is nothing valuable there
#
# Notes:
#    - It will compare the number of disks from the configuration file with the ones attached to the VMs, it will add missing disks,
#      resize existing data disks according to configuration file.
#    - This script does not shutdown VMs, all VMs must be manually shutdown prior to script execution  

set -e

CONFIG_FILE="configfile.txt"
RESOURCE_GROUP=""

usage()
{
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo "    -g <RESOURCE_GROUP>       [Required]: Name of resource group where the VMs are located."
    echo "    -c <CONFIG_FILE>          Configuration file path and name, it will default to ./configfile.txt if this parameter is not defined."
    echo
    echo "Example:"
    echo
    echo "   Adds data disks based on configuration file called configfile.txt located at the same script folder."
    echo "      $0 -g myResourceGroup"
    echo
    echo "   Adds data disks based on configuration file called setupdatadisks.txt located in another folder."
    echo "      $0 -g myResourceGroup -c /home/testuser/setupdatadisks.txt"
    echo

}

while getopts "g:c:" opt; do
    case ${opt} in
        # Set resource group
        g )
            RESOURCE_GROUP=$OPTARG
            echo "    Resource Group: $RESOURCE_GROUP"
            ;;
        # Set Configuration File
        c )
            CONFIG_FILE=$OPTARG
            echo "    Configuration file: $CONFIG_FILE"
            ;;
        # Catch call, return usage and exit
        h  ) usage; exit 0;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done
if [ $OPTIND -eq 1 ]; then echo; echo "No options were passed"; echo; usage; exit 1; fi
shift $((OPTIND -1))

# Functions

function random_string {
     # usage
    # randon_string <return variable> <length> [<chars to remove>]
    local _RESULT=$1

    eval $_RESULT=$(base64 /dev/urandom 2>/dev/null | tr -d "/+$3" 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null | dd bs="$2" count=1 2>/dev/null | xargs echo;)
}

function create_managed_disks {
    # parameters
    VM=$1
    RESOURCE_GROUP=$2
    DISK_QTY=$3
    DISK_SIZE_GB=$4
    DISK_TYPE=$5
    DISK_JSON_SERVICE_TAG=$6

    for (( i=0; i < $DISK_QTY; i++ ))
    {
        # Getting a random string
        random_string RANDOM_STR 7
        DATADISK_NAME="$VM-datadisk-$RANDOM_STR-$i"
        echo "Creating disk $DATADISK_NAME, size $DISK_SIZE_GB..."
        az vm disk attach --vm-name $VM --resource-group $RESOURCE_GROUP --disk $DATADISK_NAME --size-gb $DISK_SIZE_GB --sku $DISK_TYPE --new

        if [ ! $DISK_JSON_SERVICE_TAG = '{"Service":null}' ]; then
            echo "Adding Service Tag to disk..."
            echo "  Json Tag => $DISK_JSON_SERVICE_TAG"
            TAG=$(echo $DISK_JSON_SERVICE_TAG | tr -d '"{},' | sed 's/:/=/g')
            echo "  az Tag format => $TAG"
            az resource tag --tags $TAG -g $RESOURCE_GROUP -n $DATADISK_NAME --resource-type "Microsoft.Compute/disks"
        fi
    }
}


# Main
DETACHED_DISKS_FILENAME="detached_managed_disks_list.txt"

if [ ! -x "$(command -v jq)" ]; then
    echo "jq not installed, please install this package before proceeding"
    exit 1
fi

if [ ! -x "$(command -v az)" ]; then
    echo "Azure CLI 2.0 not installed, please install it before proceeding"
    exit 1
fi

# Rotating detached disk list
if [ -f "$DETACHED_DISKS_FILENAME" ]; then
    LATEST_FILE_VERSION=$(ls -la "$DETACHED_DISKS_FILENAME"* 2>/dev/null | tail -n 1 | awk -F. '{print $3}')
    if [ ! "$LATEST_FILE_VERSION" == "" ]; then
        LATEST_FILE_VERSION=$((LATEST_FILE_VERSION+1))
        mv "$DETACHED_DISKS_FILENAME" "$DETACHED_DISKS_FILENAME.$LATEST_FILE_VERSION"
    else
        mv "$DETACHED_DISKS_FILENAME" "$DETACHED_DISKS_FILENAME.1"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Required file $CONFIG_FILE could not be found!"
    exit 1
fi

OLD_IFS=$IFS
IFS=$'\n'
for LINE in $(cat $CONFIG_FILE); do
    if [ ! "${LINE:0:1}" == "#" ]; then

        # Converting line from config file into related variables
        IFS=';' read -ra LINE_ARR <<< "$LINE"
        VM=${LINE_ARR[0]}
        DISK_QTY=${LINE_ARR[1]}
        DISK_SIZE_GB=${LINE_ARR[2]}
        DISK_TYPE=${LINE_ARR[3]}

        echo "Config line content: VM=>$VM, DISK_QTY=>$DISK_QTY, DISK_SIZE_GB=>$DISK_SIZE_GB, DISK_TYPE=>$DISK_TYPE "

        echo "Getting VM information"
        VM_INFO=$(az vm show -n $VM -g $RESOURCE_GROUP)

        if  [ ! -z "$VM_INFO" ]; then
            #VM_STATE_INFO=$(az vm get-instance-view -n $VM -g $RESOURCE_GROUP)
            #VM_DEALLOCATED=$(echo $VM_STATE_INFO | jq '.instanceView.statuses[] | select(.code=="PowerState/deallocated")')
            echo "Getting VM Service Tag to apply to data disk..."
            JSON_SERVICE_TAG=$(echo $VM_INFO | jq -c '.tags | {Service:.Service}')

            echo "Getting number of data disks..."
            DATADISK_COUNT=$(echo $VM_INFO | jq '.storageProfile.dataDisks | length')

            echo "Creating managed disks..."

            # Checking which option to use
            if [ $DATADISK_COUNT -eq 0 ]; then
                echo "$VM - No disks attached..."
            else
                echo "$VM - One or more disks ($DATADISK_COUNT) already attached..."
                echo "Detaching disks before adding new ones..."

                # Creating array of disks to detach
                readarray -t DATADISKS_TO_DETACH < <( echo $VM_INFO | jq -c ".storageProfile.dataDisks | .[]" )
                for ITEM in "${DATADISKS_TO_DETACH[@]}"
                do
                    DISK_NAME=$(echo "${ITEM}" | jq -r .name)
                    echo $DISK_NAME >> $DETACHED_DISKS_FILENAME
                    az vm disk detach --resource-group $RESOURCE_GROUP --vm-name $VM --name $DISK_NAME
                done

            fi

            create_managed_disks $VM $RESOURCE_GROUP $DISK_QTY $DISK_SIZE_GB $DISK_TYPE $JSON_SERVICE_TAG

        else
            echo "$VM not found at resource group $RESOURCE_GROUP, skipping it..."
        fi
    fi
done
IFS=$OLD_IFS
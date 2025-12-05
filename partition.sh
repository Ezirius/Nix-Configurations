#!/usr/bin/env bash

# Partition disk for NixOS installation using disko
# Run this after clone.sh, before nixos-install
#
# Usage:
#   ./partition.sh [host]

set -euo pipefail

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "Run with: nix-shell -p bash --run './partition.sh'"
    exit 1
fi

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./partition.sh [host]

Partition disk for NixOS installation using disko.

Arguments:
  host    Target host configuration (optional, interactive if not provided)
          Available: Nithra

Options:
  -h, --help    Show this help message

This script:
  1. Reads disk device from Hosts/<host>/disko-config.nix
  2. Shows disk details and confirmation prompt
  3. Securely erases the disk (TRIM/discard)
  4. Prompts for LUKS passphrase (min 20 chars, 3+ character classes)
  5. Runs disko to partition and encrypt
  6. Copies sops-nix key to /mnt

WARNING: This permanently destroys all data on the target disk!

Prerequisites:
  - Must run from NixOS live installer
  - Run ./clone.sh first

Examples:
  ./partition.sh           # Interactive host selection
  ./partition.sh Nithra    # Partition for Nithra
EOF
    exit 0
fi

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# Only NixOS hosts with disko configs (Darwin uses native disk management)
KNOWN_HOSTS=("Nithra")

# Fail if not running from NixOS installer
CURRENT_HOST=$(hostname)
CURRENT_HOST="${CURRENT_HOST%.local}"  # Strip .local suffix (macOS)
if [[ "$CURRENT_HOST" != "nixos" ]]; then
    echo -e "${RED}>> Error: partition.sh must be run from NixOS live installer${NC}"
    echo "   Current hostname: $(hostname)"
    echo "   This script wipes disks and is only safe from a live ISO."
    exit 1
fi

# Determine target host
if [[ -n "${1:-}" ]]; then
    # Normalise to "Capitalised" format (e.g., "NITHRA" or "nithra" -> "Nithra")
    TARGET_HOST="${1,,}"
    TARGET_HOST="${TARGET_HOST^}"
    
    # Validate host argument
    VALID_ARG=false
    for host in "${KNOWN_HOSTS[@]}"; do
        if [[ "${host,,}" == "${TARGET_HOST,,}" ]]; then
            VALID_ARG=true
            break
        fi
    done
    if [[ "$VALID_ARG" != true ]]; then
        echo -e "${RED}>> Error: '${1}' is not a valid host${NC}"
        echo "   Available hosts: ${KNOWN_HOSTS[*]}"
        exit 1
    fi
elif [[ ! -t 0 ]]; then
    # Running from pipe - can't use interactive select
    echo -e "${RED}>> Error: No host specified and running non-interactively${NC}"
    echo "   Usage: ./partition.sh <host>"
    echo "   Available hosts: ${KNOWN_HOSTS[*]}"
    exit 1
else
    echo -e "${YELLOW}>> Select host to install:${NC}"
    select opt in "${KNOWN_HOSTS[@]}"; do
        if [[ -n "$opt" ]]; then
            TARGET_HOST="$opt"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done </dev/tty
fi

echo -e "${GREEN}>> Partition Setup (${TARGET_HOST})${NC}"

# Verify disko config exists
DISKO_CONFIG="${SCRIPT_DIR}/Hosts/${TARGET_HOST}/disko-config.nix"
if [[ ! -f "$DISKO_CONFIG" ]]; then
    echo -e "${RED}>> Error: Disko config not found: ${DISKO_CONFIG}${NC}"
    exit 1
fi

# Extract disk device from disko-config.nix
echo -e "${YELLOW}>> Reading disk configuration...${NC}"
SELECTED_DISK=$(grep -o 'device = "/dev/[^"]*"' "$DISKO_CONFIG" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [[ -z "$SELECTED_DISK" ]]; then
    echo -e "${RED}>> Error: Could not parse disk device from ${DISKO_CONFIG}${NC}"
    echo "   Expected 'device = \"/dev/xxx\";' in the file"
    exit 1
fi

echo -e "${GREEN}>> Disko configured for: ${SELECTED_DISK}${NC}"

# Verify disk exists
if [[ ! -b "$SELECTED_DISK" ]]; then
    echo -e "${RED}>> Error: Disk ${SELECTED_DISK} not found${NC}"
    echo ""
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | while read -r line; do
        echo "  $line"
    done
    echo ""
    echo "Update ${DISKO_CONFIG} with the correct device path."
    exit 1
fi

# Show disk details
SIZE=$(lsblk -dpno SIZE "$SELECTED_DISK" 2>/dev/null || echo "unknown")
MODEL=$(lsblk -dpno MODEL "$SELECTED_DISK" 2>/dev/null | xargs || echo "unknown")
echo ""
echo "Disk details:"
echo "  Device: ${SELECTED_DISK}"
echo "  Size:   ${SIZE}"
echo "  Model:  ${MODEL}"

# Show current partitions
PARTS=$(lsblk -pno NAME,SIZE,FSTYPE "$SELECTED_DISK" 2>/dev/null | tail -n +2 || true)
if [[ -n "$PARTS" ]]; then
    echo "  Current partitions:"
    echo "$PARTS" | while read -r line; do
        echo "    └─ $line"
    done
fi

echo ""
echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                        WARNING                                 ║${NC}"
echo -e "${RED}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║  This will PERMANENTLY DESTROY all data on:                    ║${NC}"
echo -e "${RED}║                                                                ║${NC}"
printf "${RED}║  %-62s║${NC}\n" "  ${SELECTED_DISK}"
echo -e "${RED}║                                                                ║${NC}"
echo -e "${RED}║  This action is IRREVERSIBLE.                                  ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Require explicit confirmation (risky operation - exact YES required)
echo -n "Type YES to proceed (YES/n): "
read -er CONFIRM < /dev/tty

if [[ "$CONFIRM" != "YES" ]]; then
    echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}>> Securely erasing ${SELECTED_DISK}...${NC}"
if sudo blkdiscard "$SELECTED_DISK" 2>/dev/null; then
    echo -e "${GREEN}>> SSD TRIM/discard complete${NC}"
else
    echo -e "${YELLOW}>> blkdiscard not supported (not an SSD or device doesn't support TRIM)${NC}"
fi

echo -e "${YELLOW}>> Wiping partition signatures on ${SELECTED_DISK}...${NC}"
sudo wipefs -a "$SELECTED_DISK"

echo ""
echo -e "${YELLOW}>> Enter LUKS passphrase for disk encryption:${NC}"
read -rs LUKS_PASS </dev/tty
echo
echo -e "${YELLOW}>> Confirm LUKS passphrase:${NC}"
read -rs LUKS_PASS_CONFIRM </dev/tty
echo

if [[ -z "$LUKS_PASS" ]]; then
    echo -e "${RED}>> Error: Passphrase cannot be empty${NC}"
    exit 1
fi

if [[ ${#LUKS_PASS} -lt 20 ]]; then
    echo -e "${RED}>> Error: Passphrase must be at least 20 characters${NC}"
    exit 1
fi

# Check for character diversity (at least 3 of 4 classes for better entropy)
CLASSES=0
[[ "$LUKS_PASS" =~ [a-z] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [A-Z] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [0-9] ]] && CLASSES=$((CLASSES + 1))
[[ "$LUKS_PASS" =~ [^a-zA-Z0-9] ]] && CLASSES=$((CLASSES + 1))

if [[ $CLASSES -lt 3 ]]; then
    echo -e "${RED}>> Error: Passphrase must contain at least 3 of: lowercase, uppercase, numbers, symbols${NC}"
    exit 1
fi

if [[ "$LUKS_PASS" != "$LUKS_PASS_CONFIRM" ]]; then
    echo -e "${RED}>> Passphrases do not match!${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}>> Running disko...${NC}"
echo ""

printf '%s\n%s\n' "$LUKS_PASS" "$LUKS_PASS" | sudo bash -c "nix --experimental-features 'nix-command flakes' run github:nix-community/disko -- --mode disko '$DISKO_CONFIG'"

unset LUKS_PASS LUKS_PASS_CONFIRM

echo ""
echo -e "${GREEN}>> Partitioning complete!${NC}"

# Copy sops-nix key to target system
SOPS_KEY_PATH="/tmp/sops-nix-key.txt"
if [[ -f "$SOPS_KEY_PATH" ]]; then
    echo ""
    echo -e "${YELLOW}>> Copying sops-nix key to target system...${NC}"
    sudo mkdir -p /mnt/var/lib/sops-nix
    sudo cp "$SOPS_KEY_PATH" /mnt/var/lib/sops-nix/key.txt
    sudo chmod 600 /mnt/var/lib/sops-nix/key.txt
    sudo chown root:root /mnt/var/lib/sops-nix/key.txt
    echo -e "${GREEN}>> Sops-nix key installed${NC}"
else
    echo ""
    echo -e "${YELLOW}>> Warning: Sops-nix key not found at ${SOPS_KEY_PATH}${NC}"
    echo "   You will need to copy it manually before installing:"
    echo "   sudo mkdir -p /mnt/var/lib/sops-nix"
    echo "   sudo cp <your-key-path> /mnt/var/lib/sops-nix/key.txt"
    echo "   sudo chmod 600 /mnt/var/lib/sops-nix/key.txt"
    echo "   sudo chown root:root /mnt/var/lib/sops-nix/key.txt"
fi

echo ""
echo "Next step:"
echo "  ./install.sh ${TARGET_HOST}"


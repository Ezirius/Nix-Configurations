#!/usr/bin/env bash

# Clone and set up Nix-Configurations repository
# Run this from a NixOS live installer or an installed system (NixOS/Darwin)
#
# Usage:
#   ./clone.sh [host]
#   curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash -s -- [host]

set -euo pipefail

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './clone.sh'"
    exit 1
fi

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./clone.sh [host]
       curl -sL <url>/clone.sh | bash -s -- [host]

Clone and set up the Nix-Configurations repository.

Arguments:
  host    Target host configuration (optional, interactive if not provided)
          Available: Nithra (NixOS), Maldoria (Darwin)

Options:
  -h, --help    Show this help message

This script:
  1. Clones the repository (or resets existing clone)
  2. Prompts for git-agecrypt key
  3. Prompts for sops-nix key
  4. Verifies keys match configuration
  5. Configures git-agecrypt filters
  6. Decrypts secrets

Examples:
  ./clone.sh                 # Interactive host selection
  ./clone.sh Nithra          # Set up for Nithra
  curl ... | bash -s -- Nithra   # Remote bootstrap
EOF
    exit 0
fi

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REPO_URL="https://github.com/ezirius/Nix-Configurations.git"
SSH_URL="git@github.com:ezirius/Nix-Configurations.git"
KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
PLATFORM=$(uname -s)

LINUX_HOSTS=("Nithra")
DARWIN_HOSTS=("Maldoria")

# Select hosts for current platform
if [[ "$PLATFORM" == "Darwin" ]]; then
    KNOWN_HOSTS=("${DARWIN_HOSTS[@]}")
else
    KNOWN_HOSTS=("${LINUX_HOSTS[@]}")
fi

# Function to run git commands (natively or via nix-shell)
run_git() {
    if command -v git &> /dev/null; then
        git "$@"
    else
        # Use printf %q for proper shell escaping
        local args
        args=$(printf '%q ' "$@")
        nix-shell -p git --run "git $args"
    fi
}

# Validate hostname early (before any prompts or actions)
CURRENT_HOST=$(hostname)
CURRENT_HOST="${CURRENT_HOST%.local}"  # Strip .local suffix (macOS)
CURRENT_HOST_LOWER="${CURRENT_HOST,,}"
VALID_HOST=false
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    VALID_HOST=true
else
    for host in "${KNOWN_HOSTS[@]}"; do
        if [[ "${host,,}" == "$CURRENT_HOST_LOWER" ]]; then
            VALID_HOST=true
            break
        fi
    done
fi
if [[ "$VALID_HOST" != true ]]; then
    echo -e "${RED}>> Error: Hostname '${CURRENT_HOST}' is not a supported host${NC}"
    echo "   Supported hosts: nixos (live ISO), ${KNOWN_HOSTS[*]}"
    exit 1
fi

# Check if running interactively (needed for prompts later)
# Allow non-interactive if host is specified as argument
if [[ ! -t 0 ]] && [[ -z "${1:-}" ]]; then
    echo -e "${RED}>> Error: No host specified and running non-interactively${NC}"
    echo "   Usage: curl ... | bash -s -- <host>"
    echo "   Available hosts: ${KNOWN_HOSTS[*]}"
    exit 1
fi

# Clone to /tmp on live ISO, permanent location on installed system
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    CLONE_DIR="/tmp/Nix-Configurations"
else
    CLONE_DIR="$HOME/Documents/Ezirius/Development/GitHub/Nix-Configurations"
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
        echo -e "${RED}>> Error: '${1}' is not a valid host for this platform${NC}"
        echo "   Available hosts: ${KNOWN_HOSTS[*]}"
        exit 1
    fi
elif [[ ${#KNOWN_HOSTS[@]} -eq 1 ]]; then
    # Only one host available for this platform - auto-select
    TARGET_HOST="${KNOWN_HOSTS[0]}"
    echo -e "${GREEN}>> Auto-selected host: ${TARGET_HOST}${NC}"
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

echo -e "${GREEN}>> Nix-Configurations Clone Setup (${TARGET_HOST})${NC}"

# Cleanup on error (not on Ctrl+C or success)
SCRIPT_SUCCESS=false
cleanup() {
    if [[ "$SCRIPT_SUCCESS" != true ]]; then
        echo -e "${RED}>> Setup failed. Partial state may remain at ${CLONE_DIR}${NC}"
    fi
}
trap cleanup EXIT
trap "exit 1" INT TERM

# Check network connectivity
echo -e "${YELLOW}>> Checking network...${NC}"
if ! curl -sI https://github.com --max-time 5 &>/dev/null; then
    echo -e "${RED}>> Error: Cannot reach github.com${NC}"
    echo "   Configure network first, then rerun this script"
    exit 1
fi

# Handle existing directory
if [ -d "$CLONE_DIR" ]; then
    if [ -d "$CLONE_DIR/.git" ]; then
        # Check if it's the correct remote
        CURRENT_REMOTE=$(cd "$CLONE_DIR" && run_git ls-remote --get-url origin 2>/dev/null || true)
        if [ "$CURRENT_REMOTE" = "$REPO_URL" ] || [ "$CURRENT_REMOTE" = "$SSH_URL" ]; then
            echo -e "${YELLOW}>> Repository exists, checking for local changes...${NC}"
            (cd "$CLONE_DIR" && run_git fetch origin)
            
            UNCOMMITTED=$(cd "$CLONE_DIR" && run_git status --porcelain || true)
            UNPUSHED=$(cd "$CLONE_DIR" && run_git rev-list origin/main..HEAD --count 2>/dev/null || echo "0")
            
            if [[ -n "$UNCOMMITTED" || "$UNPUSHED" -gt 0 ]]; then
                echo -e "${RED}>> Local changes detected:${NC}"
                [[ -n "$UNCOMMITTED" ]] && echo "   - Uncommitted changes"
                [[ "$UNPUSHED" -gt 0 ]] && echo "   - ${UNPUSHED} unpushed commit(s)"
                echo ""
                echo -n "Overwrite and lose all local changes? (y/n): "
                read -er CONFIRM < /dev/tty
                if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
                    echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
                    exit 0
                fi
            fi
            
            echo -e "${YELLOW}>> Resetting to origin/main...${NC}"
            (cd "$CLONE_DIR" && run_git reset --hard origin/main)
            # Note: Secrets will be decrypted later in the "Decrypting secrets" section
        else
            echo -e "${RED}>> Directory exists but has different remote${NC}"
            echo ""
            echo -n "Delete existing directory and re-clone? (y/n): "
            read -er CONFIRM < /dev/tty
            if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
                echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
                exit 0
            fi
            cd "$HOME"
            rm -rf "$CLONE_DIR"
            run_git clone "$REPO_URL" "$CLONE_DIR"
        fi
    else
        echo -e "${RED}>> Directory exists but is not a git repo${NC}"
        echo ""
        echo -n "Delete existing directory and re-clone? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted. No changes made.${NC}"
            exit 0
        fi
        cd "$HOME"
        rm -rf "$CLONE_DIR"
        run_git clone "$REPO_URL" "$CLONE_DIR"
    fi
else
    echo -e "${YELLOW}>> Cloning repository...${NC}"
    run_git clone "$REPO_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"

echo -e "${YELLOW}>> Working from: ${CLONE_DIR}${NC}"

# Switch remote to SSH on installed systems (not live ISO)
# HTTPS is used for initial clone (no SSH keys on live ISO), but SSH is needed for pushing
if [[ "$CURRENT_HOST_LOWER" != "nixos" ]]; then
    CURRENT_REMOTE=$(run_git ls-remote --get-url origin 2>/dev/null || true)
    if [[ "$CURRENT_REMOTE" == "$REPO_URL" ]]; then
        echo -e "${YELLOW}>> Switching remote from HTTPS to SSH...${NC}"
        run_git remote set-url origin "$SSH_URL"
        echo -e "${GREEN}>> Remote URL: ${SSH_URL}${NC}"
    elif [[ "$CURRENT_REMOTE" == "$SSH_URL" ]]; then
        echo -e "${GREEN}>> Remote already using SSH${NC}"
    fi
fi

# Set up git-agecrypt key
echo -e "${YELLOW}>> Setting up git-agecrypt key...${NC}"
mkdir -p "$(dirname "$KEY_PATH")"

if [ -f "$KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
    echo -e "${GREEN}>> git-agecrypt key already exists at ${KEY_PATH}${NC}"
else
    echo -e "${YELLOW}>> Paste your git-agecrypt age private key (starts with AGE-SECRET-KEY-):${NC}"
    read -er KEY_CONTENT </dev/tty
    if [[ -z "$KEY_CONTENT" ]]; then
        echo -e "${RED}>> Error: No key provided${NC}"
        exit 1
    fi
    if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
        echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
        exit 1
    fi
    (umask 077 && echo "$KEY_CONTENT" > "$KEY_PATH")
    unset KEY_CONTENT
fi

# Verify key matches git-agecrypt.toml
echo -e "${YELLOW}>> Verifying git-agecrypt key matches configuration...${NC}"
DERIVED_PUBKEY=$(nix-shell -p age --run "age-keygen -y '${KEY_PATH}'" 2>/dev/null || true)
if [[ -n "$DERIVED_PUBKEY" ]]; then
    TOML_FILE="${CLONE_DIR}/git-agecrypt.toml"
    if [[ -f "$TOML_FILE" ]] && ! grep -q "$DERIVED_PUBKEY" "$TOML_FILE"; then
        echo -e "${RED}>> Warning: Your key's public key does not match git-agecrypt.toml${NC}"
        echo "   Your public key: $DERIVED_PUBKEY"
        echo "   Decryption will fail. Check you pasted the correct key."
        echo ""
        echo -n "Continue anyway? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}>> Key matches configuration${NC}"
    fi
fi

# Set up sops-nix key (different from git-agecrypt key)
# Path depends on platform and whether we're on live ISO
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    # Live ISO - use /tmp, will be copied to /mnt by partition.sh
    SOPS_KEY_PATH="/tmp/sops-nix-key.txt"
    SOPS_NEEDS_SUDO=false
elif [[ "$PLATFORM" == "Darwin" ]]; then
    SOPS_KEY_PATH="$HOME/Library/Application Support/sops/age/keys.txt"
    SOPS_NEEDS_SUDO=false
else
    SOPS_KEY_PATH="/var/lib/sops-nix/key.txt"
    SOPS_NEEDS_SUDO=true
fi

echo -e "${YELLOW}>> Setting up sops-nix key...${NC}"
if [[ "$SOPS_NEEDS_SUDO" == true ]]; then
    sudo mkdir -p "$(dirname "$SOPS_KEY_PATH")"
    if sudo test -f "$SOPS_KEY_PATH" && sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
        echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> Paste your sops-nix age private key (starts with AGE-SECRET-KEY-):${NC}"
        echo "   (This is a DIFFERENT key from git-agecrypt!)"
        read -er KEY_CONTENT < /dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> Error: No key provided${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        echo "$KEY_CONTENT" | sudo tee "$SOPS_KEY_PATH" > /dev/null
        unset KEY_CONTENT
    fi
    sudo chmod 600 "$SOPS_KEY_PATH"
else
    mkdir -p "$(dirname "$SOPS_KEY_PATH")"
    if [ -f "$SOPS_KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$SOPS_KEY_PATH"; then
        echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> Paste your sops-nix age private key (starts with AGE-SECRET-KEY-):${NC}"
        echo "   (This is a DIFFERENT key from git-agecrypt!)"
        read -er KEY_CONTENT < /dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> Error: No key provided${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        (umask 077 && echo "$KEY_CONTENT" > "$SOPS_KEY_PATH")
        unset KEY_CONTENT
    fi
fi

# Verify sops key matches .sops.yaml
echo -e "${YELLOW}>> Verifying sops-nix key matches configuration...${NC}"
if [[ "$SOPS_NEEDS_SUDO" == true ]]; then
    SOPS_PUBKEY=$(sudo cat "$SOPS_KEY_PATH" | nix-shell -p age --run "age-keygen -y" 2>/dev/null || true)
else
    SOPS_PUBKEY=$(nix-shell -p age --run "age-keygen -y '${SOPS_KEY_PATH}'" 2>/dev/null || true)
fi
if [[ -n "$SOPS_PUBKEY" ]]; then
    SOPS_YAML="${CLONE_DIR}/.sops.yaml"
    if [[ -f "$SOPS_YAML" ]] && ! grep -q "$SOPS_PUBKEY" "$SOPS_YAML"; then
        echo -e "${RED}>> Warning: Your sops key's public key does not match .sops.yaml${NC}"
        echo "   Your public key: $SOPS_PUBKEY"
        echo "   Decryption will fail. Check you pasted the correct key."
        echo ""
        echo -n "Continue anyway? (y/n): "
        read -er CONFIRM < /dev/tty
        if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
            echo -e "${YELLOW}>> Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}>> Key matches configuration${NC}"
    fi
fi

# Configure git-agecrypt
echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
# Only run init if filters not already configured
if ! (cd "$CLONE_DIR" && run_git config --get filter.git-agecrypt.smudge) &>/dev/null; then
    nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt init"
else
    echo -e "${GREEN}>> git-agecrypt filters already configured${NC}"
fi
# Check if identity is already configured
if nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config list --identity" 2>/dev/null | grep -q "${KEY_PATH}"; then
    echo -e "${GREEN}>> git-agecrypt identity already configured${NC}"
else
    # Add identity
    ADD_OUTPUT=$(nix-shell -p git-agecrypt --run "cd '${CLONE_DIR}' && git-agecrypt config add -i '${KEY_PATH}'" 2>&1) || {
        echo -e "${RED}>> Error: Failed to add git-agecrypt identity${NC}"
        echo "$ADD_OUTPUT"
        exit 1
    }
    echo -e "${GREEN}>> git-agecrypt identity configured${NC}"
fi

# Find and decrypt all git-agecrypt.nix files
echo -e "${YELLOW}>> Decrypting secrets for all hosts...${NC}"
for SECRETS_FILE in "${CLONE_DIR}"/Secrets/*/git-agecrypt.nix; do
    if [[ ! -f "$SECRETS_FILE" ]]; then
        continue
    fi
    
    HOST_NAME=$(basename "$(dirname "$SECRETS_FILE")")
    
    # Check if already decrypted (starts with { or #)
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [[ "$FIRST_CHAR" == "{" || "$FIRST_CHAR" == "#" ]]; then
        echo -e "${GREEN}>> ${HOST_NAME}: Already decrypted${NC}"
        continue
    fi
    
    # Verify it's encrypted
    FIRST_LINE=$(head -n1 "$SECRETS_FILE")
    if [[ "$FIRST_LINE" != "age-encryption.org/v1" ]]; then
        echo -e "${RED}>> ${HOST_NAME}: Neither encrypted nor valid Nix!${NC}"
        exit 1
    fi
    
    # Decrypt (must run in nix-shell so git-agecrypt is available for smudge filter)
    echo -e "${YELLOW}>> ${HOST_NAME}: Decrypting...${NC}"
    nix-shell -p git git-agecrypt --run "cd '${CLONE_DIR}' && git checkout -- 'Secrets/${HOST_NAME}/git-agecrypt.nix'"
    
    # Verify decryption
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [[ "$FIRST_CHAR" == "{" || "$FIRST_CHAR" == "#" ]]; then
        echo -e "${GREEN}>> ${HOST_NAME}: Decrypted successfully${NC}"
    else
        echo -e "${RED}>> ${HOST_NAME}: Decryption failed${NC}"
        exit 1
    fi
done

SCRIPT_SUCCESS=true

echo ""
echo -e "${GREEN}>> Setup complete!${NC}"
echo ""
echo -e "${YELLOW}>> IMPORTANT: Run this command now (your shell's directory reference is stale):${NC}"
echo ""
echo "  cd ${CLONE_DIR}"
echo ""
echo "Then:"
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    echo ""
    echo "  # Partition disk (copies sops key automatically, prompts for LUKS passphrase):"
    echo "  ./partition.sh ${TARGET_HOST}"
    echo ""
    echo "  # Install NixOS:"
    echo "  ./install.sh ${TARGET_HOST}"
elif [[ "$PLATFORM" == "Darwin" ]]; then
    echo ""
    echo "  # Build and switch to Darwin configuration:"
    echo "  ./install.sh"
else
    echo ""
    echo "  # Rebuild system:"
    echo "  ./install.sh"
fi


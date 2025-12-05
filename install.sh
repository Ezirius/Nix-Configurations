#!/usr/bin/env bash

# Build and deploy Nix configuration
# Run ./git.sh first to commit and push changes
#
# Usage:
#   ./install.sh [host]

set -euo pipefail

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './install.sh'"
    exit 1
fi

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./install.sh [host]

Build and deploy Nix configuration for the current system.

Arguments:
  host    Target host configuration (optional, auto-detected if not provided)
          Available: Nithra (NixOS), Maldoria (Darwin)

Options:
  -h, --help    Show this help message

Prerequisites:
  - Run ./git.sh first to commit and push changes
  - On live ISO: run ./clone.sh and ./partition.sh first

Examples:
  ./install.sh              # Auto-detect host and deploy
  ./install.sh Nithra       # Deploy Nithra configuration
  ./install.sh Maldoria     # Deploy Maldoria configuration
EOF
    exit 0
fi

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PLATFORM=$(uname -s)
LINUX_HOSTS=("Nithra")
DARWIN_HOSTS=("Maldoria")

# Select hosts for current platform
if [[ "$PLATFORM" == "Darwin" ]]; then
    KNOWN_HOSTS=("${DARWIN_HOSTS[@]}")
else
    KNOWN_HOSTS=("${LINUX_HOSTS[@]}")
fi

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

# Ensure running interactively (not piped)
if [[ ! -t 0 ]]; then
    echo -e "${RED}>> Error: install.sh must be run interactively, not piped${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

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

ensure_git_agecrypt_filters() {
    if run_git config --get filter.git-agecrypt.smudge > /dev/null 2>&1; then
        return
    fi

    KEY_PATH="$HOME/.config/git-agecrypt/keys.txt"
    if [ -f "$KEY_PATH" ] && grep -q "AGE-SECRET-KEY-" "$KEY_PATH"; then
        echo -e "${GREEN}>> git-agecrypt key already exists at ${KEY_PATH}${NC}"
    else
        echo -e "${YELLOW}>> git-agecrypt key missing or invalid at ${KEY_PATH}${NC}"
        echo "   Creating directory and prompting for key..."
        mkdir -p "$(dirname "$KEY_PATH")"
        echo ""
        echo "Paste your git-agecrypt age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts git-agecrypt.nix files."
        echo ""
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        (umask 077 && echo "$KEY_CONTENT" > "$KEY_PATH")
        unset KEY_CONTENT
        echo -e "${GREEN}>> git-agecrypt key saved to ${KEY_PATH}${NC}"
    fi

    echo -e "${YELLOW}>> Configuring git-agecrypt filters...${NC}"
    nix-shell -p git-agecrypt --run "cd \"$SCRIPT_DIR\" && git-agecrypt init"
    nix-shell -p git-agecrypt --run "cd \"$SCRIPT_DIR\" && git-agecrypt config add -i \"$KEY_PATH\""
    echo -e "${GREEN}>> git-agecrypt identity configured${NC}"

    if ! run_git config --get filter.git-agecrypt.smudge > /dev/null 2>&1; then
        echo -e "${RED}>> git-agecrypt configuration failed; please configure manually.${NC}"
        exit 1
    fi
}

ensure_sops_key() {
    if [[ "$PLATFORM" == "Darwin" ]]; then
        SOPS_KEY="$HOME/Library/Application Support/sops/age/keys.txt"
        mkdir -p "$HOME/Library/Application Support/sops/age"
        if [ -s "$SOPS_KEY" ] && grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY}${NC}"
            return
        fi
        
        echo -e "${YELLOW}>> sops-nix key missing or invalid at ${SOPS_KEY}${NC}"
        echo ""
        echo "Paste your sops-nix age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts sops-nix.yaml files."
        echo ""
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        (umask 077 && echo "$KEY_CONTENT" > "$SOPS_KEY")
        unset KEY_CONTENT
        echo -e "${GREEN}>> sops-nix key saved to ${SOPS_KEY}${NC}"
    elif [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
        # Live ISO - key should be at /mnt (copied by partition.sh)
        SOPS_KEY="/mnt/var/lib/sops-nix/key.txt"
        if ! sudo test -s "$SOPS_KEY" || ! sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${RED}>> Error: sops-nix key not found at ${SOPS_KEY}${NC}"
            echo "   Run ./partition.sh first (it copies the key from /tmp)"
            exit 1
        fi
        echo -e "${GREEN}>> sops-nix key found at ${SOPS_KEY}${NC}"
    else
        # Installed NixOS system
        SOPS_KEY="/var/lib/sops-nix/key.txt"
        if sudo test -s "$SOPS_KEY" && sudo grep -q "AGE-SECRET-KEY-" "$SOPS_KEY"; then
            echo -e "${GREEN}>> sops-nix key already exists at ${SOPS_KEY}${NC}"
            return
        fi
        
        echo -e "${YELLOW}>> sops-nix key missing or invalid at ${SOPS_KEY}${NC}"
        echo ""
        echo "Paste your sops-nix age private key (starts with AGE-SECRET-KEY-)."
        echo "This key decrypts sops-nix.yaml files."
        echo ""
        read -er KEY_CONTENT </dev/tty
        if [[ -z "$KEY_CONTENT" ]]; then
            echo -e "${RED}>> No key provided. Aborting.${NC}"
            exit 1
        fi
        if [[ "$KEY_CONTENT" != AGE-SECRET-KEY-* ]]; then
            echo -e "${RED}>> Error: Key must start with AGE-SECRET-KEY-${NC}"
            exit 1
        fi
        sudo mkdir -p "$(dirname "$SOPS_KEY")"
        echo "$KEY_CONTENT" | sudo tee "$SOPS_KEY" > /dev/null
        unset KEY_CONTENT
        sudo chmod 600 "$SOPS_KEY"
        echo -e "${GREEN}>> sops-nix key saved to ${SOPS_KEY}${NC}"
    fi
}

# Initialise repo if missing
if [[ ! -d ".git" ]]; then
    echo "Initialising Git repository..."
    run_git init
fi

echo -e "${GREEN}>> NixOS/Darwin Build & Deploy${NC}"

# Validate host argument if provided
if [[ -n "${1:-}" ]]; then
    VALID_ARG=false
    for host in "${KNOWN_HOSTS[@]}"; do
        if [[ "${host,,}" == "${1,,}" ]]; then
            VALID_ARG=true
            break
        fi
    done
    if [[ "$VALID_ARG" != true ]]; then
        echo -e "${RED}>> Error: '${1}' is not a valid host for this platform${NC}"
        echo "   Available hosts: ${KNOWN_HOSTS[*]}"
        exit 1
    fi
fi

ensure_git_agecrypt_filters
ensure_sops_key

# Verify secrets are decrypted
echo -e "${YELLOW}>> Verifying secrets are decrypted...${NC}"
for SECRETS_FILE in "${SCRIPT_DIR}"/Secrets/*/git-agecrypt.nix; do
    if [[ ! -f "$SECRETS_FILE" ]]; then
        continue
    fi
    HOST_NAME=$(basename "$(dirname "$SECRETS_FILE")")
    FIRST_CHAR=$(head -c1 "$SECRETS_FILE")
    if [[ "$FIRST_CHAR" != "{" && "$FIRST_CHAR" != "#" ]]; then
        echo -e "${RED}>> Error: ${HOST_NAME}/git-agecrypt.nix is not decrypted${NC}"
        echo "   Run: nix-shell -p git git-agecrypt --run \"git checkout -- Secrets/${HOST_NAME}/git-agecrypt.nix\""
        exit 1
    fi
done
echo -e "${GREEN}>> Secrets decrypted${NC}"

# On live ISO, skip uncommitted changes check (git-agecrypt.nix is decrypted locally)
# On installed systems, require all changes to be committed
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    echo -e "${YELLOW}>> Live ISO: Using local working directory (secrets decrypted locally)${NC}"
    # Ensure nothing is staged (flakes use working directory for tracked files)
    run_git reset --quiet 2>/dev/null || true
else
    # Check for unstaged changes
    UNSTAGED=$(run_git diff --name-only 2>/dev/null || true)
    UNTRACKED=$(run_git ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "$UNSTAGED" || -n "$UNTRACKED" ]]; then
        echo -e "${RED}>> Error: You have uncommitted changes${NC}"
        echo ""
        [[ -n "$UNSTAGED" ]] && echo "Unstaged:" && run_git diff --name-only
        [[ -n "$UNTRACKED" ]] && echo "Untracked:" && run_git ls-files --others --exclude-standard
        echo ""
        echo "   Run ./git.sh to commit changes first, or use 'git stash' to set aside"
        exit 1
    fi

    # Stage files (required for flakes to see them)
    echo -e "${YELLOW}>> Staging files for flake...${NC}"
    run_git add .
fi

# --- DETERMINE TARGET ---
if [[ -n "${1:-}" ]]; then
    TARGET="$1"
    echo -e "${GREEN}>> Manual override: ${TARGET}${NC}"
elif [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    echo -e "${YELLOW}>> Running on NixOS installer${NC}"
    echo "   Select configuration to install:"
    select opt in "${KNOWN_HOSTS[@]}"; do
        if [[ -n "$opt" ]]; then
            TARGET="$opt"
            break
        else
            echo "Invalid. Try again."
        fi
    done </dev/tty
else
    for host in "${KNOWN_HOSTS[@]}"; do
        if [[ "${host,,}" == "$CURRENT_HOST_LOWER" ]]; then
            TARGET="$host"
            break
        fi
    done
    echo -e "${GREEN}>> Detected known host: ${TARGET}${NC}"
    echo -e "   Auto-building in 5 seconds... ${YELLOW}(Ctrl+C to cancel)${NC}"
    sleep 5
fi

# --- BUILD ---
FLAKE_TARGET="${TARGET,,}"

# Validate home-manager users exist (Darwin only)
if [[ "$PLATFORM" == "Darwin" ]]; then
    echo -e "${YELLOW}>> Validating home-manager users...${NC}"
    HM_USERS=$(nix eval ".#darwinConfigurations.${FLAKE_TARGET}.config.home-manager.users" \
        --apply 'users: builtins.concatStringsSep " " (builtins.attrNames users)' --raw 2>/dev/null || echo '')
    
    MISSING_USERS=()
    for user in $HM_USERS; do
        if ! id "$user" &>/dev/null; then
            MISSING_USERS+=("$user")
        fi
    done
    
    if [[ ${#MISSING_USERS[@]} -gt 0 ]]; then
        echo -e "${RED}>> Error: The following macOS users do not exist:${NC}"
        for user in "${MISSING_USERS[@]}"; do
            echo "   - $user"
        done
        echo ""
        echo "   Create them in System Settings → Users & Groups first"
        exit 1
    fi
    echo -e "${GREEN}>> All home-manager users exist${NC}"
fi

if [[ "$PLATFORM" == "Darwin" ]]; then
    echo -e "${GREEN}>> Rebuilding Darwin: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    if command -v darwin-rebuild &> /dev/null; then
        sudo darwin-rebuild switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}"
    else
        echo -e "${YELLOW}>> darwin-rebuild not found, bootstrapping nix-darwin...${NC}"
        sudo nix run nix-darwin -- switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}"
    fi
elif [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    echo -e "${GREEN}>> Installing NixOS: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    # Use path: to read from working directory (not git), so decrypted secrets are used
    sudo nixos-install --flake "path:${SCRIPT_DIR}#${FLAKE_TARGET}" --no-root-passwd
else
    echo -e "${GREEN}>> Rebuilding: ${SCRIPT_DIR}#${FLAKE_TARGET}${NC}"
    sudo nixos-rebuild switch --flake "${SCRIPT_DIR}#${FLAKE_TARGET}" --show-trace
fi

# Copy repo and keys to installed system (live ISO only)
if [[ "$CURRENT_HOST_LOWER" == "nixos" ]]; then
    DEST_DIR="/mnt/home/ezirius/Documents/Ezirius/Development/GitHub/Nix-Configurations"
    echo -e "${YELLOW}>> Copying configuration to installed system...${NC}"
    sudo mkdir -p "$(dirname "$DEST_DIR")"
    sudo cp -a "$SCRIPT_DIR" "$DEST_DIR"
    
    # Copy git-agecrypt key
    AGECRYPT_KEY_SRC="$HOME/.config/git-agecrypt/keys.txt"
    AGECRYPT_KEY_DEST="/mnt/home/ezirius/.config/git-agecrypt/keys.txt"
    AGECRYPT_KEY_COPIED=false
    if [[ -f "$AGECRYPT_KEY_SRC" ]]; then
        echo -e "${YELLOW}>> Copying git-agecrypt key...${NC}"
        sudo mkdir -p "$(dirname "$AGECRYPT_KEY_DEST")"
        sudo cp "$AGECRYPT_KEY_SRC" "$AGECRYPT_KEY_DEST"
        sudo chmod 600 "$AGECRYPT_KEY_DEST"
        AGECRYPT_KEY_COPIED=true
    else
        echo -e "${YELLOW}>> Warning: git-agecrypt key not found at ${AGECRYPT_KEY_SRC}${NC}"
    fi
    
    # Update git-agecrypt identity path for installed system
    AGECRYPT_CONFIG="$DEST_DIR/.git/git-agecrypt/config"
    if sudo test -f "$AGECRYPT_CONFIG"; then
        sudo sed -i "s|/root/.config/git-agecrypt/keys.txt|/home/ezirius/.config/git-agecrypt/keys.txt|g" "$AGECRYPT_CONFIG"
    fi
    
    # Set ownership on ezirius home directory
    EZIRIUS_UID=$(sudo grep "^ezirius:" /mnt/etc/passwd | cut -d: -f3)
    EZIRIUS_GID=$(sudo grep "^ezirius:" /mnt/etc/passwd | cut -d: -f4)
    sudo chown -R "${EZIRIUS_UID}:${EZIRIUS_GID}" "/mnt/home/ezirius"
    
    echo -e "${GREEN}>> Configuration copied to ${DEST_DIR}${NC}"
    if [[ "$AGECRYPT_KEY_COPIED" == true ]]; then
        echo -e "${GREEN}>> git-agecrypt key copied${NC}"
    fi
    echo ""
    echo -e "${GREEN}>> Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Reboot into the installed system"
    echo "  2. Configuration is at: ~/Documents/Ezirius/Development/GitHub/Nix-Configurations"
    echo "  3. Run ./install.sh to apply any future changes"
else
    # --- SYMLINK CONFIG (installed systems only) ---
    CONFIG_DIR="$HOME/.config/nixos"
    if [[ ! -e "$CONFIG_DIR" ]]; then
        echo -e "${YELLOW}>> Creating symlink: ${CONFIG_DIR} -> ${SCRIPT_DIR}${NC}"
        mkdir -p "$(dirname "$CONFIG_DIR")"
        ln -s "$SCRIPT_DIR" "$CONFIG_DIR"
    elif [[ -L "$CONFIG_DIR" ]]; then
        CURRENT_LINK=$(readlink "$CONFIG_DIR")
        if [[ "$CURRENT_LINK" != "$SCRIPT_DIR" ]]; then
            echo -e "${YELLOW}>> Updating symlink: ${CONFIG_DIR} -> ${SCRIPT_DIR}${NC}"
            rm "$CONFIG_DIR"
            ln -s "$SCRIPT_DIR" "$CONFIG_DIR"
        fi
    elif [[ -d "$CONFIG_DIR" ]]; then
        echo -e "${RED}>> Warning: ${CONFIG_DIR} is a directory, not a symlink${NC}"
        echo "   Remove it manually if you want automatic symlinking"
    fi
    
    echo -e "${GREEN}>> Success! System is live as: ${FLAKE_TARGET}${NC}"
fi

#!/usr/bin/env bash

# Validate configuration, stage, commit, and push changes to GitHub
# Checks: git-agecrypt, remote URL, user identity, commit signing, secrets encryption
#
# Usage:
#   ./git.sh

set -euo pipefail

# Require bash 4.0+ for ${var,,} and ${var^} syntax
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: bash 4.0+ required (you have ${BASH_VERSION})"
    echo "On macOS, run with: nix-shell -p bash --run './git.sh'"
    exit 1
fi

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./git.sh

Format, validate, commit, and push Nix configuration changes.

This script:
  1. Configures git-agecrypt if needed
  2. Validates git configuration (SSH remote, signing key, etc.)
  3. Fetches and rebases if remote has new commits
  4. Checks for local changes
  5. Formats Nix files with 'nix fmt'
  6. Stages all changes
  7. Validates flake for all systems
  8. Prompts for commit message
  9. Commits with signature
  10. Verifies secrets are encrypted
  11. Pushes to remote

Options:
  -h, --help    Show this help message

Prerequisites:
  - git-agecrypt key at ~/.config/git-agecrypt/keys.txt
  - Git configured with SSH signing key

Examples:
  ./git.sh    # Run the full commit workflow
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
for host in "${KNOWN_HOSTS[@]}"; do
    if [[ "${host,,}" == "$CURRENT_HOST_LOWER" ]]; then
        VALID_HOST=true
        break
    fi
done
if [[ "$VALID_HOST" != true ]]; then
    echo -e "${RED}>> Error: Hostname '${CURRENT_HOST}' is not a supported host${NC}"
    echo "   Supported hosts: ${KNOWN_HOSTS[*]}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${YELLOW}>> Working from: ${SCRIPT_DIR}${NC}"

# Ensure running interactively (not piped)
if [[ ! -t 0 ]]; then
    echo -e "${RED}>> Error: git.sh must be run interactively, not piped${NC}"
    exit 1
fi

# Ensure this is a git repository
if [[ ! -d ".git" ]]; then
    echo -e "${RED}>> Error: Not a git repository${NC}"
    echo "   Run this script from the repository root"
    exit 1
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

# Unstage changes on error to prevent accidental commits
cleanup_on_error() {
    echo -e "${RED}>> Error encountered; unstaging changes...${NC}"
    run_git reset --quiet || true
}
trap cleanup_on_error ERR

echo -e "${GREEN}>> Git Commit & Push${NC}"

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

# --- 1. ENSURE GIT-AGECRYPT CONFIGURED ---
echo -e "${YELLOW}>> Checking git-agecrypt configuration...${NC}"
ensure_git_agecrypt_filters
echo -e "${GREEN}>> git-agecrypt configured correctly${NC}"

# --- 2. VALIDATE GIT CONFIGURATION ---
echo -e "${YELLOW}>> Validating git configuration...${NC}"

# Check remote URL is SSH (use ls-remote --get-url to respect insteadOf rewrites)
REMOTE_URL=$(run_git ls-remote --get-url origin 2>/dev/null || echo "")
if [[ -z "$REMOTE_URL" ]]; then
    echo -e "${RED}>> Error: No remote 'origin' configured${NC}"
    exit 1
fi
if [[ "$REMOTE_URL" == https://* ]]; then
    echo -e "${RED}>> Error: Remote uses HTTPS, expected SSH${NC}"
    echo "   Current: $REMOTE_URL"
    echo "   Fix: git remote set-url origin git@github.com:ezirius/Nix-Configurations.git"
    exit 1
fi
echo -e "${GREEN}>> Remote URL: SSH${NC}"

# Check user.name
USER_NAME=$(run_git config user.name 2>/dev/null || echo "")
if [[ -z "$USER_NAME" ]]; then
    echo -e "${RED}>> Error: git user.name not configured${NC}"
    echo "   Fix: git config user.name \"Your Name\""
    exit 1
fi
echo -e "${GREEN}>> user.name: ${USER_NAME}${NC}"

# Check user.email
USER_EMAIL=$(run_git config user.email 2>/dev/null || echo "")
if [[ -z "$USER_EMAIL" ]]; then
    echo -e "${RED}>> Error: git user.email not configured${NC}"
    echo "   Fix: git config user.email \"you@example.com\""
    exit 1
fi
echo -e "${GREEN}>> user.email: ${USER_EMAIL}${NC}"

# Check commit signing is enabled
GPG_SIGN=$(run_git config --get commit.gpgsign 2>/dev/null || echo "")
if [[ "$GPG_SIGN" != "true" ]]; then
    echo -e "${RED}>> Error: Commit signing not enabled${NC}"
    echo "   Fix: git config commit.gpgsign true"
    exit 1
fi
echo -e "${GREEN}>> Commit signing: enabled${NC}"

# Check signing key is configured
SIGNING_KEY=$(run_git config --get user.signingkey 2>/dev/null || echo "")
if [[ -z "$SIGNING_KEY" ]]; then
    echo -e "${RED}>> Error: No signing key configured${NC}"
    echo "   Fix: git config user.signingkey <your-key>"
    exit 1
fi
echo -e "${GREEN}>> Signing key: configured${NC}"

# Check gpg.format is ssh (not gpg)
GPG_FORMAT=$(run_git config --get gpg.format 2>/dev/null || echo "")
if [[ "$GPG_FORMAT" != "ssh" ]]; then
    echo -e "${RED}>> Error: gpg.format not set to 'ssh'${NC}"
    echo "   Current: ${GPG_FORMAT:-<not set>}"
    echo "   Fix: git config gpg.format ssh"
    exit 1
fi
echo -e "${GREEN}>> gpg.format: ssh${NC}"

# --- 3. FETCH AND REBASE IF NEEDED ---
# Do this before any local changes to avoid conflicts
if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
    UPSTREAM=$(run_git rev-parse --abbrev-ref '@{u}' 2>/dev/null)
    echo -e "${YELLOW}>> Fetching from remote...${NC}"
    run_git fetch origin
    BEHIND=$(run_git rev-list HEAD.."$UPSTREAM" --count 2>/dev/null || echo "0")
    if [[ "$BEHIND" -gt 0 ]]; then
        echo -e "${YELLOW}>> Remote has ${BEHIND} new commit(s)${NC}"
        echo -n "Rebase local changes on top? (y/n): "
        read -er CONFIRM </dev/tty
        if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
            # Stash any local changes before rebasing
            STASHED=false
            if ! run_git diff --quiet || ! run_git diff --cached --quiet; then
                echo -e "${YELLOW}>> Stashing local changes...${NC}"
                run_git stash push -m "git.sh: auto-stash before rebase"
                STASHED=true
            fi
            if ! run_git pull --rebase; then
                echo -e "${RED}>> Rebase failed. Resolve conflicts and run ./git.sh again${NC}"
                [[ "$STASHED" == true ]] && echo "   Your changes are stashed. Run 'git stash pop' after resolving."
                exit 1
            fi
            if [[ "$STASHED" == true ]]; then
                echo -e "${YELLOW}>> Restoring stashed changes...${NC}"
                if ! run_git stash pop; then
                    echo -e "${RED}>> Stash pop failed (conflict with rebased changes)${NC}"
                    echo "   Resolve manually: git stash show -p | git apply"
                    exit 1
                fi
            fi
            echo -e "${GREEN}>> Rebased successfully${NC}"
        else
            echo -e "${RED}>> Aborted. Run 'git pull --rebase' manually when ready${NC}"
            exit 1
        fi
    fi
fi

# --- 4. CHECK FOR CHANGES ---
echo -e "${YELLOW}>> Checking for changes...${NC}"

if run_git diff --quiet && run_git diff --cached --quiet && [[ -z "$(run_git ls-files --others --exclude-standard)" ]]; then
    echo -e "${YELLOW}>> No changes to commit${NC}"
    
    # Check for unpushed commits
    if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
        UNPUSHED=$(run_git rev-list '@{u}..HEAD' --count 2>/dev/null || echo "0")
        if [[ "$UNPUSHED" -gt 0 ]]; then
            echo -e "${YELLOW}>> ${UNPUSHED} unpushed commit(s) found${NC}"
            echo -n "Push to remote? (y/n): "
            read -er CONFIRM </dev/tty
            if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
                echo -e "${YELLOW}>> Pushing to remote...${NC}"
                run_git push
                echo -e "${GREEN}>> Pushed successfully${NC}"
            fi
        fi
    fi
    exit 0
fi

# --- 5. FORMAT NIX FILES ---
echo -e "${YELLOW}>> Formatting Nix files...${NC}"
nix --extra-experimental-features "nix-command flakes" fmt 2>&1 | { grep -v "^warning: Git tree" || true; }

# --- 6. DETECT FRESH REPO ---
# git-agecrypt filters only work after first commit exists
# For fresh repos, we must: commit non-secrets first, then add secrets and amend
FRESH_REPO=false
if ! run_git rev-parse HEAD &>/dev/null; then
    FRESH_REPO=true
    echo -e "${YELLOW}>> Fresh repo detected - will use two-step commit for git-agecrypt${NC}"
fi

# --- 7. STAGE CHANGES ---
echo -e "${YELLOW}>> Staging changes...${NC}"
if [[ "$FRESH_REPO" == true ]]; then
    # Fresh repo: stage everything except Secrets first
    run_git add . ':!Secrets'
else
    # Normal: stage everything
    run_git add .
fi

# Show what's staged
echo ""
run_git status --short
echo ""

# --- 8. VALIDATE FLAKE ---
# Must validate before committing (needs staged files)
echo -e "${YELLOW}>> Validating flake (current system)...${NC}"
if ! nix --extra-experimental-features "nix-command flakes" flake check; then
    echo ""
    echo -e "${RED}>> Flake validation failed. Aborting.${NC}"
    run_git reset --quiet
    exit 1
fi
echo -e "${GREEN}>> Flake valid (current system)${NC}"

echo -e "${YELLOW}>> Validating flake (all systems, eval only)...${NC}"
if ! nix --extra-experimental-features "nix-command flakes" flake check --all-systems --no-build; then
    echo ""
    echo -e "${RED}>> Flake evaluation failed for other systems. Aborting.${NC}"
    run_git reset --quiet
    exit 1
fi
echo -e "${GREEN}>> Flake valid (all systems)${NC}"

# --- 9. PROMPT FOR COMMIT MESSAGE ---
echo ""
echo -n "Commit message: "
read -er COMMIT_MSG </dev/tty

if [[ -z "$COMMIT_MSG" ]]; then
    echo -e "${RED}>> Error: Commit message cannot be empty${NC}"
    run_git reset --quiet
    exit 1
fi

# --- 10. COMMIT ---
if [[ "$FRESH_REPO" == true ]]; then
    # Fresh repo: two-step commit
    echo -e "${YELLOW}>> Creating initial commit (without secrets)...${NC}"
    run_git commit -m "$COMMIT_MSG"
    
    echo -e "${YELLOW}>> Adding secrets (git-agecrypt filters now active)...${NC}"
    run_git add Secrets/
    
    echo -e "${YELLOW}>> Amending commit to include secrets...${NC}"
    run_git commit --amend --no-edit
else
    # Normal commit
    echo -e "${YELLOW}>> Committing...${NC}"
    run_git commit -m "$COMMIT_MSG"
fi

# --- 11. VERIFY SECRETS ARE ENCRYPTED ---
echo -e "${YELLOW}>> Verifying secrets are encrypted...${NC}"
SECRETS_OK=true
for SECRETS_FILE in $(run_git ls-files --cached 'Secrets/*/git-agecrypt.nix' 2>/dev/null); do
    FIRST_LINE=$(run_git show "HEAD:${SECRETS_FILE}" 2>/dev/null | head -n1 || true)
    if [[ "$FIRST_LINE" != "age-encryption.org/v1" ]]; then
        echo -e "${RED}>> ERROR: ${SECRETS_FILE} is not encrypted in commit!${NC}"
        echo "   Expected 'age-encryption.org/v1' header, got: ${FIRST_LINE:0:30}"
        SECRETS_OK=false
    else
        echo -e "${GREEN}>> ${SECRETS_FILE}: Encrypted${NC}"
    fi
done

if [[ "$SECRETS_OK" != true ]]; then
    echo ""
    echo -e "${RED}>> Secrets are not encrypted! Do NOT push.${NC}"
    echo ""
    echo "To fix:"
    echo "  1. git reset HEAD~1  (undo the commit)"
    echo "  2. nix-shell -p git-agecrypt --run \"git-agecrypt init\""
    echo "  3. nix-shell -p git-agecrypt --run \"git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt\""
    echo "  4. Run ./git.sh again"
    exit 1
fi

# --- 12. PUSH ---
if run_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
    echo -e "${YELLOW}>> Pushing to remote...${NC}"
    run_git push
    echo -e "${GREEN}>> Pushed successfully${NC}"
else
    BRANCH=$(run_git branch --show-current)
    echo -e "${YELLOW}>> No upstream branch set${NC}"
    echo -n "Push and set upstream to origin/${BRANCH}? (y/n): "
    read -er CONFIRM </dev/tty
    if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
        echo -e "${YELLOW}>> Pushing to remote...${NC}"
        run_git push -u origin "$BRANCH"
        echo -e "${GREEN}>> Pushed successfully${NC}"
    else
        echo "   To push manually: git push -u origin ${BRANCH}"
    fi
fi

echo ""
echo -e "${GREEN}>> Done!${NC}"

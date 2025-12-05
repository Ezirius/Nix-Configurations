# Nix Configurations

Encrypted declarative Nix infrastructure for NixOS and macOS (nix-darwin).

| Host | Platform | Architecture | Description |
|------|----------|--------------|-------------|
| Nithra | NixOS | x86_64-linux | VPS with LUKS full-disk encryption and Dropbear SSH unlock |
| Maldoria | macOS (nix-darwin) | aarch64-darwin | Apple Silicon Mac |

**Note:** Throughout this document, `<repo>` refers to your local clone of this repository.

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Daily Operations](#3-daily-operations)
4. [Configuration Changes](#4-configuration-changes)
5. [Secrets Management](#5-secrets-management)
6. [Fresh Installation](#6-fresh-installation)
7. [Disaster Recovery](#7-disaster-recovery)
8. [Security Model](#8-security-model)
9. [Reference](#9-reference)

---

## 1. Overview

### System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        NITHRA (VPS)                             │
│  ┌───────────────────┐      ┌───────────────────────────────┐  │
│  │ Stage 1: Boot     │      │ Stage 2: Runtime              │  │
│  │ (Dropbear SSH)    │ ──▶  │ (OpenSSH)                     │  │
│  │                   │      │                               │  │
│  │ - LUKS unlock     │      │ - Normal administration       │  │
│  │ - Port 22         │      │ - Port 22 (SSH)               │  │
│  │ - Root user       │      │ - Port 60000-61000/udp (Mosh) │  │
│  │ - Restricted keys │      │ - User: ezirius               │  │
│  └───────────────────┘      └───────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
        ▲                              ▲
        │ ssh nithra-boot              │ ssh nithra / mosh nithra
        │ (unlock LUKS)                │ (daily use)
        │                              │
┌───────┴──────────────────────────────┴───────┐
│           CLIENT MACHINES                     │
│           (Ipsa, Ipirus, Maldoria)            │
│           - SSH keys for both stages          │
│           - This repo cloned locally          │
└──────────────────────────────────────────────┘
```

### What is This?

- **Nithra**: A VPS with full-disk encryption (LUKS)
- **Ipsa, Ipirus, Maldoria**: Client machines that manage and access nithra
- **Two-stage boot**: Dropbear SSH in initrd for LUKS unlock, then OpenSSH for normal access
- **Declarative config**: Entire system defined in Nix, version controlled in Git

### Boot Flow

1. VPS powers on
2. Dropbear SSH starts in initrd (Stage 1)
3. Client SSHs in (`ssh nithra-boot`), enters LUKS passphrase
4. System decrypts and boots
5. OpenSSH starts (Stage 2)
6. Client SSHs in (`ssh nithra`) for normal use

---

## 2. Prerequisites

### Software Requirements

**Bash 4.0+** is required for all scripts (`install.sh`, `git.sh`, `clone.sh`, `partition.sh`).

| Platform | Bash Version | Notes |
|----------|--------------|-------|
| NixOS live ISO | 5.x ✓ | Works out of the box |
| NixOS installed | 5.x ✓ | Works out of the box |
| macOS (system) | 3.2 ✗ | Too old - install Nix first |
| macOS (with Nix) | 5.x ✓ | Nix provides modern bash |

**On macOS, install Nix before running any scripts:**

```bash
# 1. Install Nix (provides bash 5.x and nix-shell)
curl -L https://nixos.org/nix/install | sh

# 2. Restart terminal or source Nix profile
. ~/.nix-profile/etc/profile.d/nix.sh

# 3. Now clone.sh will work
curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash -s -- Maldoria
```

**Note:** When piping `curl | bash` on macOS, the system's `/bin/bash` (3.2) is used initially. If bash 4.0+ is not in PATH, clone.sh will fail with a clear error message. After Nix is installed and in PATH, the scripts will work correctly.

All scripts support `--help` for usage information:
```bash
./install.sh --help
./git.sh --help
./clone.sh --help
./partition.sh --help
```

### Backup Checklist

Store securely in password manager:

- [ ] **Age private key (sops-nix)** - Contents of `/var/lib/sops-nix/key.txt`
- [ ] **Age private key (git-agecrypt)** - Contents of `~/.config/git-agecrypt/keys.txt` (may be different from sops-nix key)
- [ ] **LUKS passphrase** - Disk encryption password (**unrecoverable if lost**)
- [ ] **VPS credentials** - Provider control panel login (for VNC access)

SSH keys live on client machines (Ipsa, Ipirus, Maldoria) - backed up separately.

### Client SSH Config

Add to `~/.ssh/config` on Ipsa/Ipirus/Maldoria:

```
Host nithra
    HostName <static-ip>
    User ezirius
    IdentityFile ~/.ssh/<client>_nithra_ezirius_login

Host nithra-boot
    HostName <static-ip>
    User root
    IdentityFile ~/.ssh/<client>_nithra_root_boot
    # Different host key than nithra (Dropbear vs OpenSSH)
```

**Note:** First connection to each host will prompt to accept the host key. Dropbear (boot) and OpenSSH (runtime) intentionally use different keys, so you'll need to accept both. This prevents an attacker who compromises one from impersonating the other.

**Mosh usage:** `mosh nithra` works out of the box - UDP ports 60000-61000 are open on the server firewall.

### Required Knowledge

- Basic Nix/NixOS concepts (flakes, modules, options)
- SSH key-based authentication
- Linux command line familiarity
- Git basics (clone, commit, push)

---

## 3. Daily Operations

### Rebuild System

```bash
cd <repo>
./install.sh
```

The script automatically:
1. Ensures git-agecrypt and sops-nix keys are configured
2. Stages all git files (required for flakes)
3. Detects hostname (fails if not a known host or NixOS installer)
4. Validates home-manager users exist (Darwin only - create missing users in System Settings → Users & Groups)
5. Runs `nixos-rebuild switch --flake .#<host>` (validates during build)
6. Creates symlink to `~/.config/nixos` if repo is elsewhere

**Note:** Run `./git.sh` first to format, validate, commit, and push changes.

**What to watch for:**
- Build errors appear immediately - fix and re-run
- Activation warnings are usually safe but worth noting
- If switch fails mid-activation, system may be in inconsistent state - rollback immediately

**Note:** Use `git` for version control, not `jj` (jujutsu). jj doesn't support `.gitattributes` filters required by git-agecrypt.

### Update System

```bash
cd <repo>
nix flake update          # Update all inputs (nixpkgs, home-manager, etc.)
./install.sh              # Apply updates
```

**Warning:** Updates can introduce breaking changes. Always test in a new terminal and keep the original session open for rollback.

Update single input (safer):
```bash
nix flake lock --update-input nixpkgs
./install.sh
```

### Check Current Generation

```bash
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

### Compare Generations

```bash
# See what changed between current and previous generation
nix store diff-closures /run/booted-system /nix/var/nix/profiles/system
```

### Check if Reboot Required

```bash
booted=$(readlink /run/booted-system/kernel)
current=$(readlink /nix/var/nix/profiles/system/kernel)
[ "$booted" != "$current" ] && echo "Reboot required" || echo "No reboot required"
```

### Reboot Safely

1. Keep current SSH session open (safety net)
2. `sudo reboot`
3. SSH to Dropbear: `ssh nithra-boot`
4. Enter LUKS passphrase when prompted
5. Wait 30-60 seconds for boot
6. Verify: `ssh nithra`

### Test After Deploy

After running `./install.sh`, always test in a **new terminal** before closing the original:

```bash
# New terminal
ssh nithra
whoami                    # Should be: ezirius
echo $SHELL               # Should be: /run/current-system/sw/bin/zsh
sudo whoami               # Should be: root (tests sudo + password)
```

### Format Nix Files

```bash
nix fmt                   # Uses nixfmt-rfc-style (runs automatically in git.sh)
```

### Validate Configuration

```bash
cd <repo>
nix flake check                              # Validates flake structure
nixos-rebuild build --flake .#nithra         # Test build without switching
```

---

## 4. Configuration Changes

### Add SSH Key for Login

On NixOS, SSH login keys are stored in git-agecrypt.nix because they're needed at Nix evaluation time. On Darwin, they're stored in sops (using templates).

1. Edit `Secrets/Nithra/git-agecrypt.nix`

2. Add to `loginKeysPub` (following naming convention `<from>_nithra_<user>_login`):
   ```nix
   loginKeysPub = {
     # ... existing keys ...
     newmachine_nithra_ezirius_login = "ssh-ed25519 AAAA...";
   };
   ```

3. Add to `Hosts/Nithra/default.nix` in the `authorizedKeys.keys` list:
   ```nix
   users.users.<user>.openssh.authorizedKeys.keys = [
     # ... existing keys ...
     secrets.loginKeysPub.newmachine_nithra_ezirius_login
   ];
   ```

4. `./install.sh`

### Add SSH Key for Boot Unlock

1. Edit `Secrets/Nithra/git-agecrypt.nix`

2. Add a new key to `bootKeysPub` (following naming convention `<from>_nithra_root_boot`):
   ```nix
   bootKeysPub = {
     # ... existing keys ...
     newmachine_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
   };
   ```

3. Add to `Hosts/Nithra/default.nix` in the `boot.initrd.network.ssh.authorizedKeys` list:
   ```nix
   boot.initrd.network.ssh.authorizedKeys = [
     # ... existing keys ...
     secrets.bootKeysPub.newmachine_nithra_root_boot
   ];
   ```

4. `./install.sh`

**Note:** Dropbear keys are restricted to only run `systemd-tty-ask-password-agent` - they cannot execute other commands.

### Add New User

1. Create directory structure:
   ```
   Users/<name>/
   ├── <host>-account.nix  # System user config (NixOS only)
   └── <host>-home.nix     # Home-manager config
   ```

2. Generate password hash:
   ```bash
   nix-shell -p mkpasswd --run "mkpasswd -m sha-512"
   ```

3. Add password to `Secrets/Nithra/sops-nix.yaml`:
   ```bash
   cd <repo>
   sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"
   ```
   Add: `<name>Password: "<hash from step 2>"`

4. Add sops reference in `Hosts/Nithra/default.nix`:
   ```nix
   sops.secrets.<name>Password.neededForUsers = true;
   ```

5. Import user in `Hosts/Nithra/default.nix`:
   ```nix
   imports = [
     ...
     ../../Users/<name>
   ];
   ```

6. Add home-manager in `flake.nix`:
   ```nix
   home-manager.users.<name> = import ./Users/<name>/<host>-home.nix;
   ```

7. `./install.sh`

### Add System Package

Edit `Hosts/Nithra/default.nix`:
```nix
environment.systemPackages = builtins.attrValues {
  inherit (pkgs)
    ...
    newpackage
    ;
};
```

### Add User Package (via home-manager)

Edit `Users/<user>/<host>-home.nix`. First ensure `pkgs` is in the function arguments:
```nix
{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      newpackage
      ;
  };
}
```

Or enable a program module (preferred when available):
```nix
programs.newprogram = {
  enable = true;
  # program-specific settings
};
```

### Configure Git Commit Signing

Git commits are signed with SSH keys for verified badges on GitHub.

**Nithra (NixOS):**
1. Generate signing key: `ssh-keygen -t ed25519 -C "nithra_github_ezirius_sign" -f /tmp/nithra_sign`
2. Add private key to `Secrets/Nithra/sops-nix.yaml`
3. Add public key to GitHub → Settings → SSH and GPG keys → New SSH key → Key type: **Signing Key**
4. The Nix config (`Hosts/Nithra/default.nix` and `Users/ezirius/nithra-home.nix`) handles deployment and git config

**Maldoria (macOS with 1Password):**
1. Create signing key in 1Password (SSH Key item type)
2. Add public key to `Secrets/Maldoria/sops-nix.yaml`
3. Add public key to GitHub → Settings → SSH and GPG keys → New SSH key → Key type: **Signing Key**
4. The Nix config handles deployment and git config
5. Ensure `SSH_AUTH_SOCK` points to 1Password's agent (configured in `maldoria-home.nix`)

**Testing signing:**
```bash
echo "test" | ssh-keygen -Y sign -f ~/.ssh/<host>_github_ezirius_sign -n git
```

If this fails on Maldoria, check 1Password's SSH agent is active:
```bash
echo $SSH_AUTH_SOCK  # Should contain "1Password"
ssh-add -L           # Should list keys from 1Password
```

### Configure SSH Server (Darwin)

Maldoria runs an SSH server for remote access, using sops templates for authorized_keys.

**Architecture:**
- SSH login public keys stored in `Secrets/Maldoria/sops-nix.yaml`
- sops-nix creates symlink at `~/.ssh/authorized_keys` → `/run/secrets-for-users/authorized_keys`
- `StrictModes no` required because SSH rejects symlinked authorized_keys
- Activation script ensures `~/.ssh/` exists before sops runs

**Configuration in `Hosts/Maldoria/default.nix`:**
```nix
# SSH server
services.openssh = {
  enable = true;
  settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    AllowUsers = [ "ezirius" ];
    StrictModes = "no";  # Required for sops symlinked authorized_keys
  };
};

# sops secrets and template
sops.secrets.ipsa_maldoria_ezirius_login = { };
sops.secrets.ipirus_maldoria_ezirius_login = { };

sops.templates."authorized_keys" = {
  owner = username;
  path = "${homeDir}/.ssh/authorized_keys";
  mode = "0600";
  content = ''
    ${config.sops.placeholder.ipsa_maldoria_ezirius_login}
    ${config.sops.placeholder.ipirus_maldoria_ezirius_login}
  '';
};

# Ensure ~/.ssh/ exists
system.activationScripts.postActivation.text = ''
  mkdir -p "${homeDir}/.ssh"
  chown ${username}:staff "${homeDir}/.ssh"
  chmod 700 "${homeDir}/.ssh"
'';
```

### Configure Firewall (Darwin)

macOS Application Firewall controls incoming connections (outgoing is unrestricted).

```nix
networking.applicationFirewall = {
  enable = true;
  enableStealthMode = true;  # Don't respond to probes
  allowSigned = true;        # Allow Apple-signed apps
  allowSignedApp = false;    # Prompt for third-party apps
};
```

### Configure Touch ID for Sudo (Darwin)

```nix
security.pam.services.sudo_local.touchIdAuth = true;
```

### Add New Host

1. Create `Hosts/<hostname>/default.nix` and `disko-config.nix`
2. Create `Secrets/<hostname>/git-agecrypt.nix` (copy and modify from Nithra)
3. Create `Secrets/<hostname>/sops-nix.yaml` for runtime secrets
4. Add to `flake.nix`:
   ```nix
   nixosConfigurations.<hostname> = nixpkgs.lib.nixosSystem {
     modules = [ ... ];
   };
   ```
5. Add to `install.sh`, `clone.sh`, `partition.sh`, and `git.sh` host arrays
6. Update `.sops.yaml` with host's age public key (for sops-nix)
7. Update `git-agecrypt.toml` with host's age public key (for git-agecrypt)
8. Update `.gitattributes` with path to new host's `git-agecrypt.nix`

---

## 5. Secrets Management

### Architecture

Two-layer system due to NixOS evaluation constraints:

| Layer | Tool | File | When Decrypted | NixOS Use Case | Darwin Use Case |
|-------|------|------|----------------|----------------|-----------------|
| 1 | git-agecrypt | `Secrets/<host>/git-agecrypt.nix` | Git checkout (smudge filter) | Network, Dropbear host key, Dropbear authorised keys, SSH login pubkeys | Nithra connection info (IP, host keys) |
| 2 | sops-nix | `Secrets/<host>/sops-nix.yaml` | System activation | Passwords, OpenSSH host key, GitHub SSH keys | GitHub keys (public, for 1Password), SSH login pubkeys |

**Platform difference:** On NixOS, SSH login pubkeys must be in git-agecrypt because `authorizedKeys.keys` needs values at Nix evaluation time. On Darwin, nix-darwin lacks `authorizedKeys` support, so sops templates write the `authorized_keys` file at activation time.

**Why two layers?** Layer 1 secrets are needed during Nix evaluation (e.g., boot kernel params) or in initrd (before sops-nix runs). Layer 2 secrets are decrypted at runtime by sops-nix. See the comments in `Secrets/Nithra/git-agecrypt.nix` for detailed explanation.

### Key Naming Convention

All keys follow the format: `[from]_[to]_[user]_[type]`

| Component | Description | Examples |
|-----------|-------------|----------|
| `from` | Machine where the key resides | `ipsa`, `maldoria`, `nithra` |
| `to` | Target machine, service, or `all` | `nithra`, `github`, `all` |
| `user` | Username or `all` | `ezirius`, `root`, `all` |
| `type` | Key purpose | `login`, `boot`, `nix-configurations`, `sign` |

**Note:** For host keys (which identify a machine to others), use `<machine>_all_all_<type>` - the machine identifies itself (`from`) to all clients (`to`) for all users (`user`).

**Examples:**
- `ipsa_nithra_ezirius_login` - SSH key on Ipsa to login to Nithra as ezirius
- `maldoria_nithra_root_boot` - SSH key on Maldoria to unlock Nithra boot (Dropbear)
- `nithra_github_ezirius_nix-configurations` - SSH key on Nithra for pushing to GitHub
- `maldoria_github_ezirius_sign` - SSH key on Maldoria for signing Git commits
- `nithra_github_ezirius_sign` - SSH key on Nithra for signing Git commits
- `nithra_all_all_boot` - Nithra's Dropbear host key (identifies Nithra to all clients)
- `nithra_all_all_login` - Nithra's OpenSSH host key (identifies Nithra to all clients)

### git-agecrypt.nix Encryption Behavior

**IMPORTANT:** `git-agecrypt.nix` is **always decrypted in your working directory** - this is correct and expected!

| Location | State | Why |
|----------|-------|-----|
| Working directory | **Plaintext** | Required for Nix to import and evaluate |
| Git commits/remote | **Encrypted** | git-agecrypt encrypts via clean filter on commit |

To verify encryption is working:
```bash
# Local file (should be readable plaintext)
head Secrets/Nithra/git-agecrypt.nix

# In git (should show age-encryption.org/v1 header, not plaintext Nix)
git show HEAD:Secrets/Nithra/git-agecrypt.nix | head -5
```

If you can read the local file but `git show` displays the age header (not plaintext Nix), git-agecrypt is working correctly.

### Age Key Locations

| Path | Owner | Purpose |
|------|-------|---------|
| `/var/lib/sops-nix/key.txt` | root | sops-nix (automatic decryption at activation) - requires `sudo` to read/edit |
| `~/.config/git-agecrypt/keys.txt` | user | git-agecrypt (decrypt git-agecrypt.nix on checkout) |

**Key sharing model:**
- **git-agecrypt key**: One key shared across all hosts (same key on Nithra, Maldoria, etc.)
- **sops-nix key**: One key shared across all hosts (same key, but different from git-agecrypt)
- Both keys must be backed up — they decrypt different secret files

Permissions: `600`

Key format:
```
# created: 2024-01-01T00:00:00Z
# public key: age1...
AGE-SECRET-KEY-1...
```

### Edit git-agecrypt Secrets

```bash
cd <repo>

# First time setup in a fresh clone
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# Edit (auto-decrypts on read, auto-encrypts on commit)
vim Secrets/Nithra/git-agecrypt.nix
```

File auto-decrypts on checkout, auto-encrypts on commit via `.gitattributes` filter.

### Edit sops-nix Secrets

**Nithra (NixOS):**
```bash
cd <repo>
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"
```

**Maldoria (macOS):**
```bash
cd <repo>
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Maldoria/sops-nix.yaml"
```

Opens in `$EDITOR`. File auto-encrypts on save.

### git-agecrypt.nix Contents

The file includes detailed comments explaining why each secret is needed. Structure:

```nix
{
  network = {
    nithraIp = "x.x.x.x";           # Static IP from VPS provider
    nithraGateway = "x.x.x.x";      # Gateway from VPS provider
    nithraPrefixLength = 24;        # CIDR prefix (e.g., 24 = /24)
    nithraNetmask = "255.255.255.0"; # Kernel params require string format
  };
  bootKeysPub = {
    # Each key prefixed with restrictions and command
    # Named: <from>_nithra_root_boot
    ipsa_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
    maldoria_nithra_root_boot = ''no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="systemd-tty-ask-password-agent --watch" ssh-ed25519 AAAA...'';
  };
  loginKeysPub = {
    # Named: <from>_nithra_<user>_login
    ipsa_nithra_ezirius_login = "ssh-ed25519 AAAA...";
    maldoria_nithra_ezirius_login = "ssh-ed25519 AAAA...";
  };
  hostKeys = {
    # Only Dropbear key here (needed at build time for initrd)
    # OpenSSH host key is in sops-nix.yaml (deployed at activation)
    nithra_all_all_boot = "-----BEGIN OPENSSH PRIVATE KEY-----...";
  };
  hostKeysPub = {
    # Public keys for known_hosts (used by Maldoria to verify Nithra)
    nithra_all_all_boot = "ssh-ed25519 AAAA...";   # Dropbear host key
    nithra_all_all_login = "ssh-ed25519 AAAA...";  # OpenSSH host key
  };
}
```

### sops-nix.yaml Contents

**Nithra (NixOS) - contains private keys:**
```yaml
rootPassword: $6$...          # SHA-512 hash from mkpasswd
eziriusPassword: $6$...       # SHA-512 hash from mkpasswd
nithra_all_all_login: |        # OpenSSH host key (deployed to /etc/ssh/)
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
nithra_github_ezirius_nix-configurations: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
nithra_github_ezirius_sign: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

**Maldoria (macOS) - contains public keys for 1Password and SSH login keys:**
```yaml
maldoria_github_ezirius_nix-configurations: ssh-ed25519 AAAA...
maldoria_github_ezirius_sign: ssh-ed25519 AAAA...
maldoria_nithra_root_boot: ssh-ed25519 AAAA...
maldoria_nithra_ezirius_login: ssh-ed25519 AAAA...
ipsa_maldoria_ezirius_login: ssh-ed25519 AAAA...
ipirus_maldoria_ezirius_login: ssh-ed25519 AAAA...
```

On Maldoria, sops deploys public keys to `~/.ssh/`. 1Password's SSH agent matches these to private keys stored in its vault and provides them on demand.

**Note:** On NixOS, SSH login public keys are in git-agecrypt.nix (not sops) because `authorizedKeys.keys` needs values at Nix evaluation time. On Darwin, SSH login keys are in sops (using templates) since nix-darwin lacks `authorizedKeys` support.

### .sops.yaml Structure

```yaml
keys:
  - &shared age1...           # Shared key (same key used for all hosts)
creation_rules:
  - path_regex: Secrets/.*/sops-nix\.yaml$
    key_groups:
      - age:
          - *shared           # Reference to anchor
```

### Generate New Age Key

If you need a new age key (new machine, key compromise):

```bash
# Generate new key
nix-shell -p age --run "age-keygen -o new-age-key.txt"

# View public key (needed for .sops.yaml)
nix-shell -p age --run "age-keygen -y new-age-key.txt"
```

Then re-encrypt all secrets with the new key (see Disaster Recovery).

---

## 6. Fresh Installation

### Prerequisites Checklist

Have these ready before starting:

| Secret | Source | Description |
|--------|--------|-------------|
| Age key (git-agecrypt) | Password manager | Decrypts git-agecrypt.nix on checkout |
| Age key (sops-nix) | Password manager | Decrypts sops-nix.yaml at runtime (different key!) |
| LUKS passphrase | Password manager / create new | Disk encryption password |
| VPS credentials | Provider account | Control panel login for VNC |
| This repo | GitHub | git@github.com:ezirius/Nix-Configurations.git |

### Step 1: Boot NixOS ISO

1. Mount NixOS Minimal ISO via VPS control panel
2. Boot into ISO
3. Configure network (adjust IP/prefix for your provider):

```bash
# Replace with your actual IP, prefix, and gateway
sudo ip addr add <static-ip>/<prefix> dev ens18
sudo ip route add default via <gateway>
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf

# Verify connectivity
curl -sI https://github.com --max-time 5 && echo "Network OK"
```

### Step 2: Run Clone Script

The `clone.sh` script automates repository setup, age key configuration, and secrets decryption:

```bash
# Download and run clone script
# Host can be specified, or omitted if only one valid host exists for the platform
# (e.g., on NixOS live ISO, only Nithra is valid; on macOS, only Maldoria is valid)
curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash -s -- Nithra

# Or let it auto-detect when only one valid host for current platform:
curl -sL https://raw.githubusercontent.com/ezirius/Nix-Configurations/main/clone.sh | bash
```

The script will:
1. Check network connectivity
2. Clone the repository to `/tmp/Nix-Configurations`
3. Prompt you to paste your **git-agecrypt** age private key
4. Prompt you to paste your **sops-nix** age private key (saved to `/tmp/sops-nix-key.txt`, copied to `/mnt` by `partition.sh`)
5. Configure git-agecrypt filters
6. Verify secrets are encrypted, then decrypt them
7. Print next steps

**Manual alternative:** If the curl command fails, see the manual steps in the script comments or clone manually:
```bash
nix-shell -p git --run "git clone https://github.com/ezirius/Nix-Configurations.git /tmp/Nix-Configurations"
```

### Step 3: Partition and Format

```bash
cd /tmp/Nix-Configurations

# Run partition script (will prompt for LUKS passphrase)
./partition.sh Nithra
```

The script will:
1. Read the disk device from `disko-config.nix`
2. Verify the disk exists
3. Show disk details and require "yes" confirmation
4. Wipe and partition the disk

**Important:** Remember the LUKS passphrase you enter - it's **unrecoverable** if forgotten. You'll need it for every boot.

### Step 4: Verify sops-nix Key

The `partition.sh` script automatically copies the sops-nix key to `/mnt/var/lib/sops-nix/key.txt`. If you see a warning that the key wasn't found, copy it manually:

```bash
sudo mkdir -p /mnt/var/lib/sops-nix
sudo cp /tmp/sops-nix-key.txt /mnt/var/lib/sops-nix/key.txt
sudo chmod 600 /mnt/var/lib/sops-nix/key.txt
```

### Step 5: Install

```bash
./install.sh Nithra
```

- Takes 10-20 minutes depending on connection
- The script runs `nixos-install` with `--no-root-passwd` (root password is managed via sops-nix)
- If it fails, check secrets are decrypted: `head Secrets/Nithra/git-agecrypt.nix`
- If it fails partway, you can re-run the same command - it will resume where it left off

### Step 6: Reboot and Unlock

```bash
sudo reboot
```

After reboot:

1. **Stage 1 (Dropbear):**
   ```bash
   ssh root@<ip>
   # Accept host key on first connection
   # Passphrase prompt appears immediately - enter LUKS passphrase
   # Connection closes automatically after successful unlock
   ```

2. **Wait 30-60 seconds** for system to boot

3. **Stage 2 (OpenSSH):**
   ```bash
   ssh ezirius@<ip>
   # Accept host key on first connection (different from Dropbear key)
   ```

### Step 7: Post-Install Setup

The `install.sh` script automatically copies the repository and git-agecrypt key to the installed system. After reboot, the configuration is already at:

```bash
cd ~/Documents/Ezirius/Development/GitHub/Nix-Configurations
```

The repository is ready to use - secrets are decrypted, git-agecrypt is configured, and the identity path is updated for the new system.

To apply future changes:
```bash
./git.sh      # Format, validate, commit, and push
./install.sh  # Rebuild and switch
```

### Step 8: Verify Installation

```bash
# Check services
systemctl status sshd
systemctl status fail2ban

# Check secrets decrypted
sudo ls -la /run/secrets/

# Check user
whoami                    # ezirius
groups                    # ezirius wheel
echo $SHELL               # /run/current-system/sw/bin/zsh

# Check sudo
sudo whoami               # root

# Check mosh
mosh --version
```

---

## 7. Disaster Recovery

### Rollback via SSH

If SSH still works:
```bash
sudo nixos-rebuild switch --rollback
```

Or select specific generation:
```bash
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
sudo nix-env --switch-generation <number> --profile /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Rollback via Boot Menu

If OpenSSH broken but system boots (Dropbear still works for unlock):

1. SSH to Dropbear (`ssh nithra-boot`), unlock LUKS
2. At systemd-boot menu (via VNC), press arrow keys to select previous generation
3. Once booted, access via VNC, login as ezirius, fix config and redeploy

### Rollback via VNC

If network broken:

1. Access VNC via VPS provider control panel
2. Login as ezirius locally (console login)
3. `sudo nixos-rebuild switch --rollback`

### Recovery from Live ISO

If system won't boot at all:

```bash
# 1. Boot NixOS ISO, configure network (see Fresh Installation Step 1)

# 2. Unlock LUKS
sudo cryptsetup luksOpen /dev/sda2 crypted
# Enter LUKS passphrase

# 3. Activate LVM
sudo vgchange -ay pool

# 4. Mount filesystems
sudo mkdir -p /mnt/{home,nix,var/log,boot}
sudo mount -o subvol=@ /dev/pool/root /mnt
sudo mount -o subvol=@home /dev/pool/root /mnt/home
sudo mount -o subvol=@nix /dev/pool/root /mnt/nix
sudo mount -o subvol=@log /dev/pool/root /mnt/var/log
sudo mount /dev/sda1 /mnt/boot

# 5. Enter system
sudo nixos-enter --root /mnt

# 6. Rollback
nixos-rebuild switch --rollback

# 7. Or rebuild from config (if fixed)
nixos-rebuild switch --flake <repo>#nithra
```

### Re-encrypt Secrets with New Age Key

If age key is compromised or migrating to a new key:

```bash
# 1. Generate new key
nix-shell -p age --run "age-keygen -o /tmp/new-age-key.txt"

# 2. Get new public key
nix-shell -p age --run "age-keygen -y /tmp/new-age-key.txt"
# Copy output for next step

# 3. Update .sops.yaml with new public key
vim .sops.yaml  # Replace the age1... public key

# 4. Re-encrypt sops secrets
# (Must have OLD key to decrypt, will encrypt with NEW key from .sops.yaml)
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run \
  "sops updatekeys Secrets/Nithra/sops-nix.yaml"

# 5. Update git-agecrypt configuration
# Replace key and reconfigure
cp /tmp/new-age-key.txt ~/.config/git-agecrypt/keys.txt
chmod 600 ~/.config/git-agecrypt/keys.txt
git config --unset-all filter.git-agecrypt.smudge
git config --unset-all filter.git-agecrypt.clean
nix-shell -p git-agecrypt --run "git-agecrypt init"
nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"

# 6. Re-encrypt git-agecrypt secrets (touch to trigger re-encryption on commit)
git checkout -- Secrets/Nithra/git-agecrypt.nix
# Make a trivial edit (add/remove whitespace) and commit

# 7. Deploy new key to server
sudo cp /tmp/new-age-key.txt /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt

# 8. Update password manager backup with new key

# 9. Securely delete temporary key file
# Note: shred may not be effective on SSD/btrfs due to wear leveling and COW
shred -u /tmp/new-age-key.txt 2>/dev/null || rm /tmp/new-age-key.txt
```

### Lost LUKS Passphrase

**Unrecoverable.** Data is encrypted and cannot be accessed without the passphrase. Options:

1. Reinstall from scratch using Fresh Installation guide
2. Restore from backups (if any exist outside the encrypted volume)

### Generate New SSH Host Keys

If host keys are compromised or you need fresh keys:

```bash
# Generate both keys (empty passphrase)
nix-shell -p openssh --run "
  ssh-keygen -t ed25519 -N '' -f /tmp/boot_host_key
  ssh-keygen -t ed25519 -N '' -f /tmp/login_host_key
"

# Display private keys
echo "=== hostKeys.nithra_all_all_boot (for git-agecrypt.nix) ===" && cat /tmp/boot_host_key
echo "=== nithra_all_all_login (for sops-nix.yaml) ===" && cat /tmp/login_host_key

# Clean up temporary files
rm /tmp/boot_host_key /tmp/boot_host_key.pub
rm /tmp/login_host_key /tmp/login_host_key.pub

# Update secrets:
# 1. Add boot key to Secrets/Nithra/git-agecrypt.nix → hostKeys.nithra_all_all_boot
# 2. Add login key to Secrets/Nithra/sops-nix.yaml → nithra_all_all_login

# After updating both secrets files, deploy and clear client known_hosts
./install.sh
ssh-keygen -R <ip>        # On each client machine
ssh-keygen -R nithra      # Also remove by hostname if used
ssh-keygen -R nithra-boot
```

### Reinstall Bootloader

From inside `nixos-enter`:
```bash
nixos-rebuild boot --flake <repo>#nithra
```

### Emergency Access Methods

| Method | Command | When |
|--------|---------|------|
| SSH | `ssh nithra` | Normal access |
| Mosh | `mosh nithra` | Unstable/high-latency connection |
| Dropbear | `ssh nithra-boot` | LUKS unlock at boot |
| VNC | Provider control panel | Network broken, SSH broken |

### Common Issues

**SSH connection refused after deploy:**
- New config may have broken SSH
- Use VNC to access and rollback: `sudo nixos-rebuild switch --rollback`

**LUKS unlock hangs/times out:**
- Check Dropbear host key matches known_hosts
- Remove old key: `ssh-keygen -R <ip>` then retry

**System boots but can't login:**
- Boot previous generation from systemd-boot menu (VNC)
- Check if sops secrets decrypted: `sudo ls /run/secrets/`
- If empty, age key may be missing or wrong at `/var/lib/sops-nix/key.txt`

**Sudo password rejected:**
- Password hash may be wrong in sops-nix.yaml
- Boot previous generation and fix hash
- Generate new hash: `nix-shell -p mkpasswd --run "mkpasswd -m sha-512"`

**Shell not working (falls back to sh):**
- Check `programs.zsh.enable = true` in `Users/ezirius/nithra-account.nix`

**Host key verification failed:**
- Dropbear and OpenSSH have different host keys (by design)
- After reinstall or key rotation: `ssh-keygen -R <ip>` on client, then reconnect
- May need to remove both `nithra` and `nithra-boot` entries

**git-agecrypt not decrypting:**
- Check key configured: `git config --get-regexp agecrypt`
- Check key exists: `ls -la ~/.config/git-agecrypt/keys.txt`
- Reinstall filters, then re-add identity:
  ```bash
  nix-shell -p git-agecrypt --run "git-agecrypt init"
  nix-shell -p git-agecrypt --run "git-agecrypt config add -i ~/.config/git-agecrypt/keys.txt"
  ```
- Force re-checkout: `git checkout -- Secrets/Nithra/git-agecrypt.nix`

**Build fails with "git-agecrypt.nix: No such file":**
- File exists but is encrypted/binary
- Ensure git-agecrypt is configured and re-checkout the file

**Locked out by fail2ban:**
- Access via VNC (fail2ban only affects network)
- Check status: `sudo fail2ban-client status sshd`
- Unban IP: `sudo fail2ban-client set sshd unbanip <your-ip>`
- Check banned IPs: `sudo fail2ban-client get sshd banned`

**Can't connect after VPS provider maintenance:**
- Provider may have changed IP or network config
- Access via VNC to diagnose
- Check `ip addr` and compare with git-agecrypt.nix network settings

**nixos-rebuild takes forever / hangs:**
- Large updates may take 30+ minutes
- Check network connectivity: `ping 1.1.1.1`
- If stuck on "building", check disk space: `df -h`
- Can safely Ctrl+C and re-run `./install.sh`

**Git signing fails on Maldoria (1Password):**
- Check `SSH_AUTH_SOCK` points to 1Password: `echo $SSH_AUTH_SOCK`
- Should be: `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
- If wrong, check `home.sessionVariables` in `maldoria-home.nix` and restart terminal
- List available keys: `ssh-add -L` (should show keys from 1Password)
- Test signing: `echo "test" | ssh-keygen -Y sign -f ~/.ssh/maldoria_github_ezirius_sign -n git`
- Ensure the key exists in 1Password as an "SSH Key" item type (not just a note)

**git-agecrypt encrypts with wrong key:**
- git-agecrypt caches encrypted files in `.git/git-agecrypt/`
- If the cache was created with a different key, it will keep using the wrong encryption
- Fix: delete cache and reinitialize:
  ```bash
  rm -rf .git/git-agecrypt/
  nix-shell -p git-agecrypt --run "git-agecrypt init"
  ```
- Verify encryption: `git show HEAD:Secrets/<host>/git-agecrypt.nix | head -5`
- If still failing, manually encrypt and add:
  ```bash
  nix-shell -p age --run "age -e -r <pubkey> -o /tmp/encrypted.nix Secrets/<host>/git-agecrypt.nix"
  git hash-object -w /tmp/encrypted.nix  # outputs <hash>
  git update-index --add --cacheinfo 100644,<hash>,Secrets/<host>/git-agecrypt.nix
  ```

---

## 8. Security Model

### Two-Stage Access

```
┌─────────────────────────────────────────────────────────┐
│ Stage 1: Boot (Dropbear)                                │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: LUKS unlock only                           │ │
│ │ Port: 22                                            │ │
│ │ User: root                                          │ │
│ │ Keys: command="systemd-tty-ask-password-agent"       │ │
│ │ Timeout: Disabled (waits indefinitely)              │ │
│ └─────────────────────────────────────────────────────┘ │
│                         │                               │
│                         ▼                               │
│ Stage 2: Runtime (OpenSSH)                              │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Purpose: Administration                             │ │
│ │ Ports: 22/tcp (SSH), 60000-61000/udp (Mosh)         │ │
│ │ User: ezirius only (root disabled)                  │ │
│ │ Auth: Public key only (passwords disabled)          │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### SSH Hardening

| Setting | Value | Effect |
|---------|-------|--------|
| PermitRootLogin | no | Root cannot SSH |
| PasswordAuthentication | no | Keys only |
| KbdInteractiveAuthentication | no | No keyboard auth |
| AllowUsers | ezirius | Whitelist |
| AuthenticationMethods | publickey | Keys only |
| X11Forwarding | no | No X11 |
| AllowTcpForwarding | no | No tunnels |
| AllowAgentForwarding | no | No agent |
| AllowStreamLocalForwarding | no | No sockets |

### Kernel Hardening

| Category | Settings |
|----------|----------|
| Memory | protectKernelImage, kptr_restrict=2 |
| Debug | dmesg_restrict=1, perf_event_paranoid=3 |
| Process | ptrace_scope=2, unprivileged_bpf_disabled=1 |
| BPF | bpf_jit_harden=2 |
| Network | No redirects, no source routing, SYN cookies, RP filter |

### Additional Protections

- **fail2ban** - Brute-force protection (auto-bans IPs after failed attempts)
- **Firewall** - SSH implicit, Mosh explicit, all else blocked
- **LUKS** - Full disk encryption (AES with hardware acceleration via aesni_intel)
- **Separate host keys** - Different keys for Dropbear and OpenSSH (if one is compromised, attacker can't impersonate the other stage)
- **Managed host keys** - No auto-generated keys, Dropbear key in git-agecrypt.nix, OpenSSH key in sops-nix.yaml

---

## 9. Reference

### Repository Structure

```
<repo>/
├── flake.nix                 # Entry point, nixosConfigurations, formatter
├── flake.lock                # Pinned input versions
├── install.sh                # Deploy script (ensures keys, stages, builds)
├── git.sh                    # Git script (formats, validates, stages, commits, pushes)
├── clone.sh                  # Fresh install script (clone, decrypt, setup)
├── partition.sh              # Disk partitioning script (wipes disk, runs disko)
├── .gitignore                # Excludes .DS_Store
├── .gitattributes            # git-agecrypt filter for git-agecrypt.nix files
├── .sops.yaml                # sops-nix age key configuration
├── git-agecrypt.toml         # git-agecrypt recipient configuration
├── opencode.json             # AI agent tool permissions (OpenCode)
├── AGENTS.md                 # AI agent instructions
├── README.md                 # This file
├── Hosts/
│   ├── Maldoria/
│   │   └── default.nix       # Darwin host config (sops refs, packages)
│   └── Nithra/
│       ├── default.nix       # NixOS host config (network, boot, sops refs)
│       └── disko-config.nix  # Disk layout (GPT, LUKS, LVM, Btrfs)
├── Secrets/
│   ├── Maldoria/
│   │   ├── git-agecrypt.nix  # Encrypted: Nithra IP, Nithra SSH host keys
│   │   └── sops-nix.yaml     # Encrypted: GitHub keys, Nithra SSH keys (for 1Password), SSH login keys
│   └── Nithra/
│       ├── git-agecrypt.nix  # Encrypted: network, Dropbear host key, Dropbear authorised keys, SSH login pubkeys
│       └── sops-nix.yaml     # Encrypted: passwords, OpenSSH host key, GitHub SSH keys
└── Users/
    ├── ezirius/
    │   ├── nithra-account.nix   # System user (groups, shell, auth) - NixOS
    │   ├── nithra-home.nix      # Home-manager for Nithra (NixOS)
    │   └── maldoria-home.nix    # Home-manager for Maldoria (macOS)
    └── root/
        ├── nithra-account.nix   # Root user config - NixOS
        └── nithra-home.nix      # Root home-manager - NixOS
```

### Storage Layout

```
/dev/sda
├── sda1: ESP (1GB, FAT32) → /boot
└── sda2: LUKS
    └── LVM "pool"
        ├── swap (4GB)
        └── root (Btrfs, remaining space)
            ├── @ → /
            ├── @home → /home
            ├── @nix → /nix
            └── @log → /var/log

Mount options: compress=zstd,noatime,discard=async
LUKS: allowDiscards=true (SSD TRIM passthrough)
```

### Network

| Setting | Value |
|---------|-------|
| IP/Gateway/Prefix | See git-agecrypt.nix |
| DNS | 1.1.1.1, 8.8.8.8 |
| Interface | ens18 (VirtIO) |
| DHCP | Disabled |

### Packages

See the actual config files for current package lists (these change frequently):

- **System packages**: `Hosts/<host>/default.nix` → `environment.systemPackages`
- **User packages**: `Users/<user>/<host>-home.nix` → `home.packages`
- **Program modules**: `Users/<user>/<host>-home.nix` → `programs.*`

### Flake Inputs

| Input | Source | Purpose |
|-------|--------|---------|
| nixpkgs | [nixos-unstable](https://github.com/NixOS/nixpkgs) | Package repository |
| disko | [nix-community/disko](https://github.com/nix-community/disko) | Declarative disk partitioning (NixOS) |
| home-manager | [nix-community/home-manager](https://github.com/nix-community/home-manager) | User environment management |
| sops-nix | [Mic92/sops-nix](https://github.com/Mic92/sops-nix) | Runtime secrets decryption |
| nix-darwin | [LnL7/nix-darwin](https://github.com/LnL7/nix-darwin) | macOS system configuration |

All inputs follow nixpkgs (`inputs.nixpkgs.follows = "nixpkgs"`) to avoid version conflicts.

### Automatic Maintenance

| Task | Schedule | Description |
|------|----------|-------------|
| Garbage Collection | Monday 06:00 | Deletes derivations older than 30 days |
| Store Optimisation | Automatic | Hard-links duplicate files in /nix/store |
| Btrfs Scrub | Monthly | Verifies checksums on `/` filesystem |
| Journal Rotation | Continuous | Limits to 500MB, deletes entries older than 1 month |

### Locale

| Setting | Nithra | Maldoria |
|---------|--------|----------|
| Timezone | `secrets.locale.timeZone` | `secrets.locale.timeZone` |
| Locale | `secrets.locale.defaultLocale` | macOS managed |

### Boot

| Setting | Value |
|---------|-------|
| Bootloader | systemd-boot |
| Max Generations | 10 |
| LUKS Timeout | Disabled (indefinite) |
| Initrd | systemd-based |
| Network Reset | flushBeforeStage2 |

### Maldoria (Darwin) Specifics

| Setting | Value |
|---------|-------|
| Platform | macOS (nix-darwin) |
| Architecture | aarch64-darwin (Apple Silicon) |
| Storage | APFS (managed by macOS) |
| Network | DHCP (managed by macOS) |
| Firewall | Application Firewall (incoming only) |

**Security:**
- Application Firewall with stealth mode
- SSH server (keys only, no root, AllowUsers ezirius)
- Touch ID for sudo authentication
- 1Password SSH agent for key management

**1Password Integration:**
- SSH agent: `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
- Public keys deployed to `~/.ssh/` via sops
- Private keys remain in 1Password vault
- Agent matches public keys to vault entries automatically

**Key differences from NixOS:**

| Aspect | NixOS (Nithra) | Darwin (Maldoria) |
|--------|----------------|-------------------|
| SSH login keys | git-agecrypt.nix | sops-nix.yaml (templates) |
| SSH private keys | sops-nix (files) | 1Password vault |
| Firewall | nftables + fail2ban | Application Firewall |
| User creation | Declarative | Manual (System Settings) |
| Disk encryption | LUKS | FileVault (managed by macOS) |

### Remote Desktop (Virtual Display)

Headless remote GUI via RustDesk, running in virtual X display `:1`. Physical display shows TTY only.

**Services:**
| Service | Description |
|---------|-------------|
| `virtual-desktop` | Xvnc on display `:1` (localhost only) |
| `virtual-i3` | i3 window manager in virtual display |
| `virtual-rustdesk` | RustDesk capturing virtual display |

**Initial Setup:** RustDesk requires manual configuration on first run. Access via VNC to set the permanent password and note the RustDesk ID for client connections.

**i3 Keybinds:** See `Users/ezirius/nithra-home.nix` → `xsession.windowManager.i3.config` for current keybinds. Uses `alt` modifier with vim-style navigation.

### Key File Locations

| File | Purpose |
|------|---------|
| `/var/lib/sops-nix/key.txt` | Age private key (sops-nix) |
| `~/.config/git-agecrypt/keys.txt` | Age private key (git-agecrypt) |
| `/run/secrets/*` | sops-nix decrypted secrets (tmpfs, runtime only) |
| (in initrd, via Nix store) | Dropbear host key |
| `/etc/ssh/ssh_host_ed25519_key` | OpenSSH host key |
| `/home/ezirius/.ssh/<host>_github_ezirius_nix-configurations` | GitHub SSH key (Nithra: private key, Maldoria: public key for 1Password) |
| `/home/ezirius/.ssh/<host>_github_ezirius_sign` | Git signing key (Nithra: private key, Maldoria: public key for 1Password) |

### Quick Reference Commands

```bash
# Deploy changes
./install.sh

# Commit and push (without rebuilding)
./git.sh

# Update all packages
nix flake update && ./install.sh

# Edit sops secrets
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix-shell -p sops --run "sops Secrets/Nithra/sops-nix.yaml"

# Check current generation
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback
sudo nixos-rebuild switch --rollback

# Check if reboot needed
[ "$(readlink /run/booted-system/kernel)" = "$(readlink /nix/var/nix/profiles/system/kernel)" ] || echo "Reboot required"

# Format nix files
nix fmt

# Validate without building
nix flake check
```

---

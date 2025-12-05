# Nix Configurations - Agent Instructions

## Agent Rules

- Be concise
- Use British English spelling (e.g. colour, organisation, licence)
- Use metric units
- **Always ask for explicit approval before making any file changes** - describe proposed changes first, wait for user confirmation, then implement
- Never read files or directories containing "secret" or "secrets" in the path (case-insensitive rule)
- Never read files known to contain sensitive information, including:
  - Private keys (SSH, GPG, age, etc.)
  - Passwords or password hashes
  - API keys or tokens
  - Certificates
  - Environment files with credentials (.env)
  - Encryption keys
  - Authentication credentials
  - Personal identification information
- Before pushing to GitHub, check for exposed sensitive information in all modified files (while still following the rules above)
- Use past tense in commit messages (e.g. "Added feature" not "Add feature")

## Critical Facts

1. **Git staging required** - Flakes only see staged files. `./install.sh` auto-stages, but `nix flake check` does not.

2. **Two secrets layers:**
   - `Secrets/<host>/git-agecrypt.nix` → git-agecrypt → needed at eval/build time (network config, Dropbear host key, Dropbear authorised keys, SSH login pubkeys on NixOS)
   - `Secrets/<host>/sops-nix.yaml` → sops-nix → decrypted at activation time (passwords, OpenSSH host key, GitHub SSH keys, SSH login pubkeys on Darwin)
   
   **Platform difference:** NixOS needs login pubkeys in git-agecrypt (`authorizedKeys.keys` requires eval-time values). Darwin uses sops templates (`authorized_keys` file written at activation).

3. **git-agecrypt.nix is DECRYPTED LOCALLY - this is correct!** Locally it's plaintext (required for Nix to import it); git-agecrypt encrypts on commit.

4. **Remote LUKS server** - Breaking SSH/network config locks out the user. Always warn before such changes.

5. **git-agecrypt.nix is a Nix file** - Imported directly with `import ../../Secrets/<host>/git-agecrypt.nix`, not via sops. Values accessed as `secrets.network.nithraIp`, etc.

6. **Use git, not jj** - jj doesn't support .gitattributes filters, so git-agecrypt won't encrypt.

7. **Secrets placement principle** - All system-identifying information (IPs, keys, etc.) is sensitive. Prefer sops-nix over git-agecrypt when possible. Use git-agecrypt only when values are needed at Nix evaluation time or build time (before sops-nix runs).

## Quick Reference

See `README.md` for detailed procedures. Key naming convention: `[from]_[to]_[user]_[type]`

**Key configuration files:**
- `.sops.yaml` - sops-nix age public key (for encrypting sops-nix.yaml)
- `git-agecrypt.toml` - git-agecrypt age public key (for encrypting git-agecrypt.nix)

**Essential commands:**
```bash
./git.sh                                  # Format, validate, commit, and push
./install.sh [host]                       # Build and switch
nix flake check                           # Validate flake (requires git add first)
```

## Code Patterns

### Packages (correct)
```nix
environment.systemPackages = builtins.attrValues {
  inherit (pkgs)
    curl
    git
    vim
    ;
};
```

### Packages (wrong - do not use)
```nix
environment.systemPackages = with pkgs; [ curl git vim ];
```

### Home-manager packages
```nix
{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs) package1 package2;
  };
}
```

### Sops secret reference
```nix
# In Hosts/Nithra/default.nix:
sops.secrets.mySecret = { };
sops.secrets.myPassword.neededForUsers = true;  # For user passwords

# In Hosts/<host>/default.nix or Users/<user>/<host>-account.nix (note: needs config in function args):
{ config, ... }:
{
  users.users.<user>.hashedPasswordFile = config.sops.secrets.<user>Password.path;
}
```

### SSH login key from git-agecrypt (NixOS)
```nix
# In Hosts/Nithra/default.nix:
users.users.<user>.openssh.authorizedKeys.keys = [
  secrets.loginKeysPub.ipsa_nithra_ezirius_login
  secrets.loginKeysPub.maldoria_nithra_ezirius_login
];
```

**Note:** On NixOS, SSH login keys must be in git-agecrypt.nix (not sops) because `authorizedKeys.keys` needs values at Nix evaluation time.

### SSH login key from sops (Darwin)
```nix
# In Hosts/Maldoria/default.nix:
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
```

**Note:** On Darwin, nix-darwin lacks `users.users.<name>.openssh.authorizedKeys`, so use sops templates instead. This follows the secrets placement principle (prefer sops over git-agecrypt when possible).

### GitHub SSH private key from sops
```nix
# In Hosts/Nithra/default.nix:
sops.secrets.nithra_github_ezirius_nix-configurations = {
  owner = "ezirius";
  path = "/home/ezirius/.ssh/nithra_github_ezirius_nix-configurations";
  mode = "0600";
};
```

**Note:** Files referencing `config.sops.secrets.*` need `config` in their function arguments.

### i3status (home-manager)
```nix
programs.i3status = {
  enable = true;
  enableDefault = false;  # Disable battery/wifi/volume for VPS
  modules = {
    cpu_usage = { position = 1; settings = { format = "CPU: %usage"; }; };
    "disk /" = { position = 2; settings = { format = "Disk: %avail"; }; };
    "ethernet ens18" = { position = 3; settings = { format_up = "E: %ip"; }; };
  };
};
```

**Note:** Module names include instance identifiers (e.g. `"disk /"`, `"ethernet ens18"`). Modules without instances: `cpu_usage`, `memory`, `load`.

## Formatter

The formatter in `flake.nix` excludes `Secrets/` because git-agecrypt files are encrypted - formatting would corrupt them. This is intentional and required.

## Handling Secrets Modifications

Since you cannot read `Secrets/` files, when the user needs to modify secrets:

1. **Describe the change needed** - Tell the user exactly what to add/modify and where
2. **Provide the exact format** - Show the Nix or YAML syntax they should use
3. **Reference README procedures** - Point to `README.md` Section 4 or 5 for detailed steps
4. **Remind about encryption** - For sops-nix.yaml, remind them to use the sops command; for git-agecrypt.nix, it auto-encrypts on commit

**Example response for adding a new SSH login key:**
> "To add this key, edit `Secrets/Nithra/git-agecrypt.nix` and add to `loginKeysPub`:
> ```nix
> newmachine_nithra_ezirius_login = "ssh-ed25519 AAAA...";
> ```
> Then add the reference in `Hosts/Nithra/default.nix`. See README Section 4 'Add SSH Key for Login' for full steps."

## Do NOT

- Use `with pkgs;` pattern - use `builtins.attrValues { inherit (pkgs) ...; }`
- On NixOS, forget that SSH login keys are in git-agecrypt.nix (sops paths don't exist at eval time); on Darwin, use sops templates
- Remove users from `AllowUsers` without confirming alternative access exists
- Disable `fail2ban` or firewall without explicit permission
- Hardcode IPs - use `git-agecrypt.nix` network values
- Add line number references in documentation - they break when code changes
- Run `nix flake update` without warning about potential breaking changes
- Create new files unless absolutely necessary - prefer editing existing files
- Implement functionality in scripts that should be declarative in the flake - scripts are for bootstrapping and orchestration only

## Repository Structure

See `README.md` for full repository structure, common tasks, and detailed documentation.

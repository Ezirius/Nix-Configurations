# Maldoria-specific home-manager configuration for ezirius
# Shared settings are in common-ezirius-home.nix
{ lib, pkgs, ... }:
let
  secrets = import ../../Private/Common/git-agecrypt.nix;
  pubkeys = import ../../Public/Maldoria/keys.nix;
  common = import ../../Public/Common/keys.nix;
  username = "ezirius";
  homeDir = "/Users/${username}";
in
{
  imports = [ ../Common/common-ezirius-home.nix ];

  home.stateVersion = "24.11";
  home.username = username;
  home.homeDirectory = lib.mkForce homeDir;

  # --- 1PASSWORD SSH AGENT ---
  # Note: This merges with sessionVariables from common-all-home.nix (VISUAL, LESS)
  home.sessionVariables.SSH_AUTH_SOCK = "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";

  # --- SSH CONFIG ---
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      # Global defaults - 1Password agent and hardened algorithms matching server config
      "*" = {
        serverAliveInterval = 60;
        serverAliveCountMax = 3;
        extraOptions = {
          IdentityAgent = "\"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\"";
          KexAlgorithms = "mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org";
          Ciphers = "chacha20-poly1305@openssh.com";
          MACs = "hmac-sha2-512-etm@openssh.com";
        };
      };
      "maldoria-github-ezirius-nix-configurations" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/maldoria_github_ezirius_nix-configurations";
        identitiesOnly = true;
        extraOptions.HostKeyAlias = "maldoria-github-ezirius-nix-configurations";
      };
      "maldoria-nithra-root-boot" = {
        hostname = secrets.network.nithraIp;
        user = "root";
        identityFile = "~/.ssh/maldoria_nithra_root_boot";
        identitiesOnly = true;
        extraOptions.HostKeyAlias = "maldoria-nithra-root-boot";
      };
      "maldoria-nithra-ezirius-login" = {
        hostname = secrets.network.nithraIp;
        user = "ezirius";
        identityFile = "~/.ssh/maldoria_nithra_ezirius_login";
        identitiesOnly = true;
        extraOptions.HostKeyAlias = "maldoria-nithra-ezirius-login";
      };
    };
  };

  # --- KNOWN HOSTS ---
  # GitHub keys: from Public/Common/keys.nix
  # Nithra keys: from Public/Maldoria/keys.nix
  home.file.".ssh/known_hosts".text = ''
    maldoria-github-ezirius-nix-configurations ${common.hostKeysPub.github.ed25519}
    maldoria-github-ezirius-nix-configurations ${common.hostKeysPub.github.rsa}
    maldoria-github-ezirius-nix-configurations ${common.hostKeysPub.github.ecdsa}
    maldoria-nithra-root-boot ${pubkeys.hostKeysPub.nithra_all_all_boot}
    maldoria-nithra-ezirius-login ${pubkeys.hostKeysPub.nithra_all_all_login}
  '';

  # --- JUJUTSU (host-specific signing) ---
  programs.jujutsu.settings.signing = {
    backend = "ssh";
    key = "~/.ssh/maldoria_github_ezirius_sign";
    sign-all = true;
  };

  # --- GIT (host-specific signing, includes, and 1Password SSH program) ---
  programs.git = {
    signing = {
      key = "~/.ssh/maldoria_github_ezirius_sign";
      signByDefault = true;
    };
    includes = [
      {
        condition = "gitdir:~/Documents/Ezirius/Development/GitHub/Nix-Configurations/";
        contents = {
          url."git@maldoria-github-ezirius-nix-configurations:".insteadOf = "git@github.com:";
        };
      }
    ];
    settings = {
      # 1Password SSH signing program (macOS-specific)
      gpg.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    };
  };

  # --- TERMINAL ---
  programs.ghostty = {
    enable = true;
    package = pkgs.ghostty-bin;
    enableZshIntegration = true;
    settings = {
      font-family = "JetBrainsMono Nerd Font";
      font-size = 14;
      theme = "catppuccin-mocha";
      window-padding-x = 8;
      window-padding-y = 8;
      window-decoration = true;
      mouse-hide-while-typing = true;
      cursor-style = "block";
      cursor-style-blink = false;
      copy-on-select = true;
      clipboard-trim-trailing-spaces = true;
      shell-integration = "detect";
      scrollback-limit = 10000;
      confirm-close-surface = false; # Don't prompt on close
      bold-is-bright = false; # Use actual bold font
    };
  };
}

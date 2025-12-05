{ pkgs, config, ... }:
let
  secrets = import ../../Secrets/Maldoria/git-agecrypt.nix;
  username = "ezirius";
  homeDir = "/Users/${username}";
in
{
  networking.hostName = "maldoria";

  # --- TIMEZONE ---
  time.timeZone = secrets.locale.timeZone;

  # --- FIREWALL ---
  networking.applicationFirewall = {
    enable = true;
    allowSigned = true; # Apple services (AirDrop, Handoff)
    allowSignedApp = false; # Prompt for third-party apps
    enableStealthMode = true; # Don't respond to probes
  };

  # --- SSH SERVER (HARDENED) ---
  services.openssh = {
    enable = true;
    extraConfig = ''
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthenticationMethods publickey
      AllowUsers ${username}
      X11Forwarding no
      AllowTcpForwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      StrictModes no
    '';
  };
  system.stateVersion = 5;
  nix.enable = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    interval = {
      Weekday = 1;
      Hour = 6;
      Minute = 0;
    };
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  # --- TOUCH ID FOR SUDO ---
  security.pam.services.sudo_local.touchIdAuth = true;

  # --- DEFAULT EDITOR ---
  environment.variables.EDITOR = "vim";

  programs.zsh.enable = true;

  # --- ENSURE ~/.ssh/ EXISTS WITH CORRECT OWNERSHIP ---
  # Sops-nix creates parent directories as root; this ensures correct ownership
  system.activationScripts.postActivation.text = ''
    mkdir -p ${homeDir}/.ssh
    chown ${username}:staff ${homeDir}/.ssh
    chmod 700 ${homeDir}/.ssh
  '';

  # --- SOPS ---
  sops.defaultSopsFile = ../../Secrets/Maldoria/sops-nix.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets.maldoria_github_ezirius_nix-configurations = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_github_ezirius_nix-configurations";
    mode = "0600";
  };

  sops.secrets.maldoria_github_ezirius_sign = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_github_ezirius_sign";
    mode = "0600";
  };

  # Nithra SSH public keys (1Password matches these to provide private keys)
  sops.secrets.maldoria_nithra_root_boot = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_nithra_root_boot";
    mode = "0600";
  };

  sops.secrets.maldoria_nithra_ezirius_login = {
    owner = username;
    path = "${homeDir}/.ssh/maldoria_nithra_ezirius_login";
    mode = "0600";
  };

  # --- SSH LOGIN KEYS (for logging INTO this Mac) ---
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

  environment.systemPackages = builtins.attrValues {
    inherit (pkgs)
      # --- Essential ---
      curl # HTTP client
      git # Version control
      vim # Editor

      # --- Remote Access ---
      mosh # Mobile shell - UDP transport after SSH auth, survives IP changes (vs SSH: TCP, drops on network change)
      tmux # Terminal multiplexer - persistent sessions, window splits

      # --- Modern Replacements ---
      bat # cat replacement - syntax highlighting, git integration (vs cat: plain output)
      btop # Process monitor - unified CPU/memory/disk/network view (vs htop: tabbed interface)
      eza # ls replacement - git status column, built-in tree (vs ls/tree: separate tools, no git)
      fd # find replacement - parallel, .gitignore-aware, simpler syntax (vs find: sequential, verbose flags)
      gdu # Disk usage analyser - interactive TUI, can delete (vs ncdu: slower, vs dust: non-interactive)
      procs # Process viewer - colour output, tree view, docker-aware (vs ps: minimal formatting)
      ripgrep # Content search - fastest grep, .gitignore-aware (vs grep: slower, searches everything)
      sd # String replacer - literal syntax `sd 'old' 'new'` (vs sed: regex escaping required)
      zoxide # Directory jumper - frecency-based `z foo` (vs cd: full path required)

      # --- Development Tools ---
      delta # Git pager - syntax highlighting, side-by-side, word-level diffs (vs default pager: no highlighting)
      fzf # Fuzzy finder - Ctrl+R history, Ctrl+T files, integrates with fd/ripgrep/bat
      jaq # JSON processor - 10-30x faster (vs jq: slower on large files, same syntax)
      jujutsu # Git-compatible VCS - automatic rebasing, no index (vs git: manual staging, conflict-prone rebases)
      # opencode - not available on Darwin
      tealdeer # Command examples - concise with examples (vs man: comprehensive reference)

      # --- System Administration ---
      rsync # File sync - delta transfers, --delete propagates deletions

      # --- Network Diagnostics ---
      dog # DNS client - coloured output, DoH/DoT support (vs dig: plain output, no encrypted DNS)
      trippy # Network diagnostics - live TUI, per-hop latency graphs (vs traceroute: single static output)
      ;
  };
}

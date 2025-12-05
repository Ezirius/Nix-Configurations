{
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  secrets = import ../../Secrets/Nithra/git-agecrypt.nix;
  # Initrd host key must be in Nix store (available at build time, not activation time)
  initrdHostKey = pkgs.writeText "nithra_all_all_boot" secrets.hostKeys.nithra_all_all_boot;
in
{
  imports = [
    ./disko-config.nix
    ../../Users/root/nithra-account.nix
    ../../Users/ezirius/nithra-account.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "nithra";
  system.stateVersion = "24.11";

  # --- LOCALE & TIMEZONE ---
  time.timeZone = secrets.locale.timeZone;
  i18n.defaultLocale = secrets.locale.defaultLocale;

  # --- SYSTEM PACKAGES ---
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
      opencode # AI coding assistant - terminal-native, agentic
      tealdeer # Command examples - concise with examples (vs man: comprehensive reference)

      # --- System Administration ---
      rsync # File sync - delta transfers, --delete propagates deletions

      # --- Network Diagnostics ---
      dog # DNS client - coloured output, DoH/DoT support (vs dig: plain output, no encrypted DNS)
      trippy # Network diagnostics - live TUI, per-hop latency graphs (vs traceroute: single static output)

      # --- Remote Desktop (Virtual Display) ---
      ghostty # Terminal emulator - GPU-accelerated, Kitty protocol support
      dmenu # Application launcher - minimal, keyboard-driven
      rustdesk-flutter # Remote desktop - open source, self-hostable (vs TeamViewer/AnyDesk: closed source, third-party servers)
      tigervnc # VNC server - provides Xvnc virtual display
      i3status # Status bar - lightweight, i3bar-compatible
      ;
  };

  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "Mon 06:00";
    options = "--delete-older-than 30d";
  };
  nix.settings.auto-optimise-store = true; # Hardlink duplicate files in store

  # --- DEFAULT EDITOR ---
  environment.variables.EDITOR = "vim";

  # --- FILESYSTEM MAINTENANCE ---
  boot.tmp.cleanOnBoot = true; # Clear /tmp on reboot (security: removes stale credentials, temp files)
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
  # Note: SSD TRIM handled by discard=async mount option on Btrfs

  # --- LOGGING ---
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  # --- FIREWALL ---
  networking.firewall = {
    enable = true;
    # SSH (22/tcp) is implicitly opened by services.openssh.openFirewall (default: true)
    # Mosh needs UDP 60000-61000
    allowedUDPPortRanges = [
      {
        from = 60000;
        to = 61000;
      }
    ];
  };

  # --- FAIL2BAN (Brute-force Protection) ---
  services.fail2ban.enable = true;

  # --- SSH (MAXIMUM SECURITY) ---
  services.openssh = {
    enable = true;
    settings = {
      # 1. Root CANNOT log in via SSH (Forces you to use Ezirius -> Sudo)
      PermitRootLogin = "no";

      # 2. No Passwords allowed. Keys Only.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;

      # 3. Additional Hardening
      X11Forwarding = false;
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      AuthenticationMethods = "publickey";

      # 4. Restrict SSH access to specific users
      AllowUsers = [ "ezirius" ];
    };
  };

  # --- REMOTE DESKTOP (Virtual Display Only) ---
  # Physical display shows TTY console only - no GUI
  # RustDesk session runs in virtual Xvnc framebuffer
  services.xserver = {
    enable = true;
    displayManager.startx.enable = true; # No display manager, no physical GUI
    windowManager.i3.enable = true;
  };

  # Systemd service: auto-start virtual X session
  systemd.services.virtual-desktop = {
    description = "Virtual X Desktop (Xvnc + i3)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStart = "${pkgs.tigervnc}/bin/Xvnc :1 -geometry 1920x1080 -depth 24 -localhost yes"; # -localhost yes binds to 127.0.0.1 only (RustDesk uses X11 directly)
      Restart = "always";
      RestartSec = 3;
    };
  };

  # Systemd service: start i3 in virtual display
  systemd.services.virtual-i3 = {
    description = "i3 Window Manager in Virtual Display";
    after = [ "virtual-desktop.service" ];
    bindsTo = [ "virtual-desktop.service" ]; # Stop if Xvnc stops
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'n=0; while [ ! -e /tmp/.X11-unix/X1 ] && [ $n -lt 60 ]; do sleep 0.5; n=$((n+1)); done; [ -e /tmp/.X11-unix/X1 ]'"; # Wait for Xvnc socket (max 30s)
      ExecStart = "${pkgs.i3}/bin/i3";
      Restart = "always";
      RestartSec = 3;
    };
    environment.DISPLAY = ":1";
  };

  # Systemd service: start RustDesk in virtual display
  systemd.services.virtual-rustdesk = {
    description = "RustDesk in Virtual Display";
    after = [ "virtual-i3.service" ];
    bindsTo = [ "virtual-i3.service" ]; # Stop if i3 stops
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ezirius";
      Type = "simple";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'n=0; while ! ${pkgs.i3}/bin/i3-msg get_version &>/dev/null && [ $n -lt 60 ]; do sleep 0.5; n=$((n+1)); done'"; # Wait for i3 IPC socket (max 30s)
      ExecStart = "${pkgs.rustdesk-flutter}/bin/rustdesk --service";
      Restart = "always";
      RestartSec = 3;
    };
    environment.DISPLAY = ":1";
  };

  # --- KERNEL HARDENING ---
  security.protectKernelImage = true; # Prevent /dev/mem and /dev/kmem access

  boot.kernel.sysctl = {
    # Network hardening
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;
    "net.ipv4.conf.all.rp_filter" = 1; # Reverse path filtering (anti-spoofing)
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.tcp_syncookies" = 1; # SYN flood protection

    # Kernel hardening
    "kernel.kptr_restrict" = 2; # Hide kernel pointers from unprivileged users
    "kernel.dmesg_restrict" = 1; # Restrict dmesg to root
    "kernel.perf_event_paranoid" = 3; # Restrict perf to root
    "kernel.yama.ptrace_scope" = 2; # Restrict ptrace to root
    "kernel.unprivileged_bpf_disabled" = 1; # Disable unprivileged BPF
    "net.core.bpf_jit_harden" = 2; # Harden BPF JIT compiler
  };

  # --- SOPS ---
  sops.defaultSopsFile = ../../Secrets/Nithra/sops-nix.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets.rootPassword.neededForUsers = true;
  sops.secrets.eziriusPassword.neededForUsers = true;

  sops.secrets.nithra_github_ezirius_nix-configurations = {
    owner = "ezirius";
    path = "/home/ezirius/.ssh/nithra_github_ezirius_nix-configurations";
    mode = "0600";
  };

  sops.secrets.nithra_github_ezirius_sign = {
    owner = "ezirius";
    path = "/home/ezirius/.ssh/nithra_github_ezirius_sign";
    mode = "0600";
  };

  # --- ENSURE ~/.ssh/ EXISTS WITH CORRECT OWNERSHIP ---
  # Sops-nix creates parent directories as root; this ensures home-manager can write ~/.ssh/config
  systemd.tmpfiles.rules = [
    "d /home/ezirius/.ssh 0700 ezirius users -"
  ];

  # --- SSH LOGIN KEYS (from git-agecrypt, available at eval time) ---
  users.users.ezirius.openssh.authorizedKeys.keys = [
    secrets.loginKeysPub.ipsa_nithra_ezirius_login
    secrets.loginKeysPub.ipirus_nithra_ezirius_login
    secrets.loginKeysPub.maldoria_nithra_ezirius_login
  ];

  # --- FILESYSTEM ---
  # /var/log needs to be available early for proper boot logging
  fileSystems."/var/log".neededForBoot = true;

  # --- HOST KEYS ---
  # OpenSSH host key - disable auto-generation, use our managed key from sops
  services.openssh.hostKeys = [ ];
  sops.secrets.nithra_all_all_login = {
    path = "/etc/ssh/ssh_host_ed25519_key";
    mode = "0600";
  };

  # --- KERNEL MODULES ---
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sd_mod"
    "sr_mod"
    "aesni_intel"
    "cryptd" # Hardware AES acceleration for faster LUKS
  ];

  # --- DROPBEAR (SSH Unlock) ---
  boot.initrd.systemd.enable = true;
  boot.initrd.network = {
    enable = true;
    flushBeforeStage2 = true;
    ssh = {
      enable = true;
      port = 22;
      hostKeys = [ initrdHostKey ]; # Nix store path (available at build time)
      authorizedKeys = [
        secrets.bootKeysPub.ipsa_nithra_root_boot
        secrets.bootKeysPub.ipirus_nithra_root_boot
        secrets.bootKeysPub.maldoria_nithra_root_boot
      ];
    };
  };

  # --- INITRD NETWORK (Static IP for Dropbear via systemd-networkd) ---
  # kernel ip= param doesn't work with systemd initrd, use systemd-networkd instead
  boot.initrd.systemd.network = {
    enable = true;
    networks."10-ens18" = {
      matchConfig.Name = "ens18";
      networkConfig = {
        Address = "${secrets.network.nithraIp}/${toString secrets.network.nithraPrefixLength}";
        Gateway = secrets.network.nithraGateway;
        DHCP = "no";
      };
    };
  };

  boot.kernelParams = [
    "rd.luks.options=timeout=0" # Prevent 90s timeout during unlock
  ];

  # --- OS NETWORK (Static IP for Main System) ---
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = secrets.network.nithraIp;
      prefixLength = secrets.network.nithraPrefixLength;
    }
  ];
  networking.defaultGateway = secrets.network.nithraGateway;
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # --- BOOTLOADER ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Limit boot entries to prevent /boot filling up
  boot.loader.efi.canTouchEfiVariables = true;
}

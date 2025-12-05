{ pkgs, ... }:
{
  home.stateVersion = "24.11";
  home.username = "ezirius";
  home.homeDirectory = "/home/ezirius";

  # SSH config for GitHub
  # Private key is managed by sops-nix at ~/.ssh/nithra_github_ezirius_nix-configurations
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "nithra-github-ezirius-nix-configurations" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/nithra_github_ezirius_nix-configurations";
        identitiesOnly = true;
        extraOptions.HostKeyAlias = "nithra-github-ezirius-nix-configurations";
      };
    };
  };

  # GitHub known host keys (declarative, using HostKeyAlias)
  # Verify at: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  home.file.".ssh/known_hosts".text = ''
    nithra-github-ezirius-nix-configurations ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    nithra-github-ezirius-nix-configurations ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
    nithra-github-ezirius-nix-configurations ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
  '';

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        name = "Ezirius";
        email = "66864416+ezirius@users.noreply.github.com";
      };
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
  };

  programs.git = {
    enable = true;
    signing = {
      key = "~/.ssh/nithra_github_ezirius_sign";
      signByDefault = true;
    };
    includes = [
      {
        condition = "gitdir:~/Documents/Ezirius/Development/GitHub/Nix-Configurations/";
        contents = {
          url."git@nithra-github-ezirius-nix-configurations:".insteadOf = "git@github.com:";
        };
      }
    ];
    settings = {
      gpg.format = "ssh";
      user = {
        name = "Ezirius";
        email = "66864416+ezirius@users.noreply.github.com";
      };
    };
  };

  # --- i3STATUS (VPS-appropriate status bar) ---
  programs.i3status = {
    enable = true;
    enableDefault = false; # VPS has no battery/wifi/volume

    general = {
      colors = true;
      color_good = "#50fa7b";
      color_degraded = "#f1fa8c";
      color_bad = "#ff5555";
      interval = 5;
    };

    modules = {
      cpu_usage = {
        position = 1;
        settings = {
          format = "CPU: %usage";
          degraded_threshold = 50;
          max_threshold = 80;
        };
      };

      memory = {
        position = 2;
        settings = {
          format = "RAM: %percentage_used";
          threshold_degraded = "20%";
          threshold_critical = "10%";
        };
      };

      "disk /" = {
        position = 3;
        settings = {
          format = "Disk: %avail";
          low_threshold = 10;
          threshold_type = "percentage_avail";
        };
      };

      load = {
        position = 4;
        settings = {
          format = "Load: %1min";
          max_threshold = 4;
        };
      };

      "ethernet ens18" = {
        position = 5;
        settings = {
          format_up = "E: %ip";
          format_down = "E: down";
        };
      };

      "tztime local" = {
        position = 6;
        settings = {
          format = "%Y-%m-%d %H:%M";
        };
      };
    };
  };

  # --- i3 WINDOW MANAGER (AeroSpace-compatible keybinds) ---
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = "Mod1"; # Alt key
      terminal = "ghostty";
      keybindings =
        let
          mod = "Mod1";
        in
        {
          # Focus (h/j/k/l)
          "${mod}+h" = "focus left";
          "${mod}+j" = "focus down";
          "${mod}+k" = "focus up";
          "${mod}+l" = "focus right";

          # Move window (shift + h/j/k/l)
          "${mod}+Shift+h" = "move left";
          "${mod}+Shift+j" = "move down";
          "${mod}+Shift+k" = "move up";
          "${mod}+Shift+l" = "move right";

          # Workspaces
          "${mod}+1" = "workspace number 1";
          "${mod}+2" = "workspace number 2";
          "${mod}+3" = "workspace number 3";
          "${mod}+4" = "workspace number 4";
          "${mod}+5" = "workspace number 5";
          "${mod}+6" = "workspace number 6";
          "${mod}+7" = "workspace number 7";
          "${mod}+8" = "workspace number 8";
          "${mod}+9" = "workspace number 9";
          "${mod}+0" = "workspace number 10";

          # Send to workspace
          "${mod}+Shift+1" = "move container to workspace number 1";
          "${mod}+Shift+2" = "move container to workspace number 2";
          "${mod}+Shift+3" = "move container to workspace number 3";
          "${mod}+Shift+4" = "move container to workspace number 4";
          "${mod}+Shift+5" = "move container to workspace number 5";
          "${mod}+Shift+6" = "move container to workspace number 6";
          "${mod}+Shift+7" = "move container to workspace number 7";
          "${mod}+Shift+8" = "move container to workspace number 8";
          "${mod}+Shift+9" = "move container to workspace number 9";
          "${mod}+Shift+0" = "move container to workspace number 10";

          # Layout
          "${mod}+b" = "split h";
          "${mod}+v" = "split v";
          "${mod}+f" = "fullscreen toggle";
          "${mod}+Shift+space" = "floating toggle";
          "${mod}+q" = "kill";
          "${mod}+Return" = "exec ghostty";
          "${mod}+d" = "exec dmenu_run";

          # Resize mode
          "${mod}+r" = "mode resize";

          # Session
          "${mod}+Shift+r" = "restart";
          "${mod}+Shift+e" = "exec i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'";
        };
      modes = {
        resize = {
          "h" = "resize shrink width 50 px";
          "j" = "resize grow height 50 px";
          "k" = "resize shrink height 50 px";
          "l" = "resize grow width 50 px";
          "Escape" = "mode default";
          "Return" = "mode default";
        };
      };
      bars = [
        {
          position = "top";
          statusCommand = "${pkgs.i3status}/bin/i3status";
        }
      ];
    };
  };
}

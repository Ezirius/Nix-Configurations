{ lib, ... }:
let
  secrets = import ../../Secrets/Maldoria/git-agecrypt.nix;
  username = "ezirius";
  homeDir = "/Users/${username}";
in
{
  home.stateVersion = "24.11";
  home.username = username;
  home.homeDirectory = lib.mkForce homeDir;
  home.sessionVariables = {
    SSH_AUTH_SOCK = "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
  };

  # SSH config
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        extraOptions = {
          IdentityAgent = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
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

  # Known hosts (declarative)
  # GitHub: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  # Nithra: from git-agecrypt secrets
  home.file.".ssh/known_hosts".text = ''
    maldoria-github-ezirius-nix-configurations ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    maldoria-github-ezirius-nix-configurations ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
    maldoria-github-ezirius-nix-configurations ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    maldoria-nithra-root-boot ${secrets.hostKeysPub.nithra_all_all_boot}
    maldoria-nithra-ezirius-login ${secrets.hostKeysPub.nithra_all_all_login}
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
      gpg.format = "ssh";
      gpg.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
      user = {
        name = "Ezirius";
        email = "66864416+ezirius@users.noreply.github.com";
      };
    };
  };
}

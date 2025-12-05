{ config, pkgs, ... }:
{
  users.users.ezirius = {
    isNormalUser = true;
    description = "Ezirius";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.eziriusPassword.path;
    # SSH keys set in Hosts/Nithra/default.nix (from git-agecrypt secrets)
  };
  programs.zsh.enable = true; # System-wide zsh for user shell
}

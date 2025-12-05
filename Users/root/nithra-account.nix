{ config, ... }:
{
  # Root user password managed by sops-nix
  users.users.root = {
    hashedPasswordFile = config.sops.secrets.rootPassword.path;
  };
}

{
  description = "Nix Infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      home-manager,
      sops-nix,
      nix-darwin,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      formatter = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        # Custom formatter wrapper to exclude Secrets/ directory
        # Secrets/*.nix files are encrypted by git-agecrypt - formatting would corrupt them
        pkgs.writeShellApplication {
          name = "nix-fmt-wrapper";
          runtimeInputs = [
            pkgs.nixfmt-rfc-style
            pkgs.git
            pkgs.findutils
          ];
          text = ''
                        set -euo pipefail
                        files=$(find . -type f -name '*.nix' ! -ipath './Secrets/*')
                        if [ -z "$files" ]; then
                          exit 0
                        fi
                        printf '%s
            ' "$files" | xargs nixfmt --
          '';
        }
      );

      nixosConfigurations.nithra = nixpkgs.lib.nixosSystem {
        modules = [
          # Set platform (modern approach, replaces system arg)
          { nixpkgs.hostPlatform = "x86_64-linux"; }

          # 1. Disko Module
          disko.nixosModules.disko

          # 2. Sops Module
          sops-nix.nixosModules.sops

          # 3. Host Config
          ./Hosts/Nithra

          # 4. Home Manager Module
          home-manager.nixosModules.home-manager

          # 5. Home Manager Settings
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.root = import ./Users/root/nithra-home.nix;
            home-manager.users.ezirius = import ./Users/ezirius/nithra-home.nix;
          }
        ];
      };

      darwinConfigurations.maldoria = nix-darwin.lib.darwinSystem {
        modules = [
          { nixpkgs.hostPlatform = "aarch64-darwin"; }

          # Sops Module
          sops-nix.darwinModules.sops

          # Host Config
          ./Hosts/Maldoria

          # Home Manager Module
          home-manager.darwinModules.home-manager

          # Home Manager Settings
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.ezirius = import ./Users/ezirius/maldoria-home.nix;
          }
        ];
      };
    };
}

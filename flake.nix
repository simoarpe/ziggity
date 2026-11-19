{
  description = "Ziggity: a fast terminal UI for git, written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # nix build / nix run / nix profile install
      packages = forAllSystems (pkgs: rec {
        ziggity = pkgs.callPackage ./nix/package.nix { };
        default = ziggity;
      });

      # For other flakes: add to nixpkgs.overlays, then use pkgs.ziggity.
      overlays.default = final: _prev: {
        ziggity = final.callPackage ./nix/package.nix { };
      };

      # nix develop: the pinned Zig toolchain, for plain `zig build`.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.zig_0_17
            pkgs.git
          ];
        };
      });

      # nix flake check
      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) ziggity;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}

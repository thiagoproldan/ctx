{
  description = "ctx -- keeps Claude Code's context small, and hands off to ekko before it grows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux only: the worker's sandbox is bubblewrap.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              # The worker is the Antigravity CLI, which nixpkgs marks unfree.
              config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "antigravity-cli";
            }
          )
        );
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.callPackage ./package.nix { };
      });

      # `nix develop -c src/test-hooks.sh` runs the suite against the working tree.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bash
            coreutils
            findutils
            gawk
            gnugrep
            gnused
            jq
            python3
            shellcheck
            shfmt
          ];
        };
      });
    };
}

{
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.solc-pkgs = {
    url = "github:hellwolf/solc.nix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils, haskellNix, solc-pkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      compiler-nix-name = "ghc984";
    in
      flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            haskellNix.overlay
            (final: prev: {
              libff = prev.libff.overrideAttrs (oldAttrs: {
                # Apply Windows compatibility patch for clock_gettime
                patches = (oldAttrs.patches or []) ++ prev.lib.optionals prev.stdenv.hostPlatform.isWindows [
                  ./nix/libff-mingw.patch
                ];
              });
            })
          ];
          # Also ensure we are using haskellNix config. Otherwise we won't be
          # selecting the correct wine version for cross compilation.
          inherit (haskellNix) config;
        };

        echidna = {
          inherit compiler-nix-name;
          src = pkgs.haskell-nix.haskellLib.cleanGit {
            name = "echidna";
            src = ./.;
          };

          modules = [{
            packages.hevm.components.library.libs = pkgs.lib.mkForce (with pkgs; [ libff secp256k1 ]);
          }];

          #crossPlatforms = p: (pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
          #  p.ucrt64
          #]) ++ (pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          #  p.aarch64-multiplatform-musl
          #  p.musl64
          #]);
        };

        hsPkgs = pkgs.haskell-nix.project echidna;
        #flake = hsPkgs.flake {};
      in
        let
          nativePackages = {
            packages.echidna = hsPkgs.echidna.components.exes.echidna;
            defaultPackage = self.packages.${system}.echidna;
          };

          linuxCrossPackages = let
            # using aarch64-multiplatform-musl here, gives us fully static binaries.
            aarch64-musl = pkgs.pkgsCross.aarch64-multiplatform-musl.haskell-nix.project echidna;
            x86_64-musl = pkgs.pkgsCross.musl64.haskell-nix.project echidna;
            x86_64-windows = pkgs.pkgsCross.ucrt64.haskell-nix.project echidna;
          in (pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            packages.echidna-aarch64-musl = aarch64-musl.echidna.components.exes.echidna;
            packages.echidna-x86_64-musl = x86_64-musl.echidna.components.exes.echidna;
            packages.echidna-x86_64-windows = x86_64-windows.echidna.components.exes.echidna;
          }) // (pkgs.lib.optionalAttrs (system == "aarch64-linux") {
            packages.echidna-aarch64-musl = aarch64-musl.echidna.components.exes.echidna;
          });
        
        in pkgs.lib.recursiveUpdate nativePackages linuxCrossPackages

      );

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    # This sets the flake to use the IOG nix cache.
    # Nix should ask for permission before using it,
    # but remove it here if you do not want it to.
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}

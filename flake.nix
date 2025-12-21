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
              ff = (prev.libff.overrideAttrs (oldAttrs: {
                # Apply Windows compatibility patch for clock_gettime
                patches = (oldAttrs.patches or []) ++ prev.lib.optionals prev.stdenv.hostPlatform.isWindows [
                  ./nix/libff-mingw.patch
                ];
              })).override { enableStatic = prev.stdenv.hostPlatform.isMusl; };
            })
          ];
          # Also ensure we are using haskellNix config. Otherwise we won't be
          # selecting the correct wine version for cross compilation.
          inherit (haskellNix) config;
        };

        dependencies-static = with pkgs; [
          (gmp.override { withStatic = true; })
          (secp256k1.overrideAttrs (attrs: {
            configureFlags = attrs.configureFlags ++ [ "--enable-static" ];
          }))
          (libff.override { enableStatic = true; })
          (ncurses.override { enableStatic = true; })
        ];

        stripDylib = drv: pkgs.runCommand "${drv.name}-strip-dylibs" {} ''
          mkdir -p $out
          mkdir -p $out/lib
          cp -r ${drv}/* $out/
          rm -rf $out/**/*.dylib
        '';

        # "static" binary for distribution
        # on macos this has everything except libcxx and libsystem
        # statically linked. we can be confident that these two will always
        # be provided in a well known location by macos itself.
        echidnaDarwinRedistributable = let
          grep = "${pkgs.gnugrep}/bin/grep";
          otool = "${pkgs.darwin.binutils.bintools}/bin/otool";
          install_name_tool = "${pkgs.darwin.binutils.bintools}/bin/install_name_tool";
          codesign_allocate = "${pkgs.darwin.binutils.bintools}/bin/codesign_allocate";
          codesign = "${pkgs.darwin.sigtool}/bin/codesign";
        in ''
          # rewrite /nix/... library paths to point to /usr/lib
          exe="$out/bin/echidna"
          chmod 777 "$exe"
          for lib in $(${otool} -L "$exe" | awk '/nix\/store/{ print $1 }'); do
            case "$lib" in
              *libc++.*.dylib)    ${install_name_tool} -change "$lib" /usr/lib/libc++.dylib     "$exe" ;;
              *libc++abi.*.dylib) ${install_name_tool} -change "$lib" /usr/lib/libc++abi.dylib  "$exe" ;;
              *libffi.*.dylib)    ${install_name_tool} -change "$lib" /usr/lib/libffi.dylib     "$exe" ;;
              *libiconv.2.dylib)  ${install_name_tool} -change "$lib" /usr/lib/libiconv.2.dylib "$exe" ;;
              *libz.dylib)        ${install_name_tool} -change "$lib" /usr/lib/libz.dylib       "$exe" ;;
            esac
          done
          # check that no nix deps remain
          nixdeps=$(${otool} -L "$exe" | tail -n +2 | { ${grep} /nix/store -c || test $? = 1; })
          if [ ! "$nixdeps" = "0" ]; then
            echo "Nix deps remain in redistributable binary!"
            #exit 255
          fi
          # re-sign binary
          CODESIGN_ALLOCATE=${codesign_allocate} ${codesign} -f -s - "$exe"
          chmod 555 "$exe"
        '';

        echidna' = { staticBuild ? false }: {
          inherit compiler-nix-name;
          src = pkgs.haskell-nix.haskellLib.cleanGit {
            name = "echidna";
            src = ./.;
          };

          modules = [
            (pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isWindows {
              configureFlags = [
                "--gcc-option=-Wno-error=int-conversion"
              ];
            })
            (pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isDarwin && staticBuild) {
              packages.echidna.components.exes.echidna =
                {
                  enableShared = false;
                  enableStatic = true;
                  configureFlags = map (drv: "--extra-lib-dirs=${stripDylib drv}/lib") dependencies-static;
                  postInstall = echidnaDarwinRedistributable;
                };
            })
            #{ packages.hevm.components.library.libs = pkgs.lib.mkForce (with pkgs.evalPackages; [ libff secp256k1 ]); }
          ];

          #crossPlatforms = p: (pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
          #  p.ucrt64
          #]) ++ (pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          #  p.aarch64-multiplatform-musl
          #  p.musl64
          #]);
        };

        echidna = echidna' {};
        echidnaStatic = echidna' { staticBuild = true; };

        hsPkgs = pkgs.haskell-nix.project echidna;
        hsStaticPkgs = pkgs.haskell-nix.project echidnaStatic;
        #flake = hsPkgs.flake {};
      in
        let
          nativePackages = {
            packages.echidna = hsPkgs.echidna.components.exes.echidna;
            packages.echidna-redistributable = hsStaticPkgs.echidna.components.exes.echidna;
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
            # alias for musl build
            packages.echidna-redistributable = x86_64-musl.echidna.components.exes.echidna;
          }) // (pkgs.lib.optionalAttrs (system == "aarch64-linux") {
            packages.echidna-aarch64-musl = aarch64-musl.echidna.components.exes.echidna;
            # alias for musl build
            packages.echidna-redistributable = aarch64-musl.echidna.components.exes.echidna;
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

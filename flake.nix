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
    in
      flake-utils.lib.eachSystem supportedSystems (system:
      let
        overlays = [ haskellNix.overlay
          (final: prev: let
            # Override libff to remove unnecessary boost dependency
            libff = prev.libff.overrideAttrs (oldAttrs: {
              # Apply Windows compatibility patch for clock_gettime
              patches = (oldAttrs.patches or []) ++ prev.lib.optionals prev.stdenv.hostPlatform.isWindows [
                ./nix/libff-mingw.patch
              ];
            });
            # if we pass a library folder to ghc via --extra-lib-dirs that contains
            # only .a files, then ghc will link that library statically instead of
            # dynamically (even if --enable-executable-static is not passed to cabal).
            # we use this trick to force static linking of some libraries on macos.
            stripDylib = drv : pkgs.runCommand "${drv.name}-strip-dylibs" {} ''
              mkdir -p $out
              mkdir -p $out/lib
              cp -r ${drv}/* $out/
              rm -rf $out/**/*.dylib
            '';

            # this is not perfect for development as it hardcodes solc to 0.5.7, test suite runs fine though
            # 0.5.7 is not available on aarch64 darwin so alternatively pick 0.8.5
            solc = solc-pkgs.mkDefault pkgs (pkgs.solc_0_5_7 or pkgs.solc_0_8_5);


            # Static fixup function that takes ncurses as parameter
            makeStaticFixup = ncurses-static: let
              grep = "${pkgs.gnugrep}/bin/grep";
              perl = "${pkgs.perl}/bin/perl";
              otool = "${pkgs.darwin.binutils.bintools}/bin/otool";
              install_name_tool = "${pkgs.darwin.binutils.bintools}/bin/install_name_tool";
              codesign_allocate = "${pkgs.darwin.binutils.bintools}/bin/codesign_allocate";
              codesign = "${pkgs.darwin.sigtool}/bin/codesign";
            in if pkgs.stdenv.isLinux
            then ''
              # fix TERMINFO path in ncurses
              ${perl} -i -pe 's#(${ncurses-static}/share/terminfo)#"/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo" . "\x0" x (length($1) - 65)#e' $out/bin/echidna
              chmod 555 $out/bin/echidna
            '' else if pkgs.stdenv.isDarwin then ''
              # get the list of dynamic libs from otool and tidy the output
              libs=$(${otool} -L $out/bin/echidna | tail -n +2 | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
              # get the path for libcxx
              cxx=$(echo "$libs" | ${grep} '^/nix/store/.*/libc++\.')
              cxxabi=$(echo "$libs" | ${grep} '^/nix/store/.*/libc++abi\.')
              iconv=$(echo "$libs" | ${grep} '^/nix/store/.*/libiconv\.')
              # rewrite /nix/... library paths to point to /usr/lib
              chmod 777 $out/bin/echidna
              ${install_name_tool} -change "$cxx" /usr/lib/libc++.1.dylib $out/bin/echidna
              ${install_name_tool} -change "$cxxabi" /usr/lib/libc++abi.dylib $out/bin/echidna
              ${install_name_tool} -change "$iconv" /usr/lib/libiconv.dylib $out/bin/echidna
              # fix TERMINFO path in ncurses
              ${perl} -i -pe 's#(${ncurses-static}/share/terminfo)#"/usr/share/terminfo" . "\x0" x (length($1) - 19)#e' $out/bin/echidna
              # check that no nix deps remain
              nixdeps=$(${otool} -L $out/bin/echidna | tail -n +2 | { ${grep} /nix/store -c || test $? = 1; })
              if [ ! "$nixdeps" = "0" ]; then
                echo "Nix deps remain in redistributable binary!"
                exit 255
              fi
              # re-sign binary
              CODESIGN_ALLOCATE=${codesign_allocate} ${codesign} -f -s - $out/bin/echidna
              chmod 555 $out/bin/echidna
            '' else null;
  
            echidnaProject = { staticBuild ? false, targetPkgs ? pkgs }:
              let
                # Use the target package set for static libraries when cross-compiling
                pkgsForStatic = targetPkgs;
                
                # Static libraries using the correct package set
                ncurses-static = pkgsForStatic.ncurses.override { enableStatic = true; };
                staticLibsForTarget = with pkgsForStatic; [
                  (gmp.override { withStatic = true; })
                  (libff.override { enableStatic = true; })
                  (libffi.overrideAttrs (_: { dontDisableStatic = true; }))
                  ncurses-static
                  (secp256k1.overrideAttrs (attrs: {
                    configureFlags = attrs.configureFlags ++ [ "--enable-static" ];
                  }))
                  (zlib.override { static = true; shared = false; })
                ];
                staticFixup = makeStaticFixup ncurses-static;
              in
              final.haskell-nix.project' {
                name = "echidna";
                src = pkgs.haskell-nix.haskellLib.cleanGit {
                  name = "echidna";
                  src = ./.;
                };
                compiler-nix-name = "ghc984"; # Version of GHC to use
                
                modules = [{
                  packages.hevm.components.library.libs = pkgs.lib.mkForce (with pkgsForStatic;
                      [ libff secp256k1 ]);
                  
                  packages.echidna.components.exes.echidna = if staticBuild then
                    {
                      enableShared = false;
                      enableStatic = true;
                      configureFlags = map (drv: "--extra-lib-dirs=${stripDylib drv}/lib") staticLibsForTarget;
                      postInstall = staticFixup;
                    } else {};
                }];

                # Tools to include in the development shell
                shell = {
                  tools = {
                    cabal = "latest";
                    hlint = "latest";
                    haskell-language-server = "latest";
                  };
                  # Non-Haskell shell tools go here
                  buildInputs = with pkgs; [
                    solc
                    slither-analyzer
                  ];
                };
              };
            in {
            echidnaProjectShared = echidnaProject { staticBuild = false; };
            echidnaProjectStatic = echidnaProject { staticBuild = true; };
            # Cross-compilation projects
            echidnaProjectCrossMingw = echidnaProject { staticBuild = true; targetPkgs = pkgs.pkgsCross.ucrt64; };
            echidnaProjectCrossMusl = echidnaProject { staticBuild = true; targetPkgs = pkgs.pkgsCross.musl64.pkgsStatic; };
          })
          solc-pkgs.overlay
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
        solc = solc-pkgs.mkDefault pkgs (pkgs.solc_0_5_7 or pkgs.solc_0_8_5);
        sharedFlake = pkgs.echidnaProjectShared.flake {
          crossPlatforms = p: pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 ([
              p.mingwW64
            ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              p.musl64
            ]);
        };
        staticFlake = pkgs.echidnaProjectStatic.flake {
          crossPlatforms = p: pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 ([
              p.mingwW64
            ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              p.musl64
            ]);
        };
        windowsFlake = pkgs.echidnaProjectCrossMingw.flake { };
        muslFlake = pkgs.echidnaProjectCrossMusl.flake { };
      in sharedFlake // {
        legacyPackages = pkgs;

        packages = sharedFlake.packages // {
          default = sharedFlake.packages."echidna:exe:echidna";
          echidna-redistributable = if pkgs.stdenv.hostPlatform.isLinux
            then muslFlake.packages."echidna:exe:echidna"
            else staticFlake.packages."echidna:exe:echidna";
          echidna-windows = windowsFlake.packages."echidna:exe:echidna";
        };
      });

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

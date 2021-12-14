let
  overlays = [(final: prev:
    # libff doesn't build on aarch64 with the default options
    # TODO: upstream this to nixpkgs and remove the overlay
    if prev.stdenv.system == "aarch64-darwin" || prev.stdenv.system == "aarch64-linux" then {
      libff = prev.libff.overrideAttrs (old: {
        cmakeFlags = old.cmakeFlags ++ ["-DCURVE=ALT_BN128" "-DUSE_ASM=OFF"];
      });
    } else {}
  )];

  pkgs = import (builtins.fetchTarball {
    name = "nixpkgs-unstable-2021-12-08";
    url = "https://github.com/nixos/nixpkgs/archive/f225322e3bea8638304adfcf415cd11de99f2208.tar.gz";
    sha256 = "sha256:1cbl7w81h2m4as15z094jkcrgg2mdi2wnkzg2dhd6080vgic11vy";
  }) { inherit overlays; };

  # this is not perfect for development as it hardcodes solc to 0.5.7, test suite runs fine though
  # would be great to integrate solc-select to be more flexible, improve this in future
  solc = pkgs.stdenv.mkDerivation {
    name = "solc";
    src = if pkgs.stdenv.isDarwin then
      pkgs.fetchurl {
        url = "https://binaries.soliditylang.org/macosx-amd64/solc-macosx-amd64-v0.5.7+commit.6da8b019";
        sha256 = "095mlw5x9lpdcdl9jzlvkvw46ag03xr4nj4vly4hgn92rgivimm7";
      }
    else
      pkgs.fetchurl {
        url = "https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.5.7+commit.6da8b019";
        sha256 = "0dsvzck5jh8rvdxs7zyn2ga9hif024msx8gr8ifgj4cmyb7m4341";
      };
    phases = ["installPhase" "patchPhase"];
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/solc
      chmod +x $out/bin/solc
    '';
  };

  slither-analyzer = pkgs.slither-analyzer.override { withSolc = false; };

  v = "1.7.3";

  f = { mkDerivation, aeson, ansi-terminal, base, base16-bytestring, binary
      , brick, bytestring, cborg, containers, data-dword, data-has, deepseq
      , directory, exceptions, filepath, hashable, hevm, hpack, lens, lens-aeson
      , megaparsec, MonadRandom, mtl, optparse-applicative, process, random
      , semver, stm, tasty, tasty-hunit, tasty-quickcheck, temporary, text
      , transformers, unix, unliftio, unliftio-core, unordered-containers, vector
      , vector-instances, vty, wl-pprint-annotated, word8, yaml, extra, ListLike
      }:
      mkDerivation rec {
        pname = "echidna";
        version = v;
        src = ./.;
        isLibrary = true;
        isExecutable = true;
        libraryHaskellDepends = [
          aeson ansi-terminal base base16-bytestring binary brick bytestring
          cborg containers data-dword data-has deepseq directory exceptions
          filepath hashable hevm lens lens-aeson ListLike megaparsec MonadRandom
          mtl optparse-applicative process random semver stm temporary text
          transformers unix unliftio unliftio-core unordered-containers vector
          vector-instances vty wl-pprint-annotated word8 yaml extra ListLike
        ] ++ (if pkgs.lib.inNixShell then testHaskellDepends else []);
        executableHaskellDepends = libraryHaskellDepends;
        testHaskellDepends = [ tasty tasty-hunit tasty-quickcheck ];
        libraryToolDepends = [ hpack slither-analyzer solc ];
        testToolDepends = [ slither-analyzer solc ];
        preConfigure = ''
          hpack
          # re-enable dynamic build for Linux
          sed -i -e 's/os(linux)/false/' echidna.cabal
        '';
        shellHook = "hpack";
        license = pkgs.lib.licenses.agpl3;
        doHaddock = false;
        doCheck = pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform && pkgs.stdenv.hostPlatform.isx86;
      };

  # some overrides required to build hevm on aarch64, this should disappear in the future
  aarch64HaskellPackages = pkgs.haskellPackages.override {
    overrides = self: super: {
      # cvc4 is broken on aarch64-darwin, looks like we don't need it though,
      # don't mark it as an explicit dependency
      # https://github.com/NixOS/nixpkgs/blob/eac53a865b53ce9e0697bc2020f9ee444eb27e7d/pkgs/development/haskell-modules/configuration-nix.nix#L496-L511
      # TODO: fix cln package, dependency of cvc4
      sbv = pkgs.haskell.lib.dontCheck (pkgs.haskell.lib.overrideCabal super.sbv (old: {
        postPatch = ''
          sed -i -e 's|"abc"|"${pkgs.abc-verifier}/bin/abc"|' Data/SBV/Provers/ABC.hs
          sed -i -e 's|"boolector"|"${pkgs.boolector}/bin/boolector"|' Data/SBV/Provers/Boolector.hs
          sed -i -e 's|"yices-smt2"|"${pkgs.yices}/bin/yices-smt2"|' Data/SBV/Provers/Yices.hs
          sed -i -e 's|"z3"|"${pkgs.z3}/bin/z3"|' Data/SBV/Provers/Z3.hs

          sed -i -e 's|\[abc, boolector, cvc4, mathSAT, yices, z3, dReal\]|[abc, boolector, cvc4, yices, z3]|' SBVTestSuite/SBVConnectionTest.hs
        '';
      }));
      # the hackage version doesn't build on aarch64-darwin, master is fixed
      # TODO: remove this after libBF is bumped to the next version
      libBF = super.libBF.overrideAttrs (old: {
        src = pkgs.fetchFromGitHub {
          owner = "GaloisInc";
          repo = "libBF-hs";
          rev = "ebc09dc6536eefd6bd72bdbe125b0ff79bb118fe";
          sha256 = "sha256-GlHU163TzuPsYzUlA129RPz8HDDlslrE7PF7ybnAPR0=";
        };
      });
    };
  };

  haskellPackages = if pkgs.stdenv.system == "aarch64-darwin" || pkgs.stdenv.system == "aarch64-linux"
    then aarch64HaskellPackages
    else pkgs.haskellPackages;

  echidna = haskellPackages.callPackage f { };
  echidnaShell = haskellPackages.shellFor {
    packages = p: [ echidna ];
    buildInputs = with haskellPackages; [
      hlint
      cabal-install
    ] ++ pkgs.lib.optional (pkgs.stdenv.system != "aarch64-darwin" && pkgs.stdenv.system != "aarch64-linux") [
      # this doesn't work due to ormolu not building
      haskell-language-server
    ];
  };
in
  if pkgs.lib.inNixShell
    then echidnaShell
    else pkgs.haskell.lib.justStaticExecutables echidna

{ tests ? false }:
let
  pkgs = import (builtins.fetchTarball {
    name = "nixpkgs-unstable-2022-05-17";
    url = "https://github.com/nixos/nixpkgs/archive/0e78d578e643f353d6db74a8514bab28099760dc.tar.gz";
    sha256 = "sha256:08xl0wcl4rn2zkdn0wfdrp0bcs5zjdbib84324cxg0vxvg114lb4";
  }) {};
  echidna = import ./. { inherit tests; };
in
  with pkgs; runCommand "echidna-${echidna.version}-bundled-dylibs" {
    buildInputs = [
      macdylibbundler
      darwin.sigtool
      darwin.cctools
      perl
    ];
  } ''
    mkdir -p $out/bin
    cp ${echidna}/bin/echidna-test $out/bin/echidna-test
    chmod 755 $out/bin/echidna-test
    dylibbundler -b \
      -x $out/bin/echidna-test \
      -d $out/bin \
      -p '@executable_path'

    # fix TERMINFO path in ncurses binary
    perl -i -pe 's#(${pkgs.ncurses}/share/terminfo)#"/usr/share/terminfo" . "\x0" x (length($1) - 19)#e' $out/bin/libncursesw.6.dylib

    # re-sign the binaries since the load paths were modified
    codesign -s - -f $out/bin/*
    tar -czvf $out/echidna-${echidna.version}-${stdenv.system}.tar.gz -C $out/bin .
  ''

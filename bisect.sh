#!/bin/bash

function finish {
  git checkout package.yaml
}
trap finish EXIT

# Fix ArchLinux build
sed -i '/- -static/d' package.yaml
sed -i '/cc-options: -static/d' package.yaml
sed -i 's/-static//' package.yaml

INCLUDE_PATH=/home/emilio/echidna/local/include/
LIBRARY_PATH=/home/emilio/echidna/local/lib
stack install --extra-include-dirs=$INCLUDE_PATH --extra-lib-dirs=$LIBRARY_PATH . || exit 125

systemd-run --user --wait -E "PATH=$PATH" -t --slice=memlimit.slice ./testleak.sh
test_code=$?

if [[ $test_code = 0 ]]; then
  exit 0
fi

exit 1

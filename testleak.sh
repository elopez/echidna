#!/bin/bash
set -x

BUILD_DIR=$(dirname "$(readlink -f "$0")")
BINARY=$HOME/.local/bin/echidna-test
TIME_SECS=600

cd $BUILD_DIR
sha1sum $BINARY
timeout $TIME_SECS $BINARY bug.sol --config config.yaml
test_code=$?

if [[ $test_code = 124 ]]; then
  # timeout = good
  exit 0
fi

exit 1

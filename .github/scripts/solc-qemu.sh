#!/bin/bash

exec qemu-x86_64 -L /usr/x86_64-linux-gnu -- "$0.amd64" "$@"

#!/bin/bash
set -e
source devkit/rootless.sh
FINALPACKAGE=1 "${MAKE:-make}" -j1 clean package

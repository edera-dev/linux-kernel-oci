#!/bin/sh
set -e

if [ -z "${TARGET_ARCH}" ]
then
  TARGET_ARCH="$(uname -m)"
fi

if [ "${TARGET_ARCH}" = "arm64" ]
then
  TARGET_ARCH="aarch64"
fi

[ "${TARGET_ARCH}" = "x86_64" ] && C_TARGET="x86_64-linux-gnu"
[ "${TARGET_ARCH}" = "aarch64" ] && C_TARGET="aarch64-linux-gnu"

if [ -z "${C_TARGET}" ]
then
  echo "ERROR: Unable to determine C_TARGET, your os or architecture may not be supported by krata." > /dev/stderr
  exit 1
fi

echo "${C_TARGET}"

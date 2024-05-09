#!/bin/sh
set -e

if [ -z "${1}" ]
then
  echo "Usage: identify-kernel-sh <file>"
  exit 1
fi

file -bL "${1}" | sed 's/.*version //;s/ .*//'

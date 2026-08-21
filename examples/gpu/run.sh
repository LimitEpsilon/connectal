#!/bin/bash
if [ "$#" -ne 2 ] || ! [ -f "kernels/$2.elf" ]; then
  echo "Usage: $0 <benchmark-name>" >&2
  exit 1
fi
./$1/bin/ubuntu.exe benchmarks/$2 kernels/$2.elf

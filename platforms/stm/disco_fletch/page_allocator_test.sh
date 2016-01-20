#!/bin/sh
# Copyright (c) 2016, the Fletch project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE.md file.

# Temporary script for testing the page allocator.
rm a.out

set -e

g++ \
  -g \
  -Og \
  -I. \
  -DFLETCH_TARGET_OS_POSIX \
  --std=gnu++11 \
  platforms/stm/disco_fletch/src/page_allocator_test.cc \
  platforms/stm/disco_fletch/src/page_allocator.cc \
  src/shared/assert.cc \
  src/shared/platform_posix.cc src/shared/platform_linux.cc \
  src/shared/utils.cc

./a.out

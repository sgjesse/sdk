#!/usr/bin/python

# Copyright (c) 2015, the Dartino project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import os
import sys
import utils

def invoke_embedded_ar(args):
  library_name = args[len(args) - 1]
  libraries = args[:-1]
  script = 'CREATE %s\n' % library_name
  for lib in libraries:
    script += 'ADDLIB %s\n' % lib
  script += 'SAVE\n'
  script += 'END\n'
  os.system('env echo "%s" | /Users/sgjesse/prj/dart/github/dartino/sdk/third_party/gcc-arm-embedded/mac/gcc-arm-embedded/bin/arm-none-eabi-ar -M' % script)

def invoke_ar(args):
  library_name = args[len(args) - 1]
  libraries = args[:-1]
  script = 'create %s\\n' % library_name
  for lib in libraries:
    script += 'addlib %s\\n' % lib
  script += 'save\\n'
  script += 'end\\n'
  os.system('env echo -e "%s" | ar -M' % script)

def invoke_libtool(args):
  library_name = args[len(args) - 1]
  libraries = args[:-1]
  command = 'libtool -static -o %s' % library_name
  for lib in libraries:
    command += ' %s' % lib
  os.system(command)

def invoke_lib_exe(args):
  library_name = args[len(args) - 1]
  libraries = args[:-1]
  command = 'lib.exe /out:%s' % library_name
  for lib in libraries:
    command += ' %s' % lib
  os.system(command)

def main():
  args = sys.argv[1:]
  os_name = utils.GuessOS()
  if os.getenv('CONFIGURATION').endswith('STM') or os.getenv('CONFIGURATION').endswith('CM4') or os.getenv('CONFIGURATION').endswith('CM4SF'):
    invoke_embedded_ar(args)
  elif os_name == 'linux':
    invoke_ar(args)
  elif os_name == 'macos':
    invoke_libtool(args)
  elif os_name == 'windows':
    invoke_lib_exe(args)

if __name__ == '__main__':
  main()

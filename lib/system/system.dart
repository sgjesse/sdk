// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dart.dartino._system;

import 'dart:_internal' hide Symbol;
import 'dart:collection';
import 'dart:dartino';
import 'dart:math';

part 'list.dart';
part 'map.dart';
part 'nsm.dart';

const native = "native";

class _Patch {
  const _Patch();
}

const patch = const _Patch();

const bool enableBigint =
    const bool.fromEnvironment('dartino.enable-bigint', defaultValue: true);

// These strings need to be kept in sync with the strings allocated
// for the raw failure objects in src/vm/program.cc.
const wrongArgumentType = "Wrong argument type.";
const indexOutOfBounds = "Index out of bounds.";
const illegalState = "Illegal state.";

// This enum must be kept in sync with the Interpreter::InterruptKind
// enum in src/vm/interpreter.h.
enum InterruptKind {
  ready,
  terminate,
  interrupt,
  yield,
  targetYield,
  uncaughtException,
  compileTimeError,
  breakPoint
}

class _Arguments
    extends Object with UnmodifiableListMixin<String>, ListMixin<String>
    implements List<String> {

  _Arguments();

  @native external int get length;

  String operator[](int index) {
    return _toString(index);
  }

  @native external static String _toString(int index);
}

/// This is a magic method recognized by the compiler, and references to it
/// will be substituted for the actual main method.
/// [arguments] is supposed to be a List<String> with command line arguments.
/// [isolateArgument] is an extra argument that can be passed via
/// [Isolate.spawnUri].
external invokeMain([arguments, isolateArgument]);

// Trivial wrapper around invokeMain to have a frame to restart from
// if we want to restart main.
// TODO(ager): Get rid of this wrapper.
callMain(arguments) => invokeMain(arguments);

/// This is the main entry point for a Dartino program, and it takes care of
/// calling "main" and exiting the VM when "main" is done.
void entry() {
  Fiber.exit(callMain(new _Arguments()));
}

runToEnd(entry) {
  Fiber.exit(entry());
}

unresolved(name) {
  throw new NoSuchMethodError(
      null,
      name,
      null,
      null);
}

compileError(String message) {
  print("Compile error: $message");
  yield(InterruptKind.compileTimeError.index);
}

halt() {
  yield(InterruptKind.terminate.index);
}

/// Make the current process yield. Either to allow other fibers to
/// make progress or to terminate execution.
external yield(int reason);

external get nativeError;

// Change execution to [coroutine], passing along [argument].
external coroutineChange(coroutine, argument);

// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'dart:dartino.ffi';
import 'package:ffi/ffi.dart';
import 'package:expect/expect.dart';

import 'package:mbedtls/mbedtls.dart';
import 'dart:math';

const String serverPort = const String.fromEnvironment('SERVER_PORT');

void main() {
  var port = int.parse(serverPort);
  var socket = new TLSSocket.connect('localhost', port);
  const String data = "GET THE FOOBAR";
  for (int i = 0; i < 10; i++) {
    socket.writeString(data);
    int length = data.length;
    var back = socket.read(length);
    Expect.equals(data, bufferToString(back.getForeign()));
  }
  // Write a lot to socket, make sure we go over our own 1024 circular buffer.
  // (data should stay in the underlying buffers).
  for (int i = 0; i < 200; i++) {
    socket.writeString(data);
  }
  // Partial read
  var back = socket.read(data.length * 3);
  var string = bufferToString(back.getForeign());
  Expect.equals(bufferToString(back.getForeign()), '$data$data$data');
  var combined  = "";
  while (combined.length < data.length * 197) {
    var chunk = bufferToString(socket.readNext().getForeign());
    combined = "$combined$chunk";
  }
  var longData = "";
  for (int i = 0; i < 197; i++) longData = "$longData$data";
  Expect.equals(combined, longData);
  socket.close();
}

String bufferToString(ForeignMemory buffer) {
  return memoryToString(new ForeignPointer(buffer.address), buffer.length);
}


// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'dart:fletch.ffi';
import 'dart:typed_data';
import 'dart:fletch.os';
import 'dart:fletch' hide sleep;

final _uartOpen = ForeignLibrary.main.lookup('uart_open');
final _uartRead = ForeignLibrary.main.lookup('uart_read');
final _uartWrite = ForeignLibrary.main.lookup('uart_write');
final _uart_getError = ForeignLibrary.main.lookup('uart_get_error');

class Uart {
  int handle;
  Port port;
  Channel channel;

  Uart() {
    handle = _uartOpen.icall$0();
    channel = new Channel();
    port = new Port(channel);
  }

  ForeignMemory _getForeign(ByteBuffer buffer) {
    var b = buffer;
    return b.getForeign();
  }

  ByteBuffer readNext() {
    int event = 0;
    while (event & READ_EVENT == 0) {
      eventHandler.registerPortForNextEvent(
          handle, port, READ_EVENT | ERROR_EVENT);
      event = channel.receive();
      if (event & ERROR_EVENT != 0) {
        // TODO(sigurdm): Find the right way of handling errors.
        print("Error ${_uart_getError.icall$1(handle)}.");
      }
    }

    var mem = new ForeignMemory.allocated(10);
    try {
      var read = _uartRead.icall$3(handle, mem, 10);
      assert(read > 0);
      var result = new Uint8List(read);
      mem.copyBytesToList(result, 0, read, 0);
      return result.buffer;
    } finally {
      mem.free();
    }
  }

  void write(ByteBuffer data) {
    _write(_getForeign(data), data.lengthInBytes);
  }

  int writeString(String message) {
    var mem = new ForeignMemory.fromStringAsUTF8(message);
    try {
      // Don't write the terminating \0.
      _write(mem, mem.length - 1);
    } finally {
      mem.free();
    }
  }

  void _write(ForeignMemory mem, int size) {
    int written = 0;
    while (written < size) {
      written += _uartWrite.icall$3(handle, mem, size);
      if (written == size) break;
      // We do not listen for errors here, because writing cannot fail.
      eventHandler.registerPortForNextEvent(handle, port, WRITE_EVENT);
      channel.receive();
    }
  }
}

main() {
  var uart = new Uart();

  uart.writeString("\rWelcome to Dart UART echo!\r\n");
  uart.writeString("--------------------------\r\n");
  while (true) {
    uart.write(uart.readNext());
  }
}

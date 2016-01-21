// Copyright (c) 2016, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

/// Simple test that timers and event-handlers work.
///
/// For now we have to run this manually.

import "dart:fletch";
import "dart:fletch.ffi";
import "dart:fletch.os" hide sleep;

ForeignFunction ledOn = ForeignLibrary.main.lookup('BSP_LED_On');
ForeignFunction ledOff = ForeignLibrary.main.lookup('BSP_LED_Off');
ForeignFunction initializeProducer =
    ForeignLibrary.main.lookup('initialize_producer');
ForeignFunction notifyRead = ForeignLibrary.main.lookup('notify_read');

// How many timers to schedule.
const int count = 3;

int nextExpectedTimer = count - 1;

// Listens continuously for messages on port 1.
//
// When a message is received, turns on the LED, and starts a timer to turn it
// off again.
listenProducer() {
  int deviceId = initializeProducer.icall$0();
  Channel channel = new Channel();
  Port port = new Port(channel);
  for (int i = 0; i < 50; i++) {
    eventHandler.registerPortForNextEvent(deviceId, port, 1);
    int msg = channel.receive();
    ledOn.vcall$1(0);
    notifyRead.vcall$1(deviceId);
    Fiber.fork(() {
      Channel offChannel = sleep(100);
      offChannel.receive();
      ledOff.vcall$1(0);
    });
  }
}

main() {
  print("");
  List<Fiber> fibers = new List<Fiber>();
  // Start the delays with the longest first to test that they are triggered
  // in opposite order.
  for (int i = 0; i < count; i++) {
    Channel channel = sleep((count - i) * 500);
    var localI = i;
    Fiber fiber = Fiber.fork(() {
      print("Timer $localI waiting");
      var _ = channel.receive();
      if (nextExpectedTimer != localI) {
        print("Failure: Wrong order of timeouts, "
            "expected $nextExpectedTimer got $localI");
      } else {
        print("Timer $localI triggered");
      }
      nextExpectedTimer--;
    });
    // Yield to let the newly created fiber start listening.
    Fiber.yield();
    fibers.add(fiber);
  }
  Fiber.yield();
  fibers.add(Fiber.fork(listenProducer));

  fibers.forEach((Fiber fiber) => fiber.join);
}
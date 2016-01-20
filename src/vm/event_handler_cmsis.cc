// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if defined(FLETCH_TARGET_OS_CMSIS)

#include <cmsis_os.h>

#include "src/vm/event_handler.h"
#include "src/vm/object.h"
#include "src/vm/port.h"
#include "src/vm/process.h"
#include "src/shared/platform.h"

namespace fletch {

// Pseudo device-id indicating a interrupt.
const int kInterruptDeviceId = -1;

class Data {};

void EventHandler::Create() {
  data_ = reinterpret_cast<void*>(new Data());
}

void EventHandler::Interrupt() {
  SendMessageCmsis(kInterruptDeviceId);
}

Object* EventHandler::Add(Process* process, Object* id, Port* port,
                          int flags) {
  if (!id->IsSmi()) return Failure::wrong_argument_type();

  EnsureInitialized();

  int device_id = Smi::cast(id)->value();

  ScopedMonitorLock locker(monitor_);

  Device *device = GetDevice(device_id);
  Port *existing = device->port;
  if (existing != NULL) FATAL("Already listening to device");
  int device_flags = device->flags;
  if ((flags & device_flags) != 0) {
    // There is already an event waiting. Send a message immediately.
    Send(port, device_flags, false);
  } else {
    device->port = port;
    device->mask = flags;
    port->IncrementRef();
  }

  return process->program()->null_object();
}

void EventHandler::Run() {
  osMailQId queue = GetFletchMailQ();
  while (true) {
    int64 next_timeout;
    {
      ScopedMonitorLock locker(monitor_);
      next_timeout = next_timeout_;
    }

    if (next_timeout == INT64_MAX) {
      next_timeout = -1;
    } else {
      next_timeout -= Platform::GetMicroseconds() / 1000;
      if (next_timeout < 0) next_timeout = 0;
    }

    osEvent event = osMailGet(queue, next_timeout);
    HandleTimeouts();

    {
      ScopedMonitorLock scoped_lock(monitor_);

      if (!running_) {
        data_ = NULL;
        monitor_->Notify();
        return;
      }
    }

    if (event.status == osEventMail) {
      CmsisMessage *message = reinterpret_cast<CmsisMessage*>(event.value.p);

      int device_id = message->device_id;
      if (device_id != kInterruptDeviceId) {
        Device *device = GetDevice(device_id);
        Port *port = device->port;
        int device_flags = device->flags;
        if (port == NULL || ((device->mask & device_flags) == 0)) {
          // No relevant listener - drop the event.
        } else {
          device->port = NULL;
          Send(port, device_flags, true);
        }
      }
      osMailFree(queue, reinterpret_cast<void*>(message));
    }
  }
}

}  // namespace fletch

#endif  // defined(FLETCH_TARGET_OS_CMSIS)

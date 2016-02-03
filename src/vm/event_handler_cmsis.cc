// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if defined(FLETCH_TARGET_OS_CMSIS)

#include <cmsis_os.h>

// TODO(sigurdm): The cmsis event-handler should not know about the
// disco-platform
#include "platforms/stm/disco_fletch/src/device_manager.h"

#include "src/vm/event_handler.h"
#include "src/vm/object.h"
#include "src/vm/port.h"
#include "src/vm/process.h"

namespace fletch {

// Pseudo device-id.
// Sending a message with this device-id signals an interruption of the
// event-handler.
const int kInterruptHandle = -1;

// Dummy-class. Currently we don't store anything in EventHandler::data_. But
// if we set it to NULL, EventHandler::EnsureInitialized will not realize it is
// initialized.
class Data {};

DeviceManager *DeviceManager::instance_;

void EventHandler::Create() {
  data_ = reinterpret_cast<void*>(new Data());
}

int interrupt_count = 0;

void EventHandler::Interrupt() {
// if (
 DeviceManager::GetDeviceManager()->SendMessage(kInterruptHandle);
  // != osOK) FATAL("Did not send");
 // interrupt_count++;
}

Object* EventHandler::Add(Process* process, Object* id, Port* port, int flags) {
  if (!id->IsSmi()) return Failure::wrong_argument_type();

  EnsureInitialized();

  int handle = Smi::cast(id)->value();

  ScopedMonitorLock locker(monitor_);

  Device *device = DeviceManager::GetDeviceManager()->GetDevice(handle);
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

int64 next_timeout;

int ll = 0;
int64 next_timeouts[40] = {};

void EventHandler::Run() {
  osMessageQId queue = DeviceManager::GetDeviceManager()->GetMailQueue();

  while (true) {
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

    next_timeouts[ll++] = next_timeout;

    osEvent event = osMessageGet(queue, (int)next_timeout);
    HandleTimeouts();

    {
      ScopedMonitorLock scoped_lock(monitor_);

      if (!running_) {
        data_ = NULL;
        monitor_->Notify();
        return;
      }
    }

    if (event.status == osEventMessage ) {
      int handle = static_cast<int>(event.value.v);
      if (handle != kInterruptHandle) {
        Device *device = DeviceManager::GetDeviceManager()->GetDevice(handle);
        Port *port = device->port;
        int device_flags = device->flags;
        if (port == NULL || ((device->mask & device_flags) == 0)) {
          // No relevant listener - drop the event.
        } else {
          device->port = NULL;
          Send(port, device_flags, true);
        }
      }
    }
  }
}

}  // namespace fletch

#endif  // defined(FLETCH_TARGET_OS_CMSIS)

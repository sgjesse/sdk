// Copyright (c) 2016, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef PLATFORMS_STM_DISCO_FLETCH_SRC_DEVICE_MANAGER_H_
#define PLATFORMS_STM_DISCO_FLETCH_SRC_DEVICE_MANAGER_H_

#include "src/shared/platform.h"
#include "src/vm/port.h"

namespace fletch {

// Represents an instance of a open device that can be listened to.
struct Device {
 public:
  Device(Port *port, uint32_t flags, uint32_t mask, void* data)
    : port(port), mask(mask), data(data) {
    this->flags.store(flags);
  }

  // The port waiting for messages on this device
  Port *port;

  // The current flags for this device.
  fletch::Atomic<uint32_t> flags;

  // The mask for messages on this device.
  uint32_t mask;

  // Data associated with the device.
  void *data;

  // Sets the [flag] in [flags]. Returns true if anything changed.
  bool AddFlag(uint32_t flag) {
    uint32_t flags = this->flags;
    if ((flags & flag) != 0) return false;
    bool success = false;
    while (!success) {
      uint32_t new_flags = flags | flag;
      success = this->flags.compare_exchange_weak(flags, new_flags);
    }
    return true;
  }

  // Disables the [flag]  in [flags]. Returns true if anything changed.
  bool RemoveFlag(uint32_t flag) {
    uint32_t flags = this->flags;
    if ((flags & flag) == 0) return false;
    bool success = false;
    while (!success) {
      uint32_t new_flags = flags & ~flag;
      success = this->flags.compare_exchange_weak(flags, new_flags);
    }
    return true;
  }

};

class DeviceManager {
 public:
  static DeviceManager *GetDeviceManager();

  // Installs [device] so it can be listened to by the event handler.
  int InstallDevice(Device *device);

  Device *GetDevice(int handle);

  osMessageQId GetMailQueue() {
    return mail_queue_;
  }

  // Send a message on the mail-queue, notifying that an event has happened on
  // [handle].
  int SendMessage(int handle);

 private:
  DeviceManager();

  // All open devices are stored here.
  Vector<Device*> devices_ = Vector<Device*>();

  osMessageQId mail_queue_;

  static DeviceManager *instance_;
};


}  // namespace fletch

#endif  // PLATFORMS_STM_DISCO_FLETCH_SRC_DEVICE_MANAGER_H_

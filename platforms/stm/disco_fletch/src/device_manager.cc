// Copyright (c) 2016, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "device_manager.h"

namespace fletch {

int DeviceManager::SendMessage(int handle) {
  return osMessagePut(mail_queue_, static_cast<uint32_t>(handle), 0);
}

// The size of the queue used by the event handler.
const uint32_t kMailQSize = 50;

DeviceManager::DeviceManager() {
  osMessageQDef(device_event_queue, kMailQSize, int);
  mail_queue_ = osMessageCreate(osMessageQ(device_event_queue), NULL);
}

DeviceManager *DeviceManager::GetDeviceManager() {
  if (instance_ == NULL) {
    instance_ = new DeviceManager();
  }
  return instance_;
}

int DeviceManager::InstallDevice(Device *device) {
  devices_.PushBack(device);
  return devices_.size() - 1;
}

Device *DeviceManager::GetDevice(int handle) {
  return devices_[handle];
}

} // namespace fletch

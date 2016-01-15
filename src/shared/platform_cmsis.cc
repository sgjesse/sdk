// Copyright (c) 2014, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if defined(FLETCH_TARGET_OS_CMSIS)

// We do not include platform_posix.h on purpose. That file
// should never be directly inported. platform.h is always
// the platform header to include.
#include "src/shared/platform.h"  // NOLINT

#include <sys/time.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

#include "src/shared/utils.h"

namespace fletch {

osMailQId fletchMailQ;

osMailQId GetFletchMailQ() {
  return fletchMailQ;
}

Vector<Device*> devices;

int InstallDevice(Device *device) {
  devices.PushBack(device);
  return devices.size() - 1;
}

// Sends a message on the fletch osMailQ used by the event handler.
int SendMessageCmsis(uint32_t port_id, int64_t message, uint32_t mask) {
  CmsisMessage *cmsisMessage =
      reinterpret_cast<CmsisMessage*>(osMailAlloc(fletchMailQ, 0));
  cmsisMessage->port_id = port_id;
  cmsisMessage->message = message;
  cmsisMessage->mask = mask;
  return osMailPut(GetFletchMailQ(), reinterpret_cast<void*>(cmsisMessage));
}

static uint64 time_launch;

// The size of the queue used by the event handler.
const uint32_t kMailQSize = 50;

void Platform::Setup() {
  time_launch = GetMicroseconds();
  osMailQDef(fletch_queue, kMailQSize, CmsisMessage);
  fletchMailQ = osMailCreate(osMailQ(fletch_queue), NULL);
  devices = Vector<Device*>();
}

void Platform::TearDown() { }

void GetPathOfExecutable(char* path, size_t path_length) { path[0] = '\0'; }

int Platform::GetLocalTimeZoneOffset() { return 0; }

uint64 Platform::GetMicroseconds() {
  struct timeval tv;
  if (gettimeofday(&tv, NULL) < 0) return -1;
  uint64 result = tv.tv_sec * 1000000LL;
  result += tv.tv_usec;
  return result;
}

uint64 Platform::GetProcessMicroseconds() {
  // Assume now is past time_launch.
  return GetMicroseconds() - time_launch;
}

int Platform::GetNumberOfHardwareThreads() { return 1; }

// Load file at 'uri'.
List<uint8> Platform::LoadFile(const char* name) {
  // Open the file.
  FILE* file = fopen(name, "rb");
  if (file == NULL) {
    Print::Error("ERROR: Cannot open %s\n", name);
    return List<uint8>();
  }

  // Determine the size of the file.
  if (fseek(file, 0, SEEK_END) != 0) {
    Print::Error("ERROR: Cannot seek in file %s\n", name);
    fclose(file);
    return List<uint8>();
  }
  int size = ftell(file);
  rewind(file);

  // Read in the entire file.
  uint8* buffer = static_cast<uint8*>(malloc(size));
  int result = fread(buffer, 1, size, file);
  fclose(file);
  if (result != size) {
    Print::Error("ERROR: Unable to read entire file %s\n", name);
    return List<uint8>();
  }
  return List<uint8>(buffer, size);
}

bool Platform::StoreFile(const char* uri, List<uint8> bytes) {
  // Open the file.
  FILE* file = fopen(uri, "wb");
  if (file == NULL) {
    Print::Error("ERROR: Cannot open %s\n", uri);
    return false;
  }

  int result = fwrite(bytes.data(), 1, bytes.length(), file);
  fclose(file);
  if (result != bytes.length()) {
    Print::Error("ERROR: Unable to write entire file %s\n", uri);
    return false;
  }

  return true;
}

bool Platform::WriteText(const char* uri, const char* text, bool append) {
  // Open the file.
  FILE* file = fopen(uri, append ? "a" : "w");
  if (file == NULL) {
    // TODO(wibling): Does it make sense to write an error here? It seems it
    // could go into a loop if it fails to open the log file and we then write
    // again.
    return false;
  }
  int len = strlen(text);
  int result = fwrite(text, 1, len, file);
  fclose(file);
  if (result != len) {
    // TODO(wibling): Same as above.
    return false;
  }

  return true;
}

const char* Platform::GetTimeZoneName(int64_t seconds_since_epoch) {
  // We don't know, so return an empty string like V8 does.
  return "";
}

int Platform::GetTimeZoneOffset(int64_t seconds_since_epoch) {
  // We don't know, so return zero like V8 does.
  return 0;
}

void Platform::Exit(int exit_code) { exit(exit_code); }

void Platform::ScheduleAbort() {
  static bool failed = false;
  if (!failed) atexit(abort);
  failed = true;
}

void Platform::ImmediateAbort() { abort(); }

int Platform::GetPid() {
  // For now just returning 0 here.
  return 0;
}

// Do nothing for errno handling for now.
int Platform::GetLastError() { return 0; }
void Platform::SetLastError(int value) { }

int Platform::MaxStackSizeInWords() { return 16 * KB; }

VirtualMemory::VirtualMemory(int size) : size_(size) { UNIMPLEMENTED(); }

VirtualMemory::~VirtualMemory() { UNIMPLEMENTED(); }

bool VirtualMemory::IsReserved() const {
  UNIMPLEMENTED();
  return false;
}

bool VirtualMemory::Commit(uword address, int size, bool executable) {
  UNIMPLEMENTED();
  return false;
}

bool VirtualMemory::Uncommit(uword address, int size) {
  UNIMPLEMENTED();
  return false;
}

}  // namespace fletch

#endif  // defined(FLETCH_TARGET_OS_CMSIS)

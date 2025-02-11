// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_PORT_H_
#define SRC_VM_PORT_H_

#include "src/shared/globals.h"
#include "src/shared/platform.h"

#include "src/vm/object_memory.h"
#include "src/vm/spinlock.h"

namespace dartino {

class HeapObject;
class Instance;
class Object;
class PointerVisitor;
class Process;

class Port {
 public:
  Port(Process* process, Instance* channel);

  static Port* FromDartObject(Object* dart_port);

  Process* process() { return process_; }
  void set_process(Process* process) { process_ = process; }

  Port* next() const { return next_; }

  Instance* channel() const { return channel_; }

  bool IsLocked() const { return spinlock_.IsLocked(); }
  void Lock() { spinlock_.Lock(); }
  void Unlock() { spinlock_.Unlock(); }

  Spinlock* spinlock() { return &spinlock_; }

  // Increment the ref count. This function is thread safe.
  void IncrementRef();

  // Decrement the ref count. When the ref reaches zero, the port is delete.
  // This function is thread safe.
  void DecrementRef();

  // Cleanup ports. Delete ports with zero ref count and update the channel
  // pointer. The channel pointer is weak and is set to NULL if the channel
  // is not referenced from anywhere else.
  static Port* CleanupPorts(Space* space, Port* head);

  static void WeakCallback(HeapObject* port, Heap* heap);

 private:
  friend class Process;

  void OwnerProcessTerminating();

  void set_next(Port* next) { next_ = next; }

  virtual ~Port();

  Process* process_;
  Instance* channel_;
  Atomic<int> ref_count_;
  Spinlock spinlock_;
  // The ports are in a list in the process so that we can GC the channel
  // pointer.
  Port* next_;
};

}  // namespace dartino

#endif  // SRC_VM_PORT_H_

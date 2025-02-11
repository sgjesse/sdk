// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/weak_pointer.h"

#include <stdlib.h>

#include "src/vm/object.h"
#include "src/vm/object_memory.h"

namespace dartino {

WeakPointer::WeakPointer(HeapObject* object, WeakPointerCallback callback,
                         WeakPointer* next)
    : object_(object), callback_(callback), prev_(NULL), next_(next) {}

void WeakPointer::Process(Space* space, WeakPointer** pointers, Heap* heap) {
  WeakPointer* new_list = NULL;
  WeakPointer* previous = NULL;
  WeakPointer* current = *pointers;
  while (current != NULL) {
    WeakPointer* next = current->next_;
    HeapObject* current_object = current->object_;
    if (space->Includes(current_object->address())) {
      if (space->IsAlive(current_object)) {
        current->object_ = space->NewLocation(current_object);
        if (new_list == NULL) new_list = current;
        previous = current;
      } else {
        if (current->next_ != NULL) current->next_->prev_ = previous;
        if (previous != NULL) previous->next_ = current->next_;
        current->callback_(current_object, heap);
        delete current;
      }
    } else {
      if (new_list == NULL) new_list = current;
      previous = current;
    }
    current = next;
  }
  *pointers = new_list;
}

void WeakPointer::ForceCallbacks(WeakPointer** pointers, Heap* heap) {
  WeakPointer* current = *pointers;
  while (current != NULL) {
    WeakPointer* temp = current->next_;
    current->callback_(current->object_, heap);
    delete current;
    current = temp;
  }
  *pointers = NULL;
}

void WeakPointer::Remove(WeakPointer** pointers, HeapObject* object) {
  WeakPointer* current = *pointers;
  WeakPointer* previous = NULL;
  while (current != NULL) {
    if (current->object_ == object) {
      if (previous == NULL) {
        *pointers = current->next_;
      } else {
        previous->next_ = current->next_;
      }
      if (current->next_ != NULL) current->next_->prev_ = previous;
      delete current;
      return;
    } else {
      previous = current;
      current = current->next_;
    }
  }
}

void WeakPointer::PrependWeakPointers(WeakPointer** pointers,
                                      WeakPointer* to_be_prepended) {
  if (to_be_prepended != NULL) {
    WeakPointer* head = *pointers;

    ASSERT(head == NULL || head->prev_ == NULL);
    ASSERT(to_be_prepended->prev_ == NULL);

    WeakPointer* last = to_be_prepended;
    while (last->next_ != NULL) {
      last = last->next_;
    }
    last->next_ = head;
    if (head != NULL) {
      head->prev_ = last;
    }
    *pointers = to_be_prepended;
  }
}

void WeakPointer::Visit(WeakPointer* pointers, PointerVisitor* visitor) {
  while (pointers != NULL) {
    visitor->Visit(reinterpret_cast<Object**>(&pointers->object_));
    pointers = pointers->next_;
  }
}

}  // namespace dartino

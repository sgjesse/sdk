// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_MARK_SWEEP_H_
#define SRC_VM_MARK_SWEEP_H_

#include "src/vm/object.h"
#include "src/vm/program.h"
#include "src/vm/process.h"

namespace fletch {

class MarkingStackChunk {
 public:
  MarkingStackChunk()
      : next_chunk_(NULL), next_(&backing_[0]), limit_(next_ + kChunkSize) {}

  ~MarkingStackChunk() { ASSERT(next_chunk_ == NULL); }

  bool IsEmpty() { return next_ == &backing_[0]; }

  void Push(HeapObject* object, MarkingStackChunk** chunk_list) {
    ASSERT(object->IsMarked());
    if (next_ < limit_) {
      *(next_++) = object;
    } else {
      PushInNewChunk(object, chunk_list);
    }
  }

  HeapObject* Pop() {
    ASSERT(!IsEmpty());
    return *(--next_);
  }

  // Takes the chunk after the current one out of the chain, and
  // returns it.  If there is no such chunk, puts a new empty chunk in
  // the chain and returns this.
  MarkingStackChunk* TakeChunk(MarkingStackChunk** chunk_list) {
    if (next_chunk_ != NULL) {
      MarkingStackChunk* result = next_chunk_;
      next_chunk_ = result->next_chunk_;
      result->next_chunk_ = NULL;
      return result;
    }
    if (IsEmpty()) return NULL;
    *chunk_list = new MarkingStackChunk();
    return this;
  }

 private:
  static const int kChunkSize = 128;

  void PushInNewChunk(HeapObject* object, MarkingStackChunk** chunk_list) {
    MarkingStackChunk* new_chunk = new MarkingStackChunk();
    new_chunk->next_chunk_ = this;
    *chunk_list = new_chunk;
    new_chunk->Push(object, chunk_list);
  }

  MarkingStackChunk* next_chunk_;
  HeapObject** next_;
  HeapObject** limit_;
  HeapObject* backing_[kChunkSize];
};

class MarkingStack {
 public:
  MarkingStack() : current_chunk_(new MarkingStackChunk()) {}

  ~MarkingStack() { delete current_chunk_; }

  void Push(HeapObject* object) {
    current_chunk_->Push(object, &current_chunk_);
  }

  void Process(PointerVisitor* visitor) {
    for (MarkingStackChunk* chunk = current_chunk_->TakeChunk(&current_chunk_);
         chunk != NULL; chunk = current_chunk_->TakeChunk(&current_chunk_)) {
      while (!chunk->IsEmpty()) {
        HeapObject* object = chunk->Pop();
        object->IteratePointers(visitor);
      }
      delete chunk;
    }
  }

 private:
  MarkingStackChunk* current_chunk_;
};

class MarkingVisitor : public PointerVisitor {
 public:
  MarkingVisitor(SemiSpace* new_space, OldSpace* old_space,
                 MarkingStack* marking_stack, Stack** stack_chain = NULL)
      : stack_chain_(stack_chain),
        new_space_(new_space),
        old_space_(old_space),
        marking_stack_(marking_stack),
        number_of_stacks_(0) {}

  virtual void Visit(Object** p) { MarkPointer(*p); }

  virtual void VisitClass(Object** p) {
    // The class pointer is used for the mark bit. Therefore,
    // the actual class pointer is obtained by clearing the
    // mark bit.
    uword klass = reinterpret_cast<uword>(*p);
    MarkPointer(reinterpret_cast<Object*>(klass & ~HeapObject::kMarkBit));
  }

  virtual void VisitBlock(Object** start, Object** end) {
    // Mark live all HeapObjects pointed to by pointers in [start, end)
    for (Object** p = start; p < end; p++) MarkPointer(*p);
  }

  int number_of_stacks() const { return number_of_stacks_; }

 private:
  void ChainStack(Stack* stack) {
    number_of_stacks_++;
    stack->set_next(*stack_chain_);
    *stack_chain_ = stack;
  }

  void MarkPointer(Object* object) {
    if (!object->IsHeapObject()) return;
    uword address = reinterpret_cast<uword>(object);
    if (!new_space_->Includes(address) &&
        (old_space_ == NULL || !old_space_->Includes(address))) {
      return;
    }
    HeapObject* heap_object = HeapObject::cast(object);
    if (!heap_object->IsMarked()) {
      if (stack_chain_ != NULL && heap_object->IsStack()) {
        ChainStack(Stack::cast(heap_object));
      }
      heap_object->SetMark();
      marking_stack_->Push(heap_object);
    }
  }

  Stack** stack_chain_;
  SemiSpace* new_space_;
  OldSpace* old_space_;
  MarkingStack* marking_stack_;
  int number_of_stacks_;
};

class FreeList {
 public:
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeList(void) {
    memset(buckets_, 0, kNumberOfBuckets * sizeof(FreeListChunk*));
  }
#endif

  void AddChunk(uword free_start, uword free_size) {
    // If the chunk is too small to be turned into an actual
    // free list chunk we turn it into fillers to be coalesced
    // with other free chunks later.
    if (free_size < FreeListChunk::kSize) {
      ASSERT(free_size <= 2 * kPointerSize);
      Object** free_address = reinterpret_cast<Object**>(free_start);
      for (uword i = 0; i * kPointerSize < free_size; i++) {
        free_address[i] = StaticClassStructures::one_word_filler_class();
      }
      return;
    }
    // Large enough to add a free list chunk.
    FreeListChunk* result =
        reinterpret_cast<FreeListChunk*>(HeapObject::FromAddress(free_start));
    result->set_class(StaticClassStructures::free_list_chunk_class());
    result->set_size(free_size);
    int bucket = Utils::HighestBit(free_size) - 1;
    if (bucket >= kNumberOfBuckets) bucket = kNumberOfBuckets - 1;
    result->set_next_chunk(buckets_[bucket]);
    buckets_[bucket] = result;
  }

  FreeListChunk* GetChunk(uword min_size) {
    int smallest_bucket = Utils::HighestBit(min_size);
    ASSERT(smallest_bucket > 0);

    // Locate largest chunk in free list guaranteed to satisfy the
    // allocation.
    for (int i = kNumberOfBuckets - 1; i >= smallest_bucket; i--) {
      FreeListChunk* result = buckets_[i];
      if (result != NULL) {
        ASSERT(result->size() >= min_size);
        FreeListChunk* next_chunk =
            reinterpret_cast<FreeListChunk*>(result->next_chunk());
        result->set_next_chunk(NULL);
        buckets_[i] = next_chunk;
        return result;
      }
    }

    // Search the bucket containing chunks that could, but are not
    // guaranteed to, satisfy the allocation.
    if (smallest_bucket > kNumberOfBuckets) smallest_bucket = kNumberOfBuckets;
    FreeListChunk* previous = reinterpret_cast<FreeListChunk*>(NULL);
    FreeListChunk* current = buckets_[smallest_bucket - 1];
    while (current != NULL) {
      if (current->size() >= min_size) {
        if (previous != NULL) {
          previous->set_next_chunk(current->next_chunk());
        } else {
          buckets_[smallest_bucket - 1] =
              reinterpret_cast<FreeListChunk*>(current->next_chunk());
        }
        current->set_next_chunk(NULL);
        return current;
      }
      previous = current;
      current = reinterpret_cast<FreeListChunk*>(current->next_chunk());
    }

    return NULL;
  }

  void Clear() {
    for (int i = 0; i < kNumberOfBuckets; i++) {
      buckets_[i] = NULL;
    }
  }

  void Merge(FreeList* other) {
    for (int i = 0; i < kNumberOfBuckets; i++) {
      FreeListChunk* chunk = other->buckets_[i];
      if (chunk != NULL) {
        FreeListChunk* last_chunk = chunk;
        while (last_chunk->next_chunk() != NULL) {
          last_chunk = FreeListChunk::cast(last_chunk->next_chunk());
        }
        last_chunk->set_next_chunk(buckets_[i]);
        buckets_[i] = chunk;
      }
    }
  }

 private:
  // Buckets of power of two sized free lists chunks. Bucket i
  // contains chunks of size larger than 2 ** (i + 1).
  static const int kNumberOfBuckets = 12;
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeListChunk* buckets_[kNumberOfBuckets];
#else
  FreeListChunk* buckets_[kNumberOfBuckets] = {NULL};
#endif
};

class SweepingVisitor : public HeapObjectVisitor {
 public:
  explicit SweepingVisitor(FreeList* free_list)
      : free_list_(free_list), free_start_(0), used_(0) {
    // Clear the free list. It will be rebuilt during sweeping.
    if (free_list_ != NULL) free_list_->Clear();
  }

  void AddFreeListChunk(uword free_end_) {
    if (free_start_ != 0) {
      uword free_size = free_end_ - free_start_;
      // When sweeping the new space we just remove mark bits, but don't build
      // free lists, since it is GCed by scavenge instead.
      if (free_list_ != NULL) free_list_->AddChunk(free_start_, free_size);
      free_start_ = 0;
    }
  }

  virtual int Visit(HeapObject* object) {
    if (object->IsMarked()) {
      AddFreeListChunk(object->address());
      object->ClearMark();
      int size = object->Size();
      used_ += size;
      return size;
    }
    int size = object->Size();
    if (free_start_ == 0) free_start_ = object->address();
    return size;
  }

  virtual void ChunkEnd(uword end) { AddFreeListChunk(end); }

  int used() const { return used_; }

 private:
  FreeList* free_list_;
  uword free_start_;
  int used_;
};

}  // namespace fletch

#endif  // SRC_VM_MARK_SWEEP_H_

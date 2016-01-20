// Copyright (c) 2014, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/program.h"

#include <stdlib.h>
#include <string.h>

#include "src/shared/assert.h"
#include "src/shared/flags.h"
#include "src/shared/globals.h"
#include "src/shared/names.h"
#include "src/shared/platform.h"
#include "src/shared/selectors.h"
#include "src/shared/utils.h"

#include "src/vm/frame.h"
#include "src/vm/heap_validator.h"
#include "src/vm/mark_sweep.h"
#include "src/vm/native_interpreter.h"
#include "src/vm/object.h"
#include "src/vm/port.h"
#include "src/vm/process.h"
#include "src/vm/session.h"

namespace fletch {

static List<const char> StringFromCharZ(const char* str) {
  return List<const char>(str, strlen(str));
}

void ProgramState::AddPausedProcess(Process* process) {
  ASSERT(process->next() == NULL);
  process->set_next(paused_processes_head_);
  set_paused_processes_head(process);
  ASSERT(paused_processes_head_ != paused_processes_head_->next());
}

Program::Program(ProgramSource source, int hashtag)
    :
#define CONSTRUCTOR_NULL(type, name, CamelName) name##_(NULL),
      ROOTS_DO(CONSTRUCTOR_NULL)
#undef CONSTRUCTOR_NULL
          process_list_mutex_(Platform::CreateMutex()),
      process_list_head_(NULL),
      random_(0),
      heap_(&random_),
      scheduler_(NULL),
      session_(NULL),
      entry_(NULL),
      loaded_from_snapshot_(source == Program::kLoadedFromSnapshot),
      program_exit_listener_(NULL),
      program_exit_listener_data_(NULL),
      exit_kind_(Signal::kTerminated),
      hashtag_(hashtag),
      stack_chain_(NULL) {
// These asserts need to hold when running on the target, but they don't need
// to hold on the host (the build machine, where the interpreter-generating
// program runs).  We put these asserts here on the assumption that the
// interpreter-generating program will not instantiate this class.
#define ASSERT_OFFSET(type, name, CamelName) \
  static_assert(k##CamelName##Offset == offsetof(Program, name##_), #name);
  ROOTS_DO(ASSERT_OFFSET)
#undef ASSERT_OFFSET
}

Program::~Program() {
  delete process_list_mutex_;
  ASSERT(process_list_head_ == NULL);
}

int Program::ExitCode() {
  switch (exit_kind()) {
    case Signal::kTerminated:
      return 0;
    case Signal::kCompileTimeError:
      return kCompileTimeErrorExitCode;
    case Signal::kUncaughtException:
      return kUncaughtExceptionExitCode;
    // TODO(kustermann): We should consider returning a different exitcode if a
    // process was killed via a signal or killed programmatically.
    case Signal::kUnhandledSignal:
      return kUncaughtExceptionExitCode;
    case Signal::kKilled:
      return kUncaughtExceptionExitCode;
    case Signal::kShouldKill:
      UNREACHABLE();
  }
  UNREACHABLE();
  return 0;
}

Process* Program::SpawnProcess(Process* parent) {
  Process* process = new Process(this, parent);

  // The counter part of this is in [ScheduleProcessFordeletion].
  if (parent != NULL) {
    parent->process_triangle_count_++;
  }

  AddToProcessList(process);
  return process;
}

Process* Program::ProcessSpawnForMain() {
  if (Flags::print_program_statistics) {
    PrintStatistics();
  }

  Process* process = SpawnProcess(NULL);
  Function* entry = process->entry();
  int main_arity = process->main_arity();
  process->SetupExecutionStack();
  Stack* stack = process->stack();
  uint8_t* bcp = entry->bytecode_address_for(0);
  word top = stack->length();
  stack->set(--top, NULL);
  stack->set(--top, NULL);
  Object** frame_pointer = stack->Pointer(top);
  stack->set(--top, NULL);
  stack->set(--top, Smi::FromWord(main_arity));
  // Push empty slot, fp and bcp.
  stack->set(--top, NULL);
  stack->set(--top, reinterpret_cast<Object*>(frame_pointer));
  frame_pointer = stack->Pointer(top);
  stack->set(--top, reinterpret_cast<Object*>(bcp));
  stack->set(--top, reinterpret_cast<Object*>(InterpreterEntry));
  stack->set(--top, reinterpret_cast<Object*>(frame_pointer));
  stack->set_top(top);

  return process;
}

bool Program::ScheduleProcessForDeletion(Process* process, Signal::Kind kind) {
  ASSERT(process->state() == Process::kWaitingForChildren);

  process->Cleanup(kind);

  // We are doing this up the process hierarchy.
  Process* current = process;
  while (current != NULL) {
    Process* parent = current->parent_;

    int new_count = --current->process_triangle_count_;
    ASSERT(new_count >= 0);
    if (new_count > 0) {
      return false;
    }

    // If this is the main process, we will save the exit kind.
    if (parent == NULL) {
      exit_kind_ = current->links()->exit_signal();
    }

    RemoveFromProcessList(current);
    delete current;

    current = parent;
  }
  return true;
}

void Program::VisitProcesses(ProcessVisitor* visitor) {
  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    visitor->VisitProcess(process);
  }
}

// TODO(erikcorry): Remove.
void Program::VisitProcessHeaps(ProcessVisitor* visitor) {
  if (process_list_head_ != NULL) {
    visitor->VisitProcess(process_list_head_);
  }
}

Object* Program::CreateArrayWith(int capacity, Object* initial_value) {
  Object* result = heap()->CreateArray(array_class(), capacity, initial_value);
  return result;
}

Object* Program::CreateByteArray(int capacity) {
  Object* result = heap()->CreateByteArray(byte_array_class(), capacity);
  return result;
}

Object* Program::CreateClass(int fields) {
  InstanceFormat format = InstanceFormat::instance_format(fields);
  Object* raw_class = heap()->CreateClass(format, meta_class(), null_object());
  if (raw_class->IsFailure()) return raw_class;
  Class* klass = Class::cast(raw_class);
  ASSERT(klass->NumberOfInstanceFields() == fields);
  return klass;
}

Object* Program::CreateDouble(fletch_double value) {
  return heap()->CreateDouble(double_class(), value);
}

Object* Program::CreateFunction(int arity, List<uint8> bytes,
                                int number_of_literals) {
  return heap()->CreateFunction(function_class(), arity, bytes,
                                number_of_literals);
}

Object* Program::CreateLargeInteger(int64 value) {
  return heap()->CreateLargeInteger(large_integer_class(), value);
}

Object* Program::CreateInteger(int64 value) {
  if ((sizeof(int64) > sizeof(word) &&
       static_cast<int64>(static_cast<word>(value)) != value) ||
      !Smi::IsValid(value)) {
    return CreateLargeInteger(value);
  }
  return Smi::FromWord(value);
}

Object* Program::CreateStringFromAscii(List<const char> str) {
  Object* raw_result = heap()->CreateOneByteStringUninitialized(
      one_byte_string_class(), str.length());
  if (raw_result->IsFailure()) return raw_result;
  OneByteString* result = OneByteString::cast(raw_result);
  ASSERT(result->length() == str.length());
  // Set the content.
  for (int i = 0; i < str.length(); i++) {
    result->set_char_code(i, str[i]);
  }
  return result;
}

Object* Program::CreateOneByteString(List<uint8> str) {
  Object* raw_result = heap()->CreateOneByteStringUninitialized(
      one_byte_string_class(), str.length());
  if (raw_result->IsFailure()) return raw_result;
  OneByteString* result = OneByteString::cast(raw_result);
  ASSERT(result->length() == str.length());
  // Set the content.
  for (int i = 0; i < str.length(); i++) {
    result->set_char_code(i, str[i]);
  }
  return result;
}

Object* Program::CreateTwoByteString(List<uint16> str) {
  Object* raw_result = heap()->CreateTwoByteStringUninitialized(
      two_byte_string_class(), str.length());
  if (raw_result->IsFailure()) return raw_result;
  TwoByteString* result = TwoByteString::cast(raw_result);
  ASSERT(result->length() == str.length());
  // Set the content.
  for (int i = 0; i < str.length(); i++) {
    result->set_code_unit(i, str[i]);
  }
  return result;
}

Object* Program::CreateInstance(Class* klass) {
  bool immutable = true;
  return heap()->CreateInstance(klass, null_object(), immutable);
}

Object* Program::CreateInitializer(Function* function) {
  return heap()->CreateInitializer(initializer_class_, function);
}

Object* Program::CreateDispatchTableEntry() {
  return heap()->CreateDispatchTableEntry(dispatch_table_entry_class_);
}

class ValidateProcessHeapVisitor : public ProcessVisitor {
 public:
  explicit ValidateProcessHeapVisitor(SharedHeap* shared_heap)
      : shared_heap_(shared_heap) {}

  virtual void VisitProcess(Process* process) {
    process->ValidateHeaps(shared_heap_);
  }

 private:
  SharedHeap* shared_heap_;
};

void Program::PrepareProgramGC() {
  // All threads are stopped and have given their parts back to the
  // [SharedHeap], so we can merge them now.
  shared_heap()->MergeParts();

  if (Flags::validate_heaps) {
    ValidateGlobalHeapsAreConsistent();
  }

  if (Flags::validate_heaps) {
    ValidateProcessHeapVisitor visitor(&shared_heap_);
    VisitProcesses(&visitor);
  }

  // We need to perform a precise GC to get rid of floating garbage stacks.
  // This is done by:
  // 1) An old-space GC, which is precise for global reachability.
  PerformSharedGarbageCollection();
  //    Old-space GC ignores the liveness information it has gathered in
  //    new-space, so this doesn't actually clean up the dead objects in
  //    new-space, so we do:
  // 2) A new-space GC, which will be precise, due to the old-space GC.
  //    (No floating garbage with pointers from old- to new-space.)
  CollectNewSpace();
  //    Now we have no floating garbage stacks.  We do:
  // 3) An old-space GC which (in the generational config) will find no
  //    garbage, but as a side effect it will chain up all the stacks (also
  //    the ones in new-space).  This does not move new-space objects.
  // TODO(erikcorry): An future simplification is to cook the stacks as we
  // find them during the program GC, instead of chaining them up beforehand
  // during a GC that is not needed in the generational config.
  int number_of_stacks = CollectMutableGarbageAndChainStacks();
  CookStacks(number_of_stacks);
}

class IterateProgramPointersVisitor : public ProcessVisitor {
 public:
  explicit IterateProgramPointersVisitor(PointerVisitor* pointer_visitor)
      : pointer_visitor_(pointer_visitor) {}

  virtual void VisitProcess(Process* process) {
    process->IterateProgramPointers(pointer_visitor_);
  }

 private:
  PointerVisitor* pointer_visitor_;
};

class IterateProgramPointersHeapVisitor : public ProcessVisitor {
 public:
  explicit IterateProgramPointersHeapVisitor(PointerVisitor* pointer_visitor)
      : pointer_visitor_(pointer_visitor) {}

  virtual void VisitProcess(Process* process) {
    process->IterateProgramPointersOnHeap(pointer_visitor_);
  }

 private:
  PointerVisitor* pointer_visitor_;
};

void Program::PerformProgramGC(SemiSpace* to, PointerVisitor* visitor) {
  {
    NoAllocationFailureScope scope(to);

    // Iterate program roots.
    IterateRoots(visitor);

    // Iterate all pointers from Immutable space to program space.
    HeapObjectPointerVisitor object_pointer_visitor(visitor);
    shared_heap_.heap()->IterateObjects(&object_pointer_visitor);

    // Iterate all pointers from processes to program space.
    IterateProgramPointersVisitor process_visitor(visitor);
    VisitProcesses(&process_visitor);

    // Iterate all pointers from process heaps to program space.
    IterateProgramPointersHeapVisitor heap_visitor(visitor);
    VisitProcessHeaps(&heap_visitor);

    // Finish collection.
    ASSERT(!to->is_empty());
    to->CompleteScavenge(visitor);
  }
  heap_.ReplaceSpace(to);
}

class FinishProgramGCVisitor : public ProcessVisitor {
 public:
  explicit FinishProgramGCVisitor(SharedHeap* shared_heap)
      : shared_heap_(shared_heap) {}

  virtual void VisitProcess(Process* process) {
    process->UpdateBreakpoints();
    if (Flags::validate_heaps) {
      // TODO(erikcorry): This should not be on the process.
      process->ValidateHeaps(shared_heap_);
    }
  }

 private:
  SharedHeap* shared_heap_;
};

void Program::FinishProgramGC() {
  // Uncook process
  UncookAndUnchainStacks();
  FinishProgramGCVisitor visitor(&shared_heap_);
  VisitProcesses(&visitor);

  if (Flags::validate_heaps) {
    ValidateGlobalHeapsAreConsistent();
  }
}

uword Program::OffsetOf(HeapObject* object) {
  ASSERT(is_optimized());
  return heap()->space()->OffsetOf(object);
}

void Program::ValidateGlobalHeapsAreConsistent() {
  ProgramHeapPointerValidator validator(heap());
  HeapObjectPointerVisitor visitor(&validator);
  IterateRoots(&validator);
  heap()->IterateObjects(&visitor);
}

void Program::ValidateHeapsAreConsistent() {
  // Validate the program heap.
  {
    ProgramHeapPointerValidator validator(heap());
    HeapObjectPointerVisitor object_pointer_visitor(&validator);
    IterateRoots(&validator);
    heap()->IterateObjects(&object_pointer_visitor);
  }

  // Validate the shared heap
  ValidateSharedHeap();

  // Validate all process heaps.
  {
    ProcessHeapValidatorVisitor validator(heap(), &shared_heap_);
    VisitProcesses(&validator);
  }
}

void Program::ValidateSharedHeap() {
  // NOTE: We do nothing in the case of *one* shared heap. The shared heap will
  // get validated (redundantly) for each process.
  //
  // (In order to validate the shared heap separately we would need to know
  //  whether stacks are cooked or not. This information is only available on a
  //  per-process basis ATM. So we just do it redundantly for now.)
}

void Program::CollectGarbage() {
  SemiSpace* to = new SemiSpace(heap_.space()->Used() / 10);
  ScavengeVisitor scavenger(heap_.space(), to);

  PrepareProgramGC();
  PerformProgramGC(to, &scavenger);
  FinishProgramGC();
}

void Program::AddToProcessList(Process* process) {
  ScopedLock locker(process_list_mutex_);

  ASSERT(process->process_list_next() == NULL &&
         process->process_list_prev() == NULL);
  process->set_process_list_next(process_list_head_);
  if (process_list_head_ != NULL) {
    process_list_head_->set_process_list_prev(process);
  }
  process_list_head_ = process;
}

void Program::RemoveFromProcessList(Process* process) {
  ScopedLock locker(process_list_mutex_);

  Process* next = process->process_list_next();
  Process* prev = process->process_list_prev();
  if (next != NULL) {
    next->set_process_list_prev(prev);
  }
  if (prev != NULL) {
    prev->set_process_list_next(next);
  } else {
    process_list_head_ = next;
  }
  process->set_process_list_next(NULL);
  process->set_process_list_prev(NULL);
}

struct SharedHeapUsage {
  uint64 timestamp = 0;
  uword shared_used = 0;
  uword shared_size = 0;
  uword shared_used_2 = 0;
  uword shared_size_2 = 0;
};

static void GetSharedHeapUsage(Heap* heap, SharedHeapUsage* heap_usage) {
  heap_usage->timestamp = Platform::GetMicroseconds();
  heap_usage->shared_used = heap->space()->Used();
  heap_usage->shared_size = heap->space()->Size();
  heap_usage->shared_used_2 = heap->old_space()->Used();
  heap_usage->shared_size_2 = heap->old_space()->Size();
}

static void PrintProgramGCInfo(SharedHeapUsage* before,
                               SharedHeapUsage* after) {
  static int count = 0;
  Print::Error(
      "Old-space-GC(%i):   "
      "\t%lli us,   "
      "\t\t\t\t\t%lu/%lu -> %lu/%lu\n",
      count++, after->timestamp - before->timestamp, before->shared_used_2,
      before->shared_size_2, after->shared_used_2, after->shared_size_2);
}

void Program::CollectSharedGarbage() {
  // All threads are stopped and have given their parts back to the
  // [SharedHeap], so we can merge them now.
  shared_heap()->MergeParts();

  if (Flags::validate_heaps) {
    ValidateHeapsAreConsistent();
  }

  SharedHeapUsage usage_before;
  if (Flags::print_heap_statistics) {
    GetSharedHeapUsage(shared_heap()->heap(), &usage_before);
  }

  PerformSharedGarbageCollection();

  if (Flags::print_heap_statistics) {
    SharedHeapUsage usage_after;
    GetSharedHeapUsage(shared_heap()->heap(), &usage_after);
    PrintProgramGCInfo(&usage_before, &usage_after);
  }

  if (Flags::validate_heaps) {
    ValidateHeapsAreConsistent();
  }
}

void Program::PerformSharedGarbageCollection() {
  // Mark all reachable objects.  We mark all live objects in new-space too, to
  // detect liveness paths that go through new-space, but we just clear the
  // mark bits afterwards.  Dead objects in new-space are only cleared in a
  // new-space GC (scavenge).
  Heap* heap = shared_heap()->heap();
  OldSpace* old_space = heap->old_space();
  SemiSpace* new_space = heap->space();
  MarkingStack stack;
  MarkingVisitor marking_visitor(new_space, old_space, &stack);
  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    process->IterateRoots(&marking_visitor);
  }
  stack.Process(&marking_visitor);
  heap->ProcessWeakPointers(old_space);

  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    process->set_ports(Port::CleanupPorts(old_space, process->ports()));
  }

  // Sweep over the old-space and rebuild the freelist.
  SweepingVisitor sweeping_visitor(old_space->free_list());
  old_space->IterateObjects(&sweeping_visitor);

  new_space->Flush();
  // We don't pass a free list so this visitor just clears the mark bits
  // without making free list entries.
  SweepingVisitor newspace_visitor(NULL);
  new_space->IterateObjects(&newspace_visitor);

  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    process->UpdateStackLimit();
  }

  old_space->set_used(sweeping_visitor.used());
  heap->AdjustOldAllocationBudget();
}

class StatisticsVisitor : public HeapObjectVisitor {
 public:
  StatisticsVisitor()
      : object_count_(0),
        class_count_(0),
        array_count_(0),
        array_size_(0),
        string_count_(0),
        string_size_(0),
        function_count_(0),
        function_size_(0),
        bytecode_size_(0) {}

  int object_count() const { return object_count_; }
  int class_count() const { return class_count_; }

  int array_count() const { return array_count_; }
  int array_size() const { return array_size_; }

  int string_count() const { return string_count_; }
  int string_size() const { return string_size_; }

  int function_count() const { return function_count_; }
  int function_size() const { return function_size_; }
  int bytecode_size() const { return bytecode_size_; }

  int function_header_size() const { return function_count_ * Function::kSize; }

  int Visit(HeapObject* object) {
    int size = object->Size();
    object_count_++;
    if (object->IsClass()) {
      VisitClass(Class::cast(object));
    } else if (object->IsArray()) {
      VisitArray(Array::cast(object));
    } else if (object->IsOneByteString()) {
      VisitOneByteString(OneByteString::cast(object));
    } else if (object->IsTwoByteString()) {
      VisitTwoByteString(TwoByteString::cast(object));
    } else if (object->IsFunction()) {
      VisitFunction(Function::cast(object));
    }
    return size;
  }

 private:
  int object_count_;

  int class_count_;

  int array_count_;
  int array_size_;

  int string_count_;
  int string_size_;

  int function_count_;
  int function_size_;

  int bytecode_size_;

  void VisitClass(Class* clazz) { class_count_++; }

  void VisitArray(Array* array) {
    array_count_++;
    array_size_ += array->ArraySize();
  }

  void VisitOneByteString(OneByteString* str) {
    string_count_++;
    string_size_ += str->StringSize();
  }

  void VisitTwoByteString(TwoByteString* str) {
    string_count_++;
    string_size_ += str->StringSize();
  }

  void VisitFunction(Function* function) {
    function_count_++;
    function_size_ += function->FunctionSize();
    bytecode_size_ += function->bytecode_size();
  }
};

void Program::PrintStatistics() {
  StatisticsVisitor statistics;
  heap_.space()->IterateObjects(&statistics);
  Print::Out("Program\n");
  Print::Out("  - size = %d bytes\n", heap_.space()->Used());
  Print::Out("  - objects = %d\n", statistics.object_count());
  Print::Out("  Classes\n");
  Print::Out("    - count = %d\n", statistics.class_count());
  Print::Out("  Arrays\n");
  Print::Out("    - count = %d\n", statistics.array_count());
  Print::Out("    - size = %d bytes\n", statistics.array_size());
  Print::Out("  Strings\n");
  Print::Out("    - count = %d\n", statistics.string_count());
  Print::Out("    - size = %d bytes\n", statistics.string_size());
  Print::Out("  Functions\n");
  Print::Out("    - count = %d\n", statistics.function_count());
  Print::Out("    - size = %d bytes\n", statistics.function_size());
  Print::Out("    - header size = %d bytes\n",
             statistics.function_header_size());
  Print::Out("    - bytecode size = %d bytes\n", statistics.bytecode_size());
}

void Program::Initialize() {
  // Create root set for the Program. During setup, do not fail
  // allocations, instead allocate new chunks.
  NoAllocationFailureScope scope(heap_.space());

  // Create null as the first object other allocated objects can use
  // null_object for initial values.
  InstanceFormat null_format =
      InstanceFormat::instance_format(0, InstanceFormat::NULL_MARKER);
  null_object_ =
      reinterpret_cast<Instance*>(heap()->Allocate(null_format.fixed_size()));

  meta_class_ = Class::cast(heap()->CreateMetaClass());

  {
    InstanceFormat format = InstanceFormat::array_format();
    array_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  empty_array_ = Array::cast(CreateArray(0));

  {
    InstanceFormat format = InstanceFormat::instance_format(0);
    object_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::num_format();
    num_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    num_class_->set_super_class(object_class_);
  }

  {
    InstanceFormat format = InstanceFormat::num_format();
    int_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    int_class_->set_super_class(num_class_);
  }

  {
    InstanceFormat format = InstanceFormat::smi_format();
    smi_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    smi_class_->set_super_class(int_class_);
  }

  {
    InstanceFormat format = InstanceFormat::heap_integer_format();
    large_integer_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    large_integer_class_->set_super_class(int_class_);
  }

  {
    InstanceFormat format = InstanceFormat::double_format();
    double_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    double_class_->set_super_class(num_class_);
  }

  {
    InstanceFormat format = InstanceFormat::boxed_format();
    boxed_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::stack_format();
    stack_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format =
        InstanceFormat::instance_format(2, InstanceFormat::COROUTINE_MARKER);
    coroutine_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format =
        InstanceFormat::instance_format(1, InstanceFormat::PORT_MARKER);
    port_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(1);
    process_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(2);
    process_death_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(4);
    foreign_memory_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::initializer_format();
    initializer_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::dispatch_table_entry_format();
    dispatch_table_entry_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(1);
    constant_list_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(1);
    constant_byte_list_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(2);
    constant_map_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::instance_format(3);
    no_such_method_error_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::one_byte_string_format();
    one_byte_string_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    one_byte_string_class_->set_super_class(object_class_);
  }

  {
    InstanceFormat format = InstanceFormat::two_byte_string_format();
    two_byte_string_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    two_byte_string_class_->set_super_class(object_class_);
  }

  empty_string_ = OneByteString::cast(
      heap()->CreateOneByteString(one_byte_string_class(), 0));

  {
    InstanceFormat format = InstanceFormat::function_format();
    function_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  {
    InstanceFormat format = InstanceFormat::byte_array_format();
    byte_array_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  // Setup the class for tearoff closures.
  {
    InstanceFormat format = InstanceFormat::instance_format(0);
    closure_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
  }

  Class* null_class;
  {  // Create null class and singleton.
    null_class = Class::cast(
        heap()->CreateClass(null_format, meta_class_, null_object_));
    null_class->set_super_class(object_class_);
    null_object_->set_class(null_class);
    null_object_->set_immutable(true);
    null_object_->InitializeIdentityHashCode(random());
    null_object_->Initialize(null_format.fixed_size(), null_object_);
  }

  {  // Create the bool class.
    InstanceFormat format = InstanceFormat::instance_format(0);
    bool_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    bool_class_->set_super_class(object_class_);
  }

  {  // Create False class and the false object.
    InstanceFormat format =
        InstanceFormat::instance_format(0, InstanceFormat::FALSE_MARKER);
    Class* false_class =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    false_class->set_super_class(bool_class_);
    false_class->set_methods(empty_array_);
    false_object_ = Instance::cast(
        heap()->CreateInstance(false_class, null_object(), true));
  }

  {  // Create True class and the true object.
    InstanceFormat format =
        InstanceFormat::instance_format(0, InstanceFormat::TRUE_MARKER);
    Class* true_class =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    true_class->set_super_class(bool_class_);
    true_class->set_methods(empty_array_);
    true_object_ =
        Instance::cast(heap()->CreateInstance(true_class, null_object(), true));
  }

  {  // Create stack overflow error object.
    InstanceFormat format = InstanceFormat::instance_format(0);
    stack_overflow_error_class_ =
        Class::cast(heap()->CreateClass(format, meta_class_, null_object_));
    stack_overflow_error_ = Instance::cast(heap()->CreateInstance(
        stack_overflow_error_class_, null_object(), true));
  }

  // Create the retry after gc failure object payload.
  raw_retry_after_gc_ = OneByteString::cast(
      CreateStringFromAscii(StringFromCharZ("Retry after GC.")));

  // Create the failure object payloads. These need to be kept in sync with the
  // constants in lib/system/system.dart.
  raw_wrong_argument_type_ = OneByteString::cast(
      CreateStringFromAscii(StringFromCharZ("Wrong argument type.")));

  raw_index_out_of_bounds_ = OneByteString::cast(
      CreateStringFromAscii(StringFromCharZ("Index out of bounds.")));

  raw_illegal_state_ = OneByteString::cast(
      CreateStringFromAscii(StringFromCharZ("Illegal state.")));

  native_failure_result_ = null_object_;
}

void Program::IterateRoots(PointerVisitor* visitor) {
  IterateRootsIgnoringSession(visitor);
  if (session_ != NULL) {
    session_->IteratePointers(visitor);
  }
}

void Program::IterateRootsIgnoringSession(PointerVisitor* visitor) {
  visitor->VisitBlock(first_root_address(), last_root_address() + 1);
  visitor->Visit(reinterpret_cast<Object**>(&entry_));
}

void Program::ClearDispatchTableIntrinsics() {
  Array* table = dispatch_table();
  if (table == NULL) return;

  int length = table->length();
  for (int i = 0; i < length; i++) {
    Object* element = table->get(i);
    DispatchTableEntry* entry = DispatchTableEntry::cast(element);
    entry->set_code(NULL);
  }
}

void Program::SetupDispatchTableIntrinsics(IntrinsicsTable* intrinsics) {
  Array* table = dispatch_table();
  if (table == NULL) return;

  int length = table->length();
  int hits = 0;

  DispatchTableEntry* entry = DispatchTableEntry::cast(table->get(0));
  Function* trampoline = entry->target();

  for (int i = 0; i < length; i++) {
    Object* element = table->get(i);
    DispatchTableEntry* entry = DispatchTableEntry::cast(element);
    if (entry->code() != NULL) {
      // The intrinsic is already set.
      hits++;
      continue;
    }
    Function* target = entry->target();
    if (target != trampoline) hits++;
    void* code = target->ComputeIntrinsic(intrinsics);
    if (code == NULL) {
      code = reinterpret_cast<void*>(InterpreterMethodEntry);
    }
    entry->set_code(code);
  }

  if (Flags::print_program_statistics) {
    Print::Out("Dispatch table fill: %F%% (%i of %i)\n", hits * 100.0 / length,
               hits, length);
  }
}

struct HeapUsage {
  uint64 timestamp = 0;
  uword process_used = 0;
  uword process_size = 0;
  uword immutable_used = 0;
  uword immutable_size = 0;
  uword program_used = 0;
  uword program_size = 0;

  uword TotalUsed() { return process_used + immutable_used + program_used; }
  uword TotalSize() { return process_used + immutable_size + program_size; }
};

static void GetHeapUsage(Heap* heap, HeapUsage* heap_usage) {
  heap_usage->timestamp = Platform::GetMicroseconds();
  heap_usage->process_used = heap->space()->Used();
  heap_usage->process_size = heap->space()->Size();
  heap_usage->program_used = heap->old_space()->Used();
  heap_usage->program_size = heap->old_space()->Size();
}

void PrintProcessGCInfo(HeapUsage* before, HeapUsage* after) {
  static int count = 0;
  if ((count & 0xF) == 0) {
    Print::Error(
        "New-space-GC,\t\tElapsed, "
        "\tNew-space use/sizeu,"
        "\t\tOld-space use/size\n");
  }
  Print::Error(
      "New-space-GC(%i): "
      "\t%lli us,   "
      "\t%lu/%lu -> %lu/%lu,   "
      "\t%lu/%lu -> %lu/%lu\n",
      count++, after->timestamp - before->timestamp, before->process_used,
      before->process_size, after->process_used, after->process_size,
      before->program_used, before->program_size, after->program_used,
      after->program_size);
}

// Somewhat misnamed - it does a scavenge of the data area used by the
// processes, not the code area used by the program.
void Program::CollectNewSpace() {
  HeapUsage usage_before;

  Heap* data_heap = shared_heap()->heap();

  SemiSpace* from = data_heap->space();
  OldSpace* old = data_heap->old_space();

  if (!data_heap->allocations_have_taken_place()) {
    return;
  }

  old->Flush();
  from->Flush();

  if (Flags::print_heap_statistics) {
    GetHeapUsage(data_heap, &usage_before);
  }

  SemiSpace* to = new SemiSpace(from->Used() / 10);

  // While garbage collecting, do not fail allocations. Instead grow
  // the to-space as needed.
  NoAllocationFailureScope scope(to);
  NoAllocationFailureScope scope2(old);

  GenerationalScavengeVisitor visitor(from, to, old);
  to->StartScavenge();
  old->StartScavenge();

  Process* current = process_list_head_;
  while (current != NULL) {
    current->IterateRoots(&visitor);
    current = current->process_list_next();
  }

  old->VisitRememberedSet(&visitor);

  bool work_found = true;
  while (work_found) {
    work_found = to->CompleteScavengeGenerational(&visitor);
    work_found |= old->CompleteScavengeGenerational(&visitor);
  }
  old->EndScavenge();

  data_heap->ProcessWeakPointers(from);

  current = process_list_head_;
  while (current != NULL) {
    current->set_ports(Port::CleanupPorts(from, current->ports()));
    current = current->process_list_next();
  }

  // Second space argument is used to size the new-space.
  data_heap->ReplaceSpace(to, old);

  if (Flags::print_heap_statistics) {
    HeapUsage usage_after;
    GetHeapUsage(data_heap, &usage_after);
    PrintProcessGCInfo(&usage_before, &usage_after);
  }

  if (old->needs_garbage_collection()) {
    CollectSharedGarbage();
  }

  UpdateStackLimits();
}

void Program::UpdateStackLimits() {
  Process* current = process_list_head_;
  while (current != NULL) {
    current->UpdateStackLimit();
    current = current->process_list_next();
  }
}

int Program::CollectMutableGarbageAndChainStacks() {
  // Mark all reachable objects.
  OldSpace* old_space = shared_heap()->heap()->old_space();
  SemiSpace* new_space = shared_heap()->heap()->space();
  MarkingStack marking_stack;
  ASSERT(stack_chain_ == NULL);
  MarkingVisitor marking_visitor(new_space, old_space, &marking_stack,
                                 &stack_chain_);

  // All processes share the same heap, so we need to iterate all roots from
  // all processes.
  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    process->IterateRoots(&marking_visitor);
  }

  marking_stack.Process(&marking_visitor);

  // Weak processing.
  shared_heap()->heap()->ProcessWeakPointers(old_space);
  for (Process* process = process_list_head_; process != NULL;
       process = process->process_list_next()) {
    process->set_ports(Port::CleanupPorts(old_space, process->ports()));
  }

  // Flush outstanding free_list chunks into the free list. Then sweep
  // over the heap and rebuild the freelist.
  old_space->Flush();
  SweepingVisitor sweeping_visitor(old_space->free_list());
  old_space->IterateObjects(&sweeping_visitor);

  // TODO(erikcorry): Find a better way to delete the mark bits on the new
  // space.
  SweepingVisitor new_space_sweeper(NULL);
  new_space->IterateObjects(&new_space_sweeper);

  UpdateStackLimits();
  return marking_visitor.number_of_stacks();
}

void Program::CookStacks(int number_of_stacks) {
  cooked_stack_deltas_ = List<List<int>>::New(number_of_stacks);
  Object* raw_current = stack_chain_;
  for (int i = 0; i < number_of_stacks; ++i) {
    Stack* current = Stack::cast(raw_current);
    int number_of_frames = 0;
    for (Frame count_frames(current); count_frames.MovePrevious();) {
      number_of_frames++;
    }
    cooked_stack_deltas_[i] = List<int>::New(number_of_frames);
    int index = 0;
    for (Frame frame(current); frame.MovePrevious();) {
      Function* function = frame.FunctionFromByteCodePointer();
      if (function == NULL) continue;
      uint8* start = function->bytecode_address_for(0);
      int delta = frame.ByteCodePointer() - start;
      cooked_stack_deltas_[i][index++] = delta;
      frame.SetByteCodePointer(reinterpret_cast<uint8*>(function));
    }
    raw_current = current->next();
  }
  ASSERT(raw_current == Smi::zero());
}

void Program::UncookAndUnchainStacks() {
  Object* raw_current = stack_chain_;
  for (int i = 0; i < cooked_stack_deltas_.length(); ++i) {
    Stack* current = Stack::cast(raw_current);
    int index = 0;
    Frame frame(current);
    while (frame.MovePrevious()) {
      Object* value = reinterpret_cast<Object*>(frame.ByteCodePointer());
      if (value == NULL) continue;
      int delta = cooked_stack_deltas_[i][index++];
      Function* function = Function::cast(value);
      uint8* bcp = function->bytecode_address_for(0) + delta;
      frame.SetByteCodePointer(bcp);
    }
    cooked_stack_deltas_[i].Delete();
    raw_current = current->next();
    current->set_next(Smi::FromWord(0));
  }
  ASSERT(raw_current == Smi::zero());
  cooked_stack_deltas_.Delete();
  stack_chain_ = NULL;
}

}  // namespace fletch

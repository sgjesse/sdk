// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_INTRINSICS_H_
#define SRC_VM_INTRINSICS_H_

#include "src/shared/globals.h"

namespace dartino {

#define INTRINSICS_DO(V) \
  V(ObjectEquals)        \
  V(GetField)            \
  V(SetField)            \
  V(ListIndexGet)        \
  V(ListIndexSet)        \
  V(ListLength)

#define DECLARE_EXTERN(name) extern "C" void Intrinsic_##name();
INTRINSICS_DO(DECLARE_EXTERN)
#undef DECLARE_EXTERN

class IntrinsicsTable {
 public:
  IntrinsicsTable()
      :
#define NULL_INITIALIZER(name) intrinsic_##name##_(NULL),
        INTRINSICS_DO(NULL_INITIALIZER)
#undef NULL_INITIALIZER
            last_member_(NULL) {
  }

  IntrinsicsTable(
#define PARAMETER_NAME(name) void (*name)(void),
      INTRINSICS_DO(PARAMETER_NAME)
#undef PARAMETER_NAME
          void (*last_member)(void))
      :
#define VALUE_INITIALIZER(name) intrinsic_##name##_(name),
        INTRINSICS_DO(VALUE_INITIALIZER)
#undef PARAMETER_NAME
            last_member_(last_member) {
    USE(last_member_);
  }

  static IntrinsicsTable* GetDefault();

#define DEFINE_GETTER(name) \
  void (*name())(void) { return intrinsic_##name##_; }
  INTRINSICS_DO(DEFINE_GETTER)
#undef DEFINE_GETTER
#define DEFINE_SETTER(name) \
  void set_##name(void (*ptr)(void)) { intrinsic_##name##_ = ptr; }
  INTRINSICS_DO(DEFINE_SETTER)
#undef DEFINE_SETTER

  bool set_from_string(const char *name, void (*ptr)(void));

 private:
#define DECLARE_FIELD(name) void (*intrinsic_##name##_)(void);
  INTRINSICS_DO(DECLARE_FIELD)
#undef DECLARE_FIELD
  void (*last_member_)(void);

  static IntrinsicsTable* default_table_;
};

}  // namespace dartino

#endif  // SRC_VM_INTRINSICS_H_

// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Generated file. Do not edit.

#ifndef TODOMVC_SERVICE_H
#define TODOMVC_SERVICE_H

#include <inttypes.h>
#include "struct.h"

class Node;
class NodeBuilder;
class Cons;
class ConsBuilder;
class Str;
class StrBuilder;
class Patch;
class PatchBuilder;
class PatchSet;
class PatchSetBuilder;

class TodoMVCService {
 public:
  static void setup();
  static void tearDown();
  static void createItem(StrBuilder title);
  static void deleteItem(int32_t id);
  static void deleteItemAsync(int32_t id, void (*callback)());
  static void completeItem(int32_t id);
  static void completeItemAsync(int32_t id, void (*callback)());
  static void clearItems();
  static void clearItemsAsync(void (*callback)());
  static PatchSet sync();
};

class Node : public Reader {
 public:
  static const int kSize = 24;
  Node(Segment* segment, int offset)
      : Reader(segment, offset) { }

  bool isNil() const { return 1 == getTag(); }
  bool isNum() const { return 2 == getTag(); }
  int32_t getNum() const { return *PointerTo<int32_t>(0); }
  bool isBool() const { return 3 == getTag(); }
  bool getBool() const { return *PointerTo<uint8_t>(0) != 0; }
  bool isStr() const { return 4 == getTag(); }
  Str getStr() const;
  bool isCons() const { return 5 == getTag(); }
  Cons getCons() const;
  uint16_t getTag() const { return *PointerTo<uint16_t>(16); }
};

class NodeBuilder : public Builder {
 public:
  static const int kSize = 24;

  explicit NodeBuilder(const Builder& builder)
      : Builder(builder) { }
  NodeBuilder(Segment* segment, int offset)
      : Builder(segment, offset) { }

  void setNil() { setTag(1); }
  void setNum(int32_t value) { setTag(2); *PointerTo<int32_t>(0) = value; }
  void setBool(bool value) { setTag(3); *PointerTo<uint8_t>(0) = value ? 1 : 0; }
  StrBuilder initStr();
  ConsBuilder initCons();
  void setTag(uint16_t value) { *PointerTo<uint16_t>(16) = value; }
};

class Cons : public Reader {
 public:
  static const int kSize = 16;
  Cons(Segment* segment, int offset)
      : Reader(segment, offset) { }

  Node getFst() const;
  Node getSnd() const;
};

class ConsBuilder : public Builder {
 public:
  static const int kSize = 16;

  explicit ConsBuilder(const Builder& builder)
      : Builder(builder) { }
  ConsBuilder(Segment* segment, int offset)
      : Builder(segment, offset) { }

  NodeBuilder initFst();
  NodeBuilder initSnd();
};

class Str : public Reader {
 public:
  static const int kSize = 8;
  Str(Segment* segment, int offset)
      : Reader(segment, offset) { }

  List<uint8_t> getChars() const { return ReadList<uint8_t>(0); }
};

class StrBuilder : public Builder {
 public:
  static const int kSize = 8;

  explicit StrBuilder(const Builder& builder)
      : Builder(builder) { }
  StrBuilder(Segment* segment, int offset)
      : Builder(segment, offset) { }

  List<uint8_t> initChars(int length);
};

class Patch : public Reader {
 public:
  static const int kSize = 32;
  Patch(Segment* segment, int offset)
      : Reader(segment, offset) { }

  Node getContent() const;
  List<uint8_t> getPath() const { return ReadList<uint8_t>(24); }
};

class PatchBuilder : public Builder {
 public:
  static const int kSize = 32;

  explicit PatchBuilder(const Builder& builder)
      : Builder(builder) { }
  PatchBuilder(Segment* segment, int offset)
      : Builder(segment, offset) { }

  NodeBuilder initContent();
  List<uint8_t> initPath(int length);
};

class PatchSet : public Reader {
 public:
  static const int kSize = 8;
  PatchSet(Segment* segment, int offset)
      : Reader(segment, offset) { }

  List<Patch> getPatches() const { return ReadList<Patch>(0); }
};

class PatchSetBuilder : public Builder {
 public:
  static const int kSize = 8;

  explicit PatchSetBuilder(const Builder& builder)
      : Builder(builder) { }
  PatchSetBuilder(Segment* segment, int offset)
      : Builder(segment, offset) { }

  List<PatchBuilder> initPatches(int length);
};

#endif  // TODOMVC_SERVICE_H

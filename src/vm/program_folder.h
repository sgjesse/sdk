// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_PROGRAM_FOLDER_H_
#define SRC_VM_PROGRAM_FOLDER_H_

#ifdef FLETCH_ENABLE_LIVE_CODING

namespace fletch {

class Function;
class Object;
class Program;
class ProgramTableRewriter;
class SemiSpace;

// ProgramFolder used for folding and unfolding a Program.
class ProgramFolder {
 public:
  explicit ProgramFolder(Program* program) : program_(program) {}

  // Fold the program into a compact format where methods, classes and
  // constants are stored in global tables in the program instead of
  // duplicated out in the literals sections of methods. The caller of
  // Fold should stop all processes running for this program before calling.
  void Fold();

  // Unfold the program into a new heap where all indices are resolved
  // and stored in the literals section of methods. Having
  // self-contained methods makes it easier to do changes to the live
  // system. The caller of Unfold should stop all processes running for this
  // program before calling.
  void Unfold();

  Program* program() const { return program_; }

  // Will fold the program if not overridden by -Xunfold-program.
  static void FoldProgramByDefault(Program* program);

 private:
  Program* const program_;
};

}  // namespace fletch

#endif  // FLETCH_ENABLE_LIVE_CODING

#endif  // SRC_VM_PROGRAM_FOLDER_H_

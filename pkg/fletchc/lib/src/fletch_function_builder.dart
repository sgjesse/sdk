// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.compiled_function;

import 'package:compiler/src/constants/values.dart' show
    ConstantValue;

import 'package:compiler/src/elements/elements.dart';

import 'fletch_constants.dart' show
    FletchFunctionConstant,
    FletchClassConstant;

import '../bytecodes.dart' show
    Bytecode,
    Opcode;

import 'fletch_context.dart';
import 'bytecode_assembler.dart';

import '../fletch_system.dart';
import '../vm_commands.dart';

class FletchFunctionBuilder extends FletchFunctionBase {
  final BytecodeAssembler assembler;

  /**
   * If the functions is an instance member, [memberOf] is set to the id of the
   * class.
   *
   * If [memberOf] is set, the compiled function takes an 'this' argument in
   * addition to that of [signature].
   */
  final Map<ConstantValue, int> constants = <ConstantValue, int>{};
  final Map<int, ConstantValue> functionConstantValues = <int, ConstantValue>{};
  final Map<int, ConstantValue> classConstantValues = <int, ConstantValue>{};

  FletchFunctionBuilder.fromFletchFunction(FletchFunction function)
      : this(
          function.functionId,
          function.kind,
          function.arity,
          name: function.name,
          element: function.element,
          memberOf: function.memberOf);

  FletchFunctionBuilder(
      int functionId,
      FletchFunctionKind kind,
      int arity,
      {String name,
       Element element,
       FunctionSignature signature,
       int memberOf})
      : super(functionId, kind, arity, name, element, signature, memberOf),
        assembler = new BytecodeAssembler(arity) {
    assert(signature == null ||
        arity == (signature.parameterCount + (isInstanceMember ? 1 : 0)));
  }

  void reuse() {
    assembler.reuse();
    constants.clear();
    functionConstantValues.clear();
    classConstantValues.clear();
  }

  int allocateConstant(ConstantValue constant) {
    if (constant == null) throw "bad constant";
    return constants.putIfAbsent(constant, () => constants.length);
  }

  int allocateConstantFromFunction(int functionId) {
    FletchFunctionConstant constant =
        functionConstantValues.putIfAbsent(
            functionId, () => new FletchFunctionConstant(functionId));
    return allocateConstant(constant);
  }

  int allocateConstantFromClass(int classId) {
    FletchClassConstant constant =
        classConstantValues.putIfAbsent(
            classId, () => new FletchClassConstant(classId));
    return allocateConstant(constant);
  }

  // TODO(ajohnsen): Remove this function when usage is avoided in
  // FletchBackend.
  void copyFrom(FletchFunctionBuilder function) {
    assembler.bytecodes.addAll(function.assembler.bytecodes);
    assembler.catchRanges.addAll(function.assembler.catchRanges);
    constants.addAll(function.constants);
    functionConstantValues.addAll(function.functionConstantValues);
    classConstantValues.addAll(function.classConstantValues);
  }

  FletchFunction finalizeFunction(
      FletchContext context,
      List<VmCommand> commands) {
    int constantCount = constants.length;
    for (int i = 0; i < constantCount; i++) {
      commands.add(const PushNull());
    }

    assert(assembler.bytecodes.last.opcode == Opcode.MethodEnd);

    commands.add(
        new PushNewFunction(
            assembler.functionArity,
            constantCount,
            assembler.bytecodes,
            assembler.catchRanges));

    commands.add(new PopToMap(MapId.methods, functionId));

    return new FletchFunction(
        functionId,
        kind,
        arity,
        name,
        element,
        signature,
        assembler.bytecodes,
        createFletchConstants(context),
        memberOf);
  }

  List<FletchConstant> createFletchConstants(FletchContext context) {
    List<FletchConstant> fletchConstants = <FletchConstant>[];

    constants.forEach((constant, int index) {
      if (constant is ConstantValue) {
        if (constant is FletchFunctionConstant) {
          fletchConstants.add(
              new FletchConstant(constant.functionId, MapId.methods));
        } else if (constant is FletchClassConstant) {
          fletchConstants.add(
              new FletchConstant(constant.classId, MapId.classes));
        } else {
          int id = context.lookupConstantIdByValue(constant);
          if (id == null) {
            throw "Unsupported constant: ${constant.toStructuredString()}";
          }
          fletchConstants.add(
              new FletchConstant(id, MapId.constants));
        }
      } else {
        throw "Unsupported constant: ${constant.runtimeType}";
      }
    });

    return fletchConstants;
  }

  String verboseToString() {
    StringBuffer sb = new StringBuffer();

    sb.writeln("Function $functionId, Arity=${assembler.functionArity}");
    sb.writeln("Constants:");
    constants.forEach((constant, int index) {
      if (constant is ConstantValue) {
        constant = constant.toStructuredString();
      }
      sb.writeln("  #$index: $constant");
    });

    sb.writeln("Bytecodes (${assembler.byteSize} bytes):");
    Bytecode.prettyPrint(sb, assembler.bytecodes);

    return '$sb';
  }
}

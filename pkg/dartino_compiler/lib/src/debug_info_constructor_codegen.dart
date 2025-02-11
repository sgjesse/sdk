// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dartino_compiler.debug_info_constructor_codegen;

import 'package:compiler/src/elements/elements.dart' show
    ConstructorElement,
    Element,
    FieldElement,
    Name;

import 'package:compiler/src/universe/selector.dart' show
    Selector;

import 'package:compiler/src/tree/tree.dart' show
    CaseMatch,
    Node,
    Send;

import 'package:compiler/src/resolution/tree_elements.dart' show
    TreeElements;

import 'package:compiler/src/dart_types.dart' show
    DartType;

import 'package:compiler/src/diagnostics/spannable.dart' show
    Spannable;

import 'bytecode_assembler.dart' show
    BytecodeLabel;

import 'closure_environment.dart' show
    ClosureEnvironment;

import 'codegen_visitor.dart' show
    LocalValue;

import 'dartino_function_builder.dart' show
    DartinoFunctionBuilder;

import '../dartino_class_base.dart' show
    DartinoClassBase;

import 'dartino_registry.dart' show
    DartinoRegistry;

import 'debug_registry.dart' show
    DebugRegistry;

import 'dartino_context.dart' show
    BytecodeLabel,
    DartinoCompilerImplementation,
    DartinoContext;

import 'constructor_codegen.dart' show
    ConstructorCodegenBase;

import 'debug_info_lazy_field_initializer_codegen.dart' show
    DebugInfoLazyFieldInitializerCodegen;

import 'debug_info.dart' show
    DebugInfo;

class DebugInfoConstructorCodegen extends ConstructorCodegenBase
    with DebugRegistry {
  final DebugInfo debugInfo;
  final DartinoCompilerImplementation compiler;

  DebugInfoConstructorCodegen(
      this.debugInfo,
      DartinoFunctionBuilder functionBuilder,
      DartinoContext context,
      TreeElements elements,
      ClosureEnvironment closureEnvironment,
      ConstructorElement constructor,
      DartinoClassBase classBase,
      this.compiler)
      : super(functionBuilder, context, elements, closureEnvironment,
              constructor, classBase);

  DebugInfoLazyFieldInitializerCodegen lazyFieldInitializerCodegenFor(
      DartinoFunctionBuilder function,
      FieldElement field) {
    TreeElements elements = field.resolvedAst.elements;
    return new DebugInfoLazyFieldInitializerCodegen(
        debugInfo,
        function,
        context,
        elements,
        context.backend.createClosureEnvironment(field, elements),
        field,
        compiler);
  }

  void recordDebugInfo(Node node) {
    debugInfo.addLocation(compiler, assembler.byteSize, node);
  }

  void pushVariableDeclaration(LocalValue value) {
    super.pushVariableDeclaration(value);
    debugInfo.pushScope(assembler.byteSize, value);
  }

  void popVariableDeclaration(Element element) {
    super.popVariableDeclaration(element);
    debugInfo.popScope(assembler.byteSize);
  }

  void doFieldInitializerSet(Send node, FieldElement field) {
    recordDebugInfo(node);
    super.doFieldInitializerSet(node, field);
  }

  void handleAllocationAndBodyCall() {
    // Clear out debug information after the initializer list. This avoids
    // seeing the code that sets up for the body call as part of the last
    // initializer evaluation.
    recordDebugInfo(null);
    super.handleAllocationAndBodyCall();
  }

  void callIsSelector(
      Node node,
      DartType type,
      Spannable diagnosticLocation) {
    recordDebugInfo(node);
    super.callIsSelector(node, type, diagnosticLocation);
  }

  void invokeMethod(Node node, Selector selector) {
    recordDebugInfo(node);
    super.invokeMethod(node, selector);
  }

  void invokeGetter(Node node, Name name) {
    recordDebugInfo(node);
    super.invokeGetter(node, name);
  }

  void invokeSetter(Node node, Name name) {
    recordDebugInfo(node);
    super.invokeSetter(node, name);
  }

  void invokeFactory(Node node, int constId, int arity) {
    recordDebugInfo(node);
    super.invokeFactory(node, constId, arity);
  }

  void invokeStatic(Node node, int constId, int arity) {
    recordDebugInfo(node);
    super.invokeStatic(node, constId, arity);
  }

  void generateReturn(Node node) {
    recordDebugInfo(node);
    super.generateReturn(node);
  }

  void generateSwitchCaseMatch(CaseMatch caseMatch, BytecodeLabel ifTrue) {
    // We do not want to break on the evaluation of the individual
    // case equality tests.
    recordDebugInfo(null);
    super.generateSwitchCaseMatch(caseMatch, ifTrue);
  }

  void generateIdentical(Node node) {
    recordDebugInfo(node);
    super.generateIdentical(node);
  }

  void generateIdenticalNonNumeric(Node node) {
    recordDebugInfo(node);
    super.generateIdenticalNonNumeric(node);
  }

  void generateThrow(Node node) {
    recordDebugInfo(node);
    super.generateThrow(node);
  }

  void visitForValue(Node node) {
    recordDebugInfo(node);
    super.visitForValue(node);
  }

  void visitForEffect(Node node) {
    recordDebugInfo(node);
    super.visitForEffect(node);
  }
}

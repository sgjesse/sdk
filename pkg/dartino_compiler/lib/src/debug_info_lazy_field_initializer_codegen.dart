// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dartino_compiler.debug_info_lazy_field_initializer_codegen;

import 'package:compiler/src/elements/elements.dart' show
    Element,
    FieldElement,
    Name;

import 'package:compiler/src/resolution/tree_elements.dart' show
    TreeElements;

import 'package:compiler/src/tree/tree.dart' show
    CaseMatch,
    Node;

import 'package:compiler/src/universe/selector.dart' show
    Selector;

import 'package:compiler/src/dart_types.dart' show
    DartType;

import 'package:compiler/src/diagnostics/spannable.dart' show
    Spannable;

import 'dartino_context.dart' show
    BytecodeLabel,
    DartinoCompilerImplementation,
    DartinoContext;

import 'dartino_function_builder.dart' show
    DartinoFunctionBuilder;

import 'dartino_registry.dart' show
    DartinoRegistry;

import 'debug_registry.dart' show
    DebugRegistry;

import 'closure_environment.dart' show
    ClosureEnvironment;

import 'codegen_visitor.dart' show
    LocalValue;

import 'lazy_field_initializer_codegen.dart' show
    LazyFieldInitializerCodegenBase;

import 'debug_info.dart' show
    DebugInfo;

class DebugInfoLazyFieldInitializerCodegen
    extends LazyFieldInitializerCodegenBase with DebugRegistry {
  final DebugInfo debugInfo;
  final DartinoCompilerImplementation compiler;

  DebugInfoLazyFieldInitializerCodegen(
      this.debugInfo,
      DartinoFunctionBuilder functionBuilder,
      DartinoContext context,
      TreeElements elements,
      ClosureEnvironment closureEnvironment,
      FieldElement field,
      this.compiler)
      : super(functionBuilder, context, elements, closureEnvironment, field);

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

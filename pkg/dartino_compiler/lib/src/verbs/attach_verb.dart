// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dartino_compiler.verbs.attach_verb;

import 'infrastructure.dart';

import 'documentation.dart' show
    attachDocumentation;

import '../worker/developer.dart' show
    Address,
    attachToVm,
    parseAddress;

const Action attachAction = const Action(
    attach, attachDocumentation, requiresSession: true,
    requiredTarget: TargetKind.TCP_SOCKET);

Future<int> attach(AnalyzedSentence sentence, VerbContext context) {
  Address address = parseAddress(sentence.targetName);
  return context.performTaskInWorker(
      new AttachTask(address.host, address.port));
}

class AttachTask extends SharedTask {
  // Keep this class simple, see note in superclass.

  final String host;

  final int port;

  const AttachTask(this.host, this.port);

  Future<int> call(
      CommandSender commandSender,
      StreamIterator<ClientCommand> commandIterator) {
    return attachTask(host, port);
  }
}

Future<int> attachTask(String host, int port) async {
  SessionState state = SessionState.current;

  // Cleanup previous session if any.
  await state.terminateSession();

  state.explicitAttach = true;
  await attachToVm(host, port, state);
  return 0;
}

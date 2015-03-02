// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library runtime_configuration;

import 'dart:io' show
    Platform;

import 'compiler_configuration.dart' show
    CommandArtifact;

// TODO(ahe): Remove this import, we can precompute all the values required
// from TestSuite once the refactoring is complete.
import 'test_suite.dart' show
    TestSuite;

import 'test_runner.dart' show
    Command,
    CommandBuilder;

// TODO(ahe): I expect this class will become abstract very soon.
class RuntimeConfiguration {
  // TODO(ahe): Remove this constructor and move the switch to
  // test_options.dart.  We probably want to store an instance of
  // [RuntimeConfiguration] in [configuration] there.
  factory RuntimeConfiguration(Map configuration) {
    String runtime = configuration['runtime'];
    switch (runtime) {
      case 'ContentShellOnAndroid':
      case 'DartiumOnAndroid':
      case 'chrome':
      case 'chromeOnAndroid':
      case 'dartium':
      case 'ff':
      case 'firefox':
      case 'ie11':
      case 'ie10':
      case 'ie9':
      case 'opera':
      case 'safari':
      case 'safarimobilesim':
        // TODO(ahe): Replace this with one or more browser runtimes.
        return new DummyRuntimeConfiguration();

      case 'jsshell':
        return new JsshellRuntimeConfiguration();

      case 'd8':
        return new D8RuntimeConfiguration();

      case 'none':
        return new NoneRuntimeConfiguration();

      case 'vm':
        return new StandaloneDartRuntimeConfiguration();

      case 'fletchc':
        return new FletchcRuntimeConfiguration();

      case 'drt':
        return new DrtRuntimeConfiguration();

      default:
        throw "Unknown runtime '$runtime'";
    }
  }

  RuntimeConfiguration._subclass();

  int computeTimeoutMultiplier({
      bool isDebug: false,
      bool isChecked: false,
      String arch}) {
    return 1;
  }

  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    // TODO(ahe): Make this method abstract.
    throw "Unimplemented runtime '$runtimeType'";
  }

  List<String> dart2jsPreambles(Uri preambleDir) => [];
}

/// The 'none' runtime configuration.
class NoneRuntimeConfiguration extends RuntimeConfiguration {
  NoneRuntimeConfiguration()
      : super._subclass();

  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    return <Command>[];
  }
}

class CommandLineJavaScriptRuntime extends RuntimeConfiguration {
  final String moniker;

  CommandLineJavaScriptRuntime(this.moniker)
      : super._subclass();

  void checkArtifact(CommandArtifact artifact) {
    String type = artifact.mimeType;
    if (type != 'application/javascript') {
      throw "Runtime '$moniker' cannot run files of type '$type'.";
    }
  }
}

/// Chrome/V8-based development shell (d8).
class D8RuntimeConfiguration extends CommandLineJavaScriptRuntime {
  D8RuntimeConfiguration()
      : super('d8');

  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    // TODO(ahe): Avoid duplication of this method between d8 and jsshell.
    checkArtifact(artifact);
    return <Command>[
        commandBuilder.getJSCommandlineCommand(
            moniker, suite.d8FileName, arguments, environmentOverrides)];
  }

  List<String> dart2jsPreambles(Uri preambleDir) {
    return [preambleDir.resolve('d8.js').toFilePath()];
  }
}

/// Firefox/SpiderMonkey-based development shell (jsshell).
class JsshellRuntimeConfiguration extends CommandLineJavaScriptRuntime {
  JsshellRuntimeConfiguration()
      : super('jsshell');

  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    checkArtifact(artifact);
    return <Command>[
        commandBuilder.getJSCommandlineCommand(
            moniker, suite.jsShellFileName, arguments, environmentOverrides)];
  }

  List<String> dart2jsPreambles(Uri preambleDir) {
    return ['-f', preambleDir.resolve('jsshell.js').toFilePath(), '-f'];
  }
}

/// Common runtime configuration for runtimes based on the Dart VM.
class DartVmRuntimeConfiguration extends RuntimeConfiguration {
  DartVmRuntimeConfiguration()
      : super._subclass();

  int computeTimeoutMultiplier({
      bool isDebug: false,
      bool isChecked: false,
      String arch}) {
    int multiplier = 1;
    switch (arch) {
      case 'simarm':
      case 'arm':
      case 'simmips':
      case 'mips':
      case 'simarm64':
        multiplier *= 4;
        break;
    }
    if (isDebug) {
      multiplier *= 2;
    }
    return multiplier;
  }
}

/// Runtime configuration for Content Shell.  We previously used a similar
/// program named Dump Render Tree, hence the name.
class DrtRuntimeConfiguration extends DartVmRuntimeConfiguration {
  int computeTimeoutMultiplier({
      bool isDebug: false,
      bool isChecked: false,
      String arch}) {
    return 4 // Allow additional time for browser testing to run.
        // TODO(ahe): We might need to distinquish between DRT for running
        // JavaScript and Dart code.  I'm not convinced the inherited timeout
        // multiplier is relevant for JavaScript.
        * super.computeTimeoutMultiplier(
            isDebug: isDebug, isChecked: isChecked);
  }
}

/// The standalone Dart VM binary, "dart" or "dart.exe".
class StandaloneDartRuntimeConfiguration extends DartVmRuntimeConfiguration {
  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    String script = artifact.filename;
    String type = artifact.mimeType;
    if (script != null && type != 'application/dart') {
      throw "Dart VM cannot run files of type '$type'.";
    }
    var binDir = suite.buildDir;
    return <Command>[
        commandBuilder.getProcessCommand(
            "fletch",
            "$binDir/fletch",
            arguments),
        commandBuilder.getProcessCommand(
            "fletch",
            "$binDir/fletch",
            ["-Xunfold-program"]..addAll(arguments))];
  }
}

class FletchcRuntimeConfiguration extends DartVmRuntimeConfiguration {
  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    String script = artifact.filename;
    String type = artifact.mimeType;
    if (script != null && type != 'application/dart') {
      throw "Dart VM cannot run files of type '$type'.";
    }
    var binDir = suite.buildDir;
    var args = ["-p", "package", "pkg/fletchc/lib/fletchc.dart"];
    args.addAll(arguments);
    return <Command>[commandBuilder.getVmCommand(
          suite.dartVmBinaryFileName, args, environmentOverrides)];
  }
}

/// Temporary runtime configuration for browser runtimes that haven't been
/// migrated yet.
// TODO(ahe): Remove this class.
class DummyRuntimeConfiguration extends DartVmRuntimeConfiguration {
  List<Command> computeRuntimeCommands(
      TestSuite suite,
      CommandBuilder commandBuilder,
      CommandArtifact artifact,
      List<String> arguments,
      Map<String, String> environmentOverrides) {
    throw "Unimplemented runtime '$runtimeType'";
  }
}

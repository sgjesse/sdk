// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dartino_compiler.test.feature_test;

import 'dart:io' hide
    exitCode,
    stderr,
    stdin,
    stdout;

import 'dart:io' as io;

import 'dart:async' show
    Completer,
    Future,
    Stream,
    StreamController,
    StreamIterator;

import 'dart:convert' show
    LineSplitter,
    UTF8,
    Utf8Decoder;

import 'package:expect/expect.dart' show
    Expect;

import 'package:dartino_compiler/incremental/scope_information_visitor.dart'
    show ScopeInformationVisitor;

import 'compiler_test_case.dart' show
    CompilerTestCase;

import 'package:compiler/src/elements/elements.dart' show
    AbstractFieldElement,
    Element,
    FieldElement,
    FunctionElement,
    LibraryElement;

import 'package:compiler/src/compiler.dart' show
    Compiler;

import 'package:compiler/src/source_file_provider.dart' show
    FormattingDiagnosticHandler,
    SourceFileProvider;

import 'package:compiler/src/io/source_file.dart' show
    StringSourceFile;

import 'package:dartino_compiler/incremental/dartino_compiler_incremental.dart'
    show IncrementalCompilationFailed,
    IncrementalCompiler,
    IncrementalMode;

import 'package:dartino_compiler/vm_commands.dart' show
    VmCommand,
    CommitChanges,
    CommitChangesResult,
    HandShakeResult,
    MapId;

import 'package:dartino_compiler/dartino_compiler.dart' show
    DartinoCompiler;

import 'package:dartino_compiler/src/dartino_compiler_implementation.dart' show
    OutputProvider;

import 'package:dartino_compiler/src/guess_configuration.dart' show
    dartinoVersion,
    guessDartinoVm;

import 'package:dartino_compiler/dartino_system.dart';

import 'package:dartino_compiler/vm_commands.dart' as commands_lib;

import 'package:dartino_compiler/vm_session.dart' show
    Session;

import 'package:dartino_compiler/src/dartino_backend.dart' show
    DartinoBackend;

import 'package:dartino_compiler/dartino_vm.dart' show
    DartinoVm;

import 'package:dartino_compiler/debug_state.dart' as debug show
    BackTraceFrame,
    BackTrace;

import 'program_result.dart';

import 'package:dartino_compiler/src/hub/exit_codes.dart' show
    DART_VM_EXITCODE_COMPILE_TIME_ERROR;

const String PACKAGE_SCHEME = 'org.dartlang.dartino.packages';

const String CUSTOM_SCHEME = 'org.dartlang.dartino.test-case';

final Uri customUriBase = new Uri(scheme: CUSTOM_SCHEME, path: '/');

typedef Future NoArgFuture();

compileAndRun(
    String testName,
    EncodedResult encodedResult,
    {IncrementalMode incrementalMode}) async {
  print("Test '$testName'");
  IncrementalTestHelper helper = new IncrementalTestHelper(incrementalMode);
  TestSession session =
      await TestSession.spawnVm(helper.compiler, testName: testName);

  bool hasCompileTimeError = false;

  await new Future(() async {

    int version = 0;

    for (ProgramResult program in encodedResult.decode()) {
      bool isFirstProgram = version == 0;
      version++;

      hasCompileTimeError = program.hasCompileTimeError;

      print("Program version $version #$testName:");
      print(numberedLines(program.code));

      DartinoDelta dartinoDelta;
      if (isFirstProgram) {
        // The first program is compiled "fully".
        dartinoDelta = await helper.fullCompile(program);
      } else {
        // An update to the first program, all updates are compiled as
        // incremental updates to the first program.
        dartinoDelta = await helper.incrementalCompile(program, version);
      }

      DartinoBackend backend = helper.compiler.compiler.context.backend;

      if (!isFirstProgram ||
          const bool.fromEnvironment("feature_test.print_initial_commands")) {
        for (VmCommand command in dartinoDelta.commands) {
          print(command);
        }
      }

      if (isFirstProgram) {
        // Perform handshake with VM.
        HandShakeResult handShakeResult =
            await session.handShake(dartinoVersion);
        Expect.isTrue(handShakeResult.success, "Dartino VM version mismatch");
      }

      CommitChangesResult result = await session.applyDelta(dartinoDelta);

      if (!result.successful) {
        print("The CommitChanges() command was not successful: "
              "${result.message}");
      }

      Expect.equals(result.successful, !program.commitChangesShouldFail,
                    result.message);

      if (isFirstProgram) {
        // Turn on debugging.
        await session.enableDebugger();
        // Spawn the process to run.
        await session.spawnProcess([]);
        // Allow operations on internal frames.
        await session.toggleInternal();
      }

      if (result.successful) {
        // Set breakpoint in main in case main was replaced.
        var breakpoints =
            await session.setBreakpoint(methodName: "main", bytecodeIndex: 0);
        for (var breakpoint in breakpoints) {
          print("Added breakpoint: $breakpoint");
        }
        if (!helper.compiler.compiler.mainFunction.isMalformed) {
          // If there's a syntax error in main, we cannot find it to set a
          // breakpoint.
          // TODO(ahe): Consider if this is a problem?
          Expect.equals(1, breakpoints.length);
        }
        if (isFirstProgram) {
          // Run the program to hit the breakpoint in main.
          await session.debugRun();
        } else {
          // Restart the current frame to rerun main.
          await session.restart();
        }
        if (session.running) {
          // Step out of main to finish execution of main.
          await session.stepOut();
        }

        // Select the stack frame of callMain.
        debug.BackTrace trace = await session.backTrace();
        FunctionElement callMainElement =
            backend.dartinoSystemLibrary.findLocal("callMain");
        DartinoFunction callMain =
            helper.system.lookupFunctionByElement(callMainElement);
        debug.BackTraceFrame mainFrame =
            trace.frames.firstWhere(
                (debug.BackTraceFrame frame) => frame.function == callMain);
        int frame = trace.frames.indexOf(mainFrame);
        Expect.notEquals(1, frame);
        session.selectFrame(frame);
        print(trace.format());

        List<String> actualMessages = session.stdoutSink.takeLines();

        List<String> messages = new List<String>.from(program.messages);
        if (program.hasCompileTimeError) {
          print("Compile-time error expected");
          // TODO(ahe): The compile-time error message shouldn't be printed by
          // the Dartino VM.

          // Find the compile-time error message in the actual output, and
          // remove all lines after it.
          int compileTimeErrorIndex = -1;
          for (int i = 0; i < actualMessages.length; i++) {
            if (actualMessages[i].startsWith("Compile error:")) {
              compileTimeErrorIndex = i;
              break;
            }
          }
          Expect.isTrue(compileTimeErrorIndex != -1);
          actualMessages.removeRange(compileTimeErrorIndex,
              actualMessages.length);
        }

        Expect.listEquals(messages, actualMessages,
            "Expected $messages, got $actualMessages");

        // TODO(ahe): Enable SerializeScopeTestCase for multiple parts.
        if (!isFirstProgram && program.code is String) {
          await new SerializeScopeTestCase(
              program.code, helper.compiler.mainApp,
              helper.compiler.compiler).run();
        }
      }
    }

    // If everything went fine, we will try finishing the execution and do a
    // graceful shutdown.
    if (session.running) {
      // The session is still alive. Run to completion.
      var continueCommand = const commands_lib.ProcessContinue();
      print(continueCommand);

      // Wait for process termination.
      VmCommand response = await session.runCommand(continueCommand);
      if (response is! commands_lib.ProcessTerminated) {
        // TODO(ahe): It's probably an instance of
        // commands_lib.UncaughtException, and if so, we should try to print
        // the stack trace.
        throw new StateError(
            "Expected ProcessTerminated, but got: $response");
      }
    }
    await session.runCommand(const commands_lib.SessionEnd());
    await session.shutdown();
  }).catchError(session.handleError);

  // TODO(ahe/kustermann/ager): We really need to distinguish VM crashes from
  // normal test failures. This information is based on exitCode and we need
  // to propagate the exitCode back to test.dart, so we can have Fail/Crash
  // outcomes of these tests.
  await session.waitForCompletion();

  int actualExitCode = await session.exitCode;
  // TODO(ahe): We should expect exit code 0, and instead be able to detect
  // compile-time errors directly via the session.
  int expectedExitCode = hasCompileTimeError
      ? DART_VM_EXITCODE_COMPILE_TIME_ERROR : 0;
  Expect.equals(
      expectedExitCode, actualExitCode, "Unexpected exit code from dartino VM");
}

class SerializeScopeTestCase extends CompilerTestCase {
  final String source;

  final String scopeInfo;

  final Compiler compiler = null; // TODO(ahe): Provide a compiler.

  SerializeScopeTestCase(
      this.source,
      LibraryElement library,
      Compiler compiler)
      : scopeInfo = computeScopeInfo(compiler, library),
        super(library.canonicalUri);

  Future run() {
    if (true) {
      // TODO(ahe): Remove this. We're temporarily bypassing scope validation.
      return new Future.value(null);
    }
    return loadMainApp().then(checkScopes);
  }

  void checkScopes(LibraryElement library) {
    var compiler = null;
    Expect.stringEquals(computeScopeInfo(compiler, library), scopeInfo);
  }

  Future<LibraryElement> loadMainApp() async {
    LibraryElement library =
        await compiler.libraryLoader.loadLibrary(scriptUri);
    if (compiler.mainApp == null) {
      compiler.mainApp = library;
    } else if (compiler.mainApp != library) {
      throw "Inconsistent use of compiler (${compiler.mainApp} != $library).";
    }
    return library;
  }

  static String computeScopeInfo(Compiler compiler, LibraryElement library) {
    ScopeInformationVisitor visitor =
        new ScopeInformationVisitor(compiler, library, 0);

    visitor.ignoreImports = true;
    visitor.sortMembers = true;
    visitor.indented.write('[\n');
    visitor.indentationLevel++;
    visitor.indented;
    library.accept(visitor, null);
    library.forEachLocalMember((Element member) {
      if (member.isClass) {
        visitor.buffer.write(',\n');
        visitor.indented;
        member.accept(visitor, null);
      }
    });
    visitor.buffer.write('\n');
    visitor.indentationLevel--;
    visitor.indented.write(']');
    return '${visitor.buffer}';
  }
}

void logger(x) {
  print(x);
}

String numberedLines(code) {
  if (code is! Map) {
    code = {'main.dart': code};
  }
  StringBuffer result = new StringBuffer();
  code.forEach((String fileName, String code) {
    result.writeln("==> $fileName <==");
    int lineNumber = 1;
    for (String text in splitLines(code)) {
      result.write("$lineNumber: $text");
      lineNumber++;
    }
  });
  return '$result';
}

List<String> splitLines(String text) {
  return text.split(new RegExp('^', multiLine: true));
}

class TestSession extends Session {
  final Process process;
  final StreamIterator stdoutIterator;
  final Stream<String> stderr;

  final List<Future> futures;

  final Future<int> exitCode;

  bool isWaitingForCompletion = false;

  var lastError;
  var lastStackTrace;

  TestSession(
      Socket vmSocket,
      IncrementalCompiler compiler,
      this.process,
      this.stdoutIterator,
      this.stderr,
      this.futures,
      this.exitCode)
      : super(vmSocket, compiler, new BytesSink(), null);

  // Refines type of [stdoutSink].
  BytesSink get stdoutSink => super.stdoutSink;

  void writeStdout(String s) {
    // Unfortunately, print will always add a newline, and the alternative is
    // to use stdout.write. However, to make it easier to debug problems in
    // this and other dartino_tests, everything that is printed to stdout ends
    // up on the console of test.dart. This is good enough for testing, but DO
    // NOT COPY TO PRODUCTION CODE.
    print(s);
  }

  void writeStdoutLine(String s) {
    print(s);
  }

  /// Add [future] to this session.  All futures that can fail after calling
  /// [waitForCompletion] must be added to the session.
  void recordFuture(Future future) {
    future = future.catchError((error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      throw error;
    });
    futures.add(convertErrorToString(future));
  }

  void addError(error, StackTrace stackTrace) {
    recordFuture(new Future.error(error, stackTrace));
  }

  /// Waits for the VM to shutdown and any futures added with [add] to
  /// complete, and report all errors that occurred.
  Future waitForCompletion() async {
    if (isWaitingForCompletion) {
      throw "waitForCompletion called more than once.";
    }
    isWaitingForCompletion = true;
    // [stderr] and [iterator] (stdout) must have active listeners before
    // waiting for [futures] below to avoid a deadlock.
    Future<List<String>> stderrFuture = stderr.toList();
    Future<List<String>> stdoutFuture = (() async {
      List<String> result = <String>[];
      while (await stdoutIterator.moveNext()) {
        result.add(stdoutIterator.current);
      }
      return result;
    })();

    StringBuffer sb = new StringBuffer();
    int problemCount = 0;
    for (var error in await Future.wait(futures)) {
      if (error != null) {
        sb.writeln("Problem #${++problemCount}:");
        sb.writeln(error);
        sb.writeln("");
      }
    }
    await stdoutFuture;
    List<String> stdoutLines = stdoutSink.takeLines();
    List<String> stderrLines = await stderrFuture;
    if (stdoutLines.isNotEmpty) {
      sb.writeln("Problem #${++problemCount}:");
      sb.writeln("Unexpected stdout from dartino-vm:");
      for (String line in stdoutLines) {
        sb.writeln(line);
      }
      sb.writeln("");
    }
    if (stderrLines.isNotEmpty) {
      sb.writeln("Problem #${++problemCount}:");
      sb.writeln("Unexpected stderr from dartino-vm:");
      for (String line in stderrLines) {
        sb.writeln(line);
      }
      sb.writeln("");
    }
    if (problemCount == 1 && lastError != null) {
      return new Future.error(lastError, lastStackTrace);
    }
    if (problemCount > 0) {
      throw new StateError('Test has $problemCount problem(s). Details:\n$sb');
    }
  }

  static Future<String> convertErrorToString(Future future) {
    return future.then((_) => null).catchError((error, stackTrace) {
      return "$error\n$stackTrace";
    });
  }

  static Future<TestSession> spawnVm(
      IncrementalCompiler compiler,
      {String testName}) async {
    String vmPath = guessDartinoVm(null).toFilePath();

    List<Future> futures = <Future>[];
    void recordFuture(String name, Future future) {
      if (future != null) {
        futures.add(convertErrorToString(future));
      }
    }

    List<String> vmOptions = <String>[
        '-Xvalidate-heaps',
    ];

    print("Running '$vmPath ${vmOptions.join(" ")}'");
    var environment = getProcessEnvironment(testName);
    DartinoVm dartinoVm = await DartinoVm.start(
        vmPath, arguments: vmOptions, environment: environment);

    // Unlike [dartinovm.stdoutLines] and [dartinovm.stderrLines], their
    // corresponding controller cannot produce an error.
    StreamController<String> stdoutController = new StreamController<String>();
    StreamController<String> stderrController = new StreamController<String>();
    recordFuture("stdout", dartinoVm.stdoutLines.listen((String line) {
      print('dartino_vm_stdout: $line');
      stdoutController.add(line);
    }).asFuture().whenComplete(stdoutController.close));
    recordFuture("stderr", dartinoVm.stderrLines.listen((String line) {
      print('dartino_vm_stderr: $line');
      stderrController.add(line);
    }).asFuture().whenComplete(stderrController.close));

    Completer<int> exitCodeCompleter = new Completer<int>();

    // TODO(ahe): If the VM crashes on startup, this will never complete. This
    // makes this program hang forever. But the exitCode completer might
    // actually be ready to give us a crashed exit code. Exiting early with a
    // failure in case exitCode is ready before server.first or having a
    // timeout on server.first would be possible solutions.
    var vmSocket = await dartinoVm.connect();
    recordFuture("vmSocket", vmSocket.done);

    TestSession session = new TestSession(
        vmSocket, compiler, dartinoVm.process,
        new StreamIterator(stdoutController.stream),
        stderrController.stream,
        futures, exitCodeCompleter.future);

    recordFuture("exitCode", dartinoVm.exitCode.then((int exitCode) {
      print("VM exited with exit code: $exitCode.");
      exitCodeCompleter.complete(exitCode);
    }));

    return session;
  }

  static Map<String, String> getProcessEnvironment(String testName) {
    if (testName == null) return null;

    var environment = new Map.from(Platform.environment);
    environment['FEATURE_TEST_TESTNAME'] = testName;
    return environment;
  }

  Future handleError(error, StackTrace stackTrace) {
    addError(error, stackTrace);

    // We either failed before we got to start a process or there was an
    // uncaught exception in the program. If there was an uncaught exception
    // the VM is intentionally hanging to give the debugger a chance to inspect
    // the state at the point of the throw. Therefore, we explicitly have to
    // kill the VM process. Notice, it is important that we kill the VM before
    // we close the socket to it. Otherwise, the VM may write a message on
    // stderr claiming that the compiler died (due to the socket getting
    // closed).
    process.kill();

    // After the process has been killed, we need to close the socket and
    // discard any commands that may have arrived.
    recordFuture(process.exitCode.then((_) => kill()));

    return waitForCompletion();
  }
}

class BytesSink implements Sink<List<int>> {
  final BytesBuilder builder = new BytesBuilder();

  void add(List<int> data) => builder.add(data);

  void close() {
  }

  List<String> takeLines() {
    return new LineSplitter().convert(UTF8.decode(builder.takeBytes()));
  }
}

class IncrementalTestHelper {
  final Uri packageConfig;

  final IoInputProvider inputProvider;

  final IncrementalCompiler compiler;

  DartinoSystem system;

  IncrementalTestHelper.internal(
      this.packageConfig,
      this.inputProvider,
      this.compiler);

  factory IncrementalTestHelper(IncrementalMode incrementalMode) {
    Uri packageConfig = Uri.base.resolve('.packages');
    IoInputProvider inputProvider = new IoInputProvider(packageConfig);
    FormattingDiagnosticHandler diagnosticHandler =
        new FormattingDiagnosticHandler(inputProvider);
    IncrementalCompiler compiler = new IncrementalCompiler(
        packageConfig: packageConfig,
        inputProvider: inputProvider,
        diagnosticHandler: diagnosticHandler,
        outputProvider: new OutputProvider(),
        support: incrementalMode,
        platform: "dartino_mobile.platform");
    return new IncrementalTestHelper.internal(
        packageConfig,
        inputProvider,
        compiler);
  }

  Future<DartinoDelta> fullCompile(ProgramResult program) async {
    Map<String, String> code = computeCode(program);
    inputProvider.sources.clear();
    code.forEach((String name, String code) {
      inputProvider.sources[customUriBase.resolve(name)] = code;
    });

    await compiler.compile(customUriBase.resolve('main.dart'), customUriBase);
    DartinoDelta delta = compiler.compiler.context.backend.computeDelta();
    system = delta.system;
    return delta;
  }

  Future<DartinoDelta> incrementalCompile(
      ProgramResult program,
      int version) async {
    Map<String, String> code = computeCode(program);
    Map<Uri, Uri> uriMap = <Uri, Uri>{};
    for (String name in code.keys) {
      Uri uri = customUriBase.resolve('$name?v$version');
      inputProvider.cachedSources[uri] = new Future.value(code[name]);
      uriMap[customUriBase.resolve(name)] = uri;
    }
    DartinoDelta delta = await compiler.compileUpdates(
        system, uriMap, logVerbose: logger, logTime: logger);
    system = delta.system;
    return delta;
  }

  Map<String, String> computeCode(ProgramResult program) {
    return program.code is String
        ? <String,String>{ 'main.dart': program.code }
        : program.code;
  }
}

/// An input provider which provides input via the class [File].  Includes
/// in-memory compilation units [sources] which are returned when a matching
/// key requested.
class IoInputProvider extends SourceFileProvider {
  final Map<Uri, String> sources = <Uri, String>{};

  final Uri packageConfig;

  final Map<Uri, Future> cachedSources = new Map<Uri, Future>();

  static final Map<Uri, String> cachedFiles = new Map<Uri, String>();

  IoInputProvider(this.packageConfig);

  Future readFromUri(Uri uri) {
    return cachedSources.putIfAbsent(uri, () {
      String text;
      String name;
      if (sources.containsKey(uri)) {
        name = '$uri';
        text = sources[uri];
      } else {
        if (uri.scheme == PACKAGE_SCHEME) {
          throw "packages not supported $uri";
        }
        text = readCachedFile(uri);
        name = new File.fromUri(uri).path;
      }
      sourceFiles[uri] = new StringSourceFile(uri, name, text);
      return new Future<String>.value(text);
    });
  }

  Future call(Uri uri) => readStringFromUri(uri);

  Future<String> readStringFromUri(Uri uri) {
    return readFromUri(uri);
  }

  Future<List<int>> readUtf8BytesFromUri(Uri uri) {
    throw "not supported";
  }

  static String readCachedFile(Uri uri) {
    return cachedFiles.putIfAbsent(
        uri, () => new File.fromUri(uri).readAsStringSync());
  }
}

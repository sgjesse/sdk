// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.worker.developer;

import 'dart:async' show
    Future,
    Stream,
    StreamController,
    Timer;

import 'dart:convert' show
    JSON,
    JsonEncoder,
    UTF8;

import 'dart:io' show
    Directory,
    File,
    FileSystemEntity,
    InternetAddress,
    Process,
    Socket,
    SocketException;

import 'package:sdk_library_metadata/libraries.dart' show
    Category;

import 'package:fletch_agent/agent_connection.dart' show
    AgentConnection,
    AgentException,
    VmData;

import 'package:fletch_agent/messages.dart' show
    AGENT_DEFAULT_PORT,
    MessageDecodeException;

import 'package:mdns/mdns.dart' show
    MDnsClient,
    ResourceRecord,
    RRType;

import '../../vm_commands.dart' show
    VmCommandCode,
    ConnectionError,
    Debugging,
    HandShakeResult,
    ProcessBacktrace,
    ProcessBacktraceRequest,
    ProcessRun,
    ProcessSpawnForMain,
    SessionEnd,
    WriteSnapshotResult;

import '../../program_info.dart' show
    Configuration,
    ProgramInfo,
    ProgramInfoBinary,
    ProgramInfoJson,
    buildProgramInfo;

import '../hub/session_manager.dart' show
    FletchVm,
    SessionState,
    Sessions;

import '../hub/client_commands.dart' show
    ClientCommandCode,
    handleSocketErrors;

import '../verbs/infrastructure.dart' show
    ClientCommand,
    CommandSender,
    DiagnosticKind,
    FletchCompiler,
    FletchDelta,
    IncrementalCompiler,
    WorkerConnection,
    IsolatePool,
    Session,
    SharedTask,
    StreamIterator,
    throwFatalError;

import '../../incremental/fletchc_incremental.dart' show
    IncrementalCompilationFailed,
    IncrementalMode,
    parseIncrementalMode,
    unparseIncrementalMode;

export '../../incremental/fletchc_incremental.dart' show
    IncrementalMode;

import '../../fletch_compiler.dart' show fletchDeviceType;

import '../hub/exit_codes.dart' as exit_codes;

import '../../fletch_system.dart' show
    FletchFunction,
    FletchSystem;

import '../../bytecodes.dart' show
    Bytecode,
    MethodEnd;

import '../diagnostic.dart' show
    throwInternalError;

import '../guess_configuration.dart' show
    executable,
    fletchVersion,
    guessFletchVm;

import '../device_type.dart' show
    DeviceType,
    parseDeviceType,
    unParseDeviceType;

export '../device_type.dart' show
    DeviceType;

import '../please_report_crash.dart' show
    pleaseReportCrash;

import '../../debug_state.dart' as debug show
    RemoteObject,
    BackTrace;

typedef Future<Null> ClientEventHandler(Session session);

Uri configFileUri;

Future<Socket> connect(
    String host,
    int port,
    DiagnosticKind kind,
    String socketDescription,
    SessionState state) async {
  // We are using .catchError rather than try/catch because we have seen
  // incorrect stack traces using the latter.
  Socket socket = await Socket.connect(host, port).catchError(
      (SocketException error) {
        String message = error.message;
        if (error.osError != null) {
          message = error.osError.message;
        }
        throwFatalError(kind, address: '$host:$port', message: message);
      }, test: (e) => e is SocketException);
  handleSocketErrors(socket, socketDescription, log: (String info) {
    state.log("Connected to TCP $socketDescription  $info");
  });
  return socket;
}

Future<AgentConnection> connectToAgent(SessionState state) async {
  // TODO(wibling): need to make sure the agent is running.
  assert(state.settings.deviceAddress != null);
  String host = state.settings.deviceAddress.host;
  int agentPort = state.settings.deviceAddress.port;
  Socket socket = await connect(
      host, agentPort, DiagnosticKind.socketAgentConnectError,
      "agentSocket", state);
  return new AgentConnection(socket);
}

/// Return the result of a function in the context of an open [AgentConnection].
///
/// The result is a [Future] of this value.
/// This function handles [AgentException] and [MessageDecodeException].
Future withAgentConnection(
    SessionState state,
    Future f(AgentConnection connection)) async {
  AgentConnection connection = await connectToAgent(state);
  try {
    return await f(connection);
  } on AgentException catch (error) {
    throwFatalError(
        DiagnosticKind.socketAgentReplyError,
        address: '${connection.socket.remoteAddress.host}:'
            '${connection.socket.remotePort}',
        message: error.message);
  } on MessageDecodeException catch (error) {
    throwFatalError(
        DiagnosticKind.socketAgentReplyError,
        address: '${connection.socket.remoteAddress.host}:'
            '${connection.socket.remotePort}',
        message: error.message);
  } finally {
    disconnectFromAgent(connection);
  }
}

void disconnectFromAgent(AgentConnection connection) {
  assert(connection.socket != null);
  connection.socket.close();
}

Future<Null> checkAgentVersion(Uri base, SessionState state) async {
  String deviceFletchVersion = await withAgentConnection(state,
      (connection) => connection.fletchVersion());
  Uri packageFile = await lookForAgentPackage(base, version: fletchVersion);
  String fixit;
  if (packageFile != null) {
    fixit = "Try running\n"
      "  'fletch x-upgrade agent in session ${state.name}'.";
  } else {
    fixit = "Try downloading a matching SDK and running\n"
      "  'fletch x-upgrade agent in session ${state.name}'\n"
      "from the SDK's root directory.";
  }

  if (fletchVersion != deviceFletchVersion) {
    throwFatalError(DiagnosticKind.agentVersionMismatch,
        userInput: fletchVersion,
        additionalUserInput: deviceFletchVersion,
        fixit: fixit);
  }
}

Future<Null> startAndAttachViaAgent(Uri base, SessionState state) async {
  // TODO(wibling): integrate with the FletchVm class, e.g. have a
  // AgentFletchVm and LocalFletchVm that both share the same interface
  // where the former is interacting with the agent.
  await checkAgentVersion(base, state);
  VmData vmData = await withAgentConnection(state,
      (connection) => connection.startVm());
  state.fletchAgentVmId = vmData.id;
  String host = state.settings.deviceAddress.host;
  await attachToVm(host, vmData.port, state);
  await state.session.disableVMStandardOutput();
}

Future<Null> startAndAttachDirectly(SessionState state, Uri base) async {
  String fletchVmPath = state.compilerHelper.fletchVm.toFilePath();
  state.fletchVm = await FletchVm.start(fletchVmPath, workingDirectory: base);
  await attachToVm(state.fletchVm.host, state.fletchVm.port, state);
  await state.session.disableVMStandardOutput();
}

Future<Null> attachToVm(String host, int port, SessionState state) async {
  Socket socket = await connect(
      host, port, DiagnosticKind.socketVmConnectError, "vmSocket", state);

  Session session = new Session(socket, state.compiler, state.stdoutSink,
      state.stderrSink, null);

  // Perform handshake with VM which validates that VM and compiler
  // have the same versions.
  HandShakeResult handShakeResult = await session.handShake(fletchVersion);
  if (handShakeResult == null) {
    throwFatalError(DiagnosticKind.handShakeFailed, address: '$host:$port');
  }
  if (!handShakeResult.success) {
    throwFatalError(DiagnosticKind.versionMismatch,
                    address: '$host:$port',
                    userInput: fletchVersion,
                    additionalUserInput: handShakeResult.version);
  }

  // Enable debugging to be able to communicate with VM when there
  // are errors.
  await session.runCommand(const Debugging());

  state.session = session;
}

Future<int> compile(
    Uri script,
    SessionState state,
    Uri base,
    {bool analyzeOnly: false,
     bool fatalIncrementalFailures: false}) async {
  IncrementalCompiler compiler = state.compiler;
  if (!compiler.isProductionModeEnabled) {
    state.resetCompiler();
  }
  Uri firstScript = state.script;
  List<FletchDelta> previousResults = state.compilationResults;

  FletchDelta newResult;
  try {
    if (analyzeOnly) {
      state.resetCompiler();
      state.log("Analyzing '$script'");
      return await compiler.analyze(script, base);
    } else if (previousResults.isEmpty) {
      state.script = script;
      await compiler.compile(script, base);
      newResult = compiler.computeInitialDelta();
    } else {
      try {
        state.log("Compiling difference from $firstScript to $script");
        newResult = await compiler.compileUpdates(
            previousResults.last.system, <Uri, Uri>{firstScript: script},
            logTime: state.log, logVerbose: state.log);
      } on IncrementalCompilationFailed catch (error) {
        state.log(error);
        state.resetCompiler();
        if (fatalIncrementalFailures) {
          print(error);
          state.log(
              "Aborting compilation due to --fatal-incremental-failures...");
          return exit_codes.INCREMENTAL_COMPILER_FAILED;
        }
        state.log("Attempting full compile...");
        state.script = script;
        await compiler.compile(script, base);
        newResult = compiler.computeInitialDelta();
      }
    }
  } catch (error, stackTrace) {
    pleaseReportCrash(error, stackTrace);
    return exit_codes.COMPILER_EXITCODE_CRASH;
  }
  state.addCompilationResult(newResult);

  state.log("Compiled '$script' to ${newResult.commands.length} commands");

  return 0;
}

Future<Settings> readSettings(Uri uri) async {
  if (await new File.fromUri(uri).exists()) {
    String jsonLikeData = await new File.fromUri(uri).readAsString();
    return parseSettings(jsonLikeData, uri);
  } else {
    return null;
  }
}

Future<Uri> findFile(Uri cwd, String fileName) async {
  Uri uri = cwd.resolve(fileName);
  while (true) {
    if (await new File.fromUri(uri).exists()) return uri;
    if (uri.pathSegments.length <= 1) return null;
    uri = uri.resolve('../$fileName');
  }
}

Future<Settings> createSettings(
    String sessionName,
    Uri uri,
    Uri cwd,
    Uri configFileUri,
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator) async {
  bool userProvidedSettings = uri != null;
  if (!userProvidedSettings) {
    // Try to find a $sessionName.fletch-settings file starting from the current
    // working directory and walking up its parent directories.
    uri = await findFile(cwd, '$sessionName.fletch-settings');

    // If no $sessionName.fletch-settings file is found, try to find the
    // settings template file (in the SDK or git repo) by looking for a
    // .fletch-settings file starting from the fletch executable's directory
    // and walking up its parent directory chain.
    if (uri == null) {
      uri = await findFile(executable, '.fletch-settings');
      if (uri != null) print('Using template settings file $uri');
    }
  }

  Settings settings = new Settings.empty();
  if (uri != null) {
    String jsonLikeData = await new File.fromUri(uri).readAsString();
    settings = parseSettings(jsonLikeData, uri);
  }
  if (userProvidedSettings) return settings;

  // TODO(wibling): get rid of below special handling of the sessions 'remote'
  // and 'local' and come up with a fletch project concept that can contain
  // these settings.
  Uri packagesUri;
  Address address;
  switch (sessionName) {
    case "remote":
      uri = configFileUri.resolve("remote.fletch-settings");
      Settings remoteSettings = await readSettings(uri);
      if (remoteSettings != null) return remoteSettings;
      packagesUri = executable.resolve("fletch-sdk.packages");
      address = await readAddressFromUser(commandSender, commandIterator);
      if (address == null) {
        // Assume user aborted data entry.
        return settings;
      }
      break;

    case "local":
      uri = configFileUri.resolve("local.fletch-settings");
      Settings localSettings = await readSettings(uri);
      if (localSettings != null) return localSettings;
      // TODO(ahe): Use mock packages here.
      packagesUri = executable.resolve("fletch-sdk.packages");
      break;

    default:
      return settings;
  }

  if (!await new File.fromUri(packagesUri).exists()) {
    packagesUri = null;
  }
  settings = settings.copyWith(packages: packagesUri, deviceAddress: address);
  print("Created settings file '$uri'");
  await new File.fromUri(uri).writeAsString(
      "${const JsonEncoder.withIndent('  ').convert(settings)}\n");
  return settings;
}

Future<Address> readAddressFromUser(
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator) async {
  String message = "Please enter IP address of remote device "
      "(press Enter to search for devices):";
  commandSender.sendStdout(message);
  // The list of devices found by running discovery.
  List<InternetAddress> devices = <InternetAddress>[];
  while (await commandIterator.moveNext()) {
    ClientCommand command = commandIterator.current;
    switch (command.code) {
      case ClientCommandCode.Stdin:
        if (command.data.length == 0) {
          // TODO(ahe): It may be safe to return null here, but we need to
          // check how this interacts with the debugger's InputHandler.
          throwInternalError("Unexpected end of input");
        }
        // TODO(ahe): This assumes that the user's input arrives as one
        // message. It is relatively safe to assume this for a normal terminal
        // session because we use canonical input processing (Unix line
        // buffering), but it doesn't work in general. So we should fix that.
        String line = UTF8.decode(command.data).trim();
        if (line.isEmpty && devices.isEmpty) {
          commandSender.sendStdout("\n");
          // [discoverDevices] will print out the list of device with their
          // IP address, hostname, and agent version.
          devices = await discoverDevices(prefixWithNumber: true);
          if (devices.isEmpty) {
            commandSender.sendStdout(
                "Couldn't find Fletch capable devices\n");
            commandSender.sendStdout(message);
          } else {
            if (devices.length == 1) {
              commandSender.sendStdout("\n");
              commandSender.sendStdout("Press Enter to use this device");
            } else {
              commandSender.sendStdout("\n");
              commandSender.sendStdout(
                  "Found ${devices.length} Fletch capable devices\n");
              commandSender.sendStdout(
                  "Please enter the number or the IP address of "
                  "the remote device you would like to use "
                  "(press Enter to use the first device): ");
            }
          }
        } else {
          bool checkedIndex = false;
          if (devices.length > 0) {
            if (line.isEmpty) {
              return new Address(devices[0].address, AGENT_DEFAULT_PORT);
            }
            try {
              checkedIndex = true;
              int index = int.parse(line);
              if (1 <= index  && index <= devices.length) {
                return new Address(devices[index - 1].address,
                                   AGENT_DEFAULT_PORT);
              } else {
                commandSender.sendStdout("Invalid device index $line\n\n");
                commandSender.sendStdout(message);
              }
            } on FormatException {
              // Ignore FormatException and fall through to parse as IP address.
            }
          }
          if (!checkedIndex) {
            return parseAddress(line, defaultPort: AGENT_DEFAULT_PORT);
          }
        }
        break;

      default:
        throwInternalError("Unexpected ${command.code}");
        return null;
    }
  }
  return null;
}

SessionState createSessionState(
    String name,
    Settings settings,
    {Uri libraryRoot,
     Uri fletchVm,
     Uri nativesJson}) {
  if (settings == null) {
    settings = const Settings.empty();
  }
  List<String> compilerOptions = const bool.fromEnvironment("fletchc-verbose")
      ? <String>['--verbose'] : <String>[];
  compilerOptions.addAll(settings.options);
  Uri packageConfig = settings.packages;
  if (packageConfig == null) {
    packageConfig = executable.resolve("fletch-sdk.packages");
  }

  DeviceType deviceType = settings.deviceType ??
      parseDeviceType(fletchDeviceType);

  String platform = (deviceType == DeviceType.embedded)
      ? "fletch_embedded.platform"
      : "fletch_mobile.platform";

  FletchCompiler compilerHelper = new FletchCompiler(
      options: compilerOptions,
      packageConfig: packageConfig,
      environment: settings.constants,
      platform: platform,
      libraryRoot: libraryRoot,
      fletchVm: fletchVm,
      nativesJson: nativesJson);

  return new SessionState(
      name, compilerHelper,
      compilerHelper.newIncrementalCompiler(settings.incrementalMode),
      settings);
}

Future runWithDebugger(
    List<String> commands,
    Session session,
    SessionState state) async {

  // Method used to generate the debugger commands if none are specified.
  Stream<String> inputGenerator() async* {
    yield 't verbose';
    yield 'b main';
    yield 'r';
    while (!session.terminated) {
      yield 's';
    }
  }

  return commands.isEmpty ?
      session.debug(inputGenerator(), Uri.base, state, echo: true) :
      session.debug(
          new Stream<String>.fromIterable(commands), Uri.base, state,
          echo: true);
}

Future<int> run(
    SessionState state,
    {List<String> testDebuggerCommands,
     bool terminateDebugger: true}) async {
  List<FletchDelta> compilationResults = state.compilationResults;
  Session session = state.session;

  for (FletchDelta delta in compilationResults) {
    await session.applyDelta(delta);
  }

  if (testDebuggerCommands != null) {
    await runWithDebugger(testDebuggerCommands, session, state);
    return 0;
  }

  session.silent = true;

  await session.enableDebugger();
  await session.spawnProcess();
  var command = await session.debugRun();

  int exitCode = exit_codes.COMPILER_EXITCODE_CRASH;
  if (command == null) {
    await session.kill();
    await session.shutdown();
    throwInternalError("No command received from Fletch VM");
  }

  Future printException() async {
    if (!session.loaded) {
      print('### process not loaded, cannot print uncaught exception');
      return;
    }
    debug.RemoteObject exception = await session.uncaughtException();
    if (exception != null) {
      print(session.exceptionToString(exception));
    }
  }

  Future printTrace() async {
    if (!session.loaded) {
      print("### process not loaded, cannot print stacktrace and code");
      return;
    }
    debug.BackTrace stackTrace = await session.backTrace();
    if (stackTrace != null) {
      print(stackTrace.format());
      print(stackTrace.list(state));
    }
  }

  try {
    switch (command.code) {
      case VmCommandCode.UncaughtException:
        state.log("Uncaught error");
        exitCode = exit_codes.DART_VM_EXITCODE_UNCAUGHT_EXCEPTION;
        await printException();
        await printTrace();
        // TODO(ahe): Need to continue to unwind stack.
        break;
      case VmCommandCode.ProcessCompileTimeError:
        state.log("Compile-time error");
        exitCode = exit_codes.DART_VM_EXITCODE_COMPILE_TIME_ERROR;
        await printTrace();
        // TODO(ahe): Continue to unwind stack?
        break;

      case VmCommandCode.ProcessTerminated:
        exitCode = 0;
        break;

      case VmCommandCode.ConnectionError:
        state.log("Error on connection to Fletch VM: ${command.error}");
        exitCode = exit_codes.COMPILER_EXITCODE_CONNECTION_ERROR;
        break;

      default:
        throwInternalError("Unexpected result from Fletch VM: '$command'");
        break;
    }
  } finally {
    if (terminateDebugger) {
      await state.terminateSession();
    } else {
      // If the session terminated due to a ConnectionError or the program
      // finished don't reuse the state's session.
      if (session.terminated) {
        state.session = null;
      }
      session.silent = false;
    }
  };

  return exitCode;
}

Future<int> export(SessionState state,
                   Uri snapshot,
                   {bool binaryProgramInfo: false}) async {
  List<FletchDelta> compilationResults = state.compilationResults;
  Session session = state.session;
  state.session = null;

  for (FletchDelta delta in compilationResults) {
    await session.applyDelta(delta);
  }

  var result = await session.writeSnapshot(snapshot.toFilePath());
  if (result is WriteSnapshotResult) {
    WriteSnapshotResult snapshotResult = result;

    await session.shutdown();

    ProgramInfo info =
        buildProgramInfo(compilationResults.last.system, snapshotResult);

    File jsonFile = new File('${snapshot.toFilePath()}.info.json');
    await jsonFile.writeAsString(ProgramInfoJson.encode(info));

    if (binaryProgramInfo) {
      File binFile = new File('${snapshot.toFilePath()}.info.bin');
      await binFile.writeAsBytes(ProgramInfoBinary.encode(info));
    }

    return 0;
  } else {
    assert(result is ConnectionError);
    print("There was a connection error while writing the snapshot.");
    return exit_codes.COMPILER_EXITCODE_CONNECTION_ERROR;
  }
}

Future<int> compileAndAttachToVmThen(
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator,
    SessionState state,
    Uri script,
    Uri base,
    bool waitForVmExit,
    Future<int> action(),
    {ClientEventHandler eventHandler}) async {
  bool startedVmDirectly = false;
  List<FletchDelta> compilationResults = state.compilationResults;
  if (compilationResults.isEmpty || script != null) {
    if (script == null) {
      throwFatalError(DiagnosticKind.noFileTarget);
    }
    int exitCode = await compile(script, state, base);
    if (exitCode != 0) return exitCode;
    compilationResults = state.compilationResults;
    assert(compilationResults != null);
  }

  Session session = state.session;
  if (session != null && session.loaded) {
    // We cannot reuse a session that has already been loaded. Loading
    // currently implies that some of the code has been run.
    if (state.explicitAttach) {
      // If the user explicitly called 'fletch attach' we cannot
      // create a new VM session since we don't know if the vm is
      // running locally or remotely and if running remotely there
      // is no guarantee there is an agent to start a new vm.
      //
      // The UserSession is invalid in its current state as the
      // vm session (aka. session in the code here) has already
      // been loaded and run some code.
      throwFatalError(DiagnosticKind.sessionInvalidState,
          sessionName: state.name);
    }
    state.log('Cannot reuse existing VM session, creating new.');
    await state.terminateSession();
    session = null;
  }
  if (session == null) {
    if (state.settings.deviceAddress != null) {
      await startAndAttachViaAgent(base, state);
      // TODO(wibling): read stdout from agent.
    } else {
      startedVmDirectly = true;
      await startAndAttachDirectly(state, base);
      state.fletchVm.stdoutLines.listen((String line) {
          commandSender.sendStdout("$line\n");
        });
      state.fletchVm.stderrLines.listen((String line) {
          commandSender.sendStderr("$line\n");
        });
    }
    session = state.session;
    assert(session != null);
  }

  eventHandler ??= defaultClientEventHandler(state, commandIterator);
  setupClientInOut(state, commandSender, eventHandler);

  int exitCode = exit_codes.COMPILER_EXITCODE_CRASH;
  try {
    exitCode = await action();
  } catch (error, trace) {
    print(error);
    if (trace != null) {
      print(trace);
    }
  } finally {
    if (waitForVmExit && startedVmDirectly) {
      exitCode = await state.fletchVm.exitCode;
    }
    state.detachCommandSender();
  }
  return exitCode;
}

void setupClientInOut(
    SessionState state,
    CommandSender commandSender,
    ClientEventHandler eventHandler) {
  // Forward output going into the state's outputSink using the passed in
  // commandSender. This typically forwards output to the hub (main isolate)
  // which forwards it on to stdout of the Fletch C++ client.
  state.attachCommandSender(commandSender);

  // Start event handling for input passed from the Fletch C++ client.
  eventHandler(state.session);

  // Let the hub (main isolate) know that event handling has been started.
  commandSender.sendEventLoopStarted();
}

/// Return a default client event handler bound to the current session's
/// commandIterator and state.
/// This handler only takes care of signals coming from the client.
ClientEventHandler defaultClientEventHandler(
    SessionState state,
    StreamIterator<ClientCommand> commandIterator) {
  return (Session session) async {
    while (await commandIterator.moveNext()) {
      ClientCommand command = commandIterator.current;
      switch (command.code) {
        case ClientCommandCode.Signal:
          int signalNumber = command.data;
          handleSignal(state, signalNumber);
          break;
        default:
          state.log("Unhandled command from client: $command");
      }
    }
  };
}

void handleSignal(SessionState state, int signalNumber) {
  state.log("Received signal $signalNumber");
  if (!state.hasRemoteVm && state.fletchVm == null) {
    // This can happen if a user has attached to a vm using the "attach" verb
    // in which case we don't forward the signal to the vm.
    // TODO(wibling): Determine how to interpret the signal for the persistent
    // process.
    state.log('Signal $signalNumber ignored. VM was manually attached.');
    print('Signal $signalNumber ignored. VM was manually attached.');
    return;
  }
  if (state.hasRemoteVm) {
    signalAgentVm(state, signalNumber);
  } else {
    assert(state.fletchVm.process != null);
    int vmPid = state.fletchVm.process.pid;
    Process.runSync("kill", ["-$signalNumber", "$vmPid"]);
  }
}

Future signalAgentVm(SessionState state, int signalNumber) async {
  await withAgentConnection(state, (connection) {
    return connection.signalVm(state.fletchAgentVmId, signalNumber);
  });
}

String extractVersion(Uri uri) {
  List<String> nameParts = uri.pathSegments.last.split('_');
  if (nameParts.length != 3 || nameParts[0] != 'fletch-agent') {
    throwFatalError(DiagnosticKind.upgradeInvalidPackageName);
  }
  String version = nameParts[1];
  // create_debian_packages.py adds a '-1' after the hash in the package name.
  if (version.endsWith('-1')) {
    version = version.substring(0, version.length - 2);
  }
  return version;
}

/// Try to locate an Fletch agent package file assuming the normal SDK layout
/// with SDK base directory [base].
///
/// If the parameter [version] is passed, the Uri is only returned, if
/// the version matches.
Future<Uri> lookForAgentPackage(Uri base, {String version}) async {
  String platform = "raspberry-pi2";
  Uri platformUri = base.resolve("platforms/$platform");
  Directory platformDir = new Directory.fromUri(platformUri);

  // Try to locate the agent package in the SDK for the selected platform.
  Uri sdkAgentPackage;
  if (await platformDir.exists()) {
    for (FileSystemEntity entry in platformDir.listSync()) {
      Uri uri = entry.uri;
      String name = uri.pathSegments.last;
      if (name.startsWith('fletch-agent') &&
          name.endsWith('.deb') &&
          (version == null || extractVersion(uri) == version)) {
        return uri;
      }
    }
  }
  return null;
}

Future<Uri> readPackagePathFromUser(
    Uri base,
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator) async {
  Uri sdkAgentPackage = await lookForAgentPackage(base);
  if (sdkAgentPackage != null) {
    String path = sdkAgentPackage.toFilePath();
    commandSender.sendStdout("Found SDK package: $path\n");
    commandSender.sendStdout("Press Enter to use this package to upgrade "
        "or enter the path to another package file:\n");
  } else {
    commandSender.sendStdout("Please enter the path to the package file "
        "you want to use:\n");
  }

  while (await commandIterator.moveNext()) {
    ClientCommand command = commandIterator.current;
    switch (command.code) {
      case ClientCommandCode.Stdin:
        if (command.data.length == 0) {
          throwInternalError("Unexpected end of input");
        }
        // TODO(karlklose): This assumes that the user's input arrives as one
        // message. It is relatively safe to assume this for a normal terminal
        // session because we use canonical input processing (Unix line
        // buffering), but it doesn't work in general. So we should fix that.
        String line = UTF8.decode(command.data).trim();
        if (line.isEmpty) {
          return sdkAgentPackage;
        } else {
          return base.resolve(line);
        }
        break;

      default:
        throwInternalError("Unexpected ${command.code}");
        return null;
    }
  }
  return null;
}

class Version {
  final List<int> version;
  final String label;

  Version(this.version, this.label) {
    if (version.length != 3) {
      throw new ArgumentError("version must have three parts");
    }
  }

  /// Returns `true` if this version's digits are greater in lexicographical
  /// order.
  ///
  /// We use a function instead of [operator >] because [label] is not used
  /// in the comparison, but it is used in [operator ==].
  bool isGreaterThan(Version other) {
    for (int part = 0; part < 3; ++part) {
      if (version[part] < other.version[part]) {
        return false;
      }
      if (version[part] > other.version[part]) {
        return true;
      }
    }
    return false;
  }

  bool operator ==(other) {
    return other is Version &&
        version[0] == other.version[0] &&
        version[1] == other.version[1] &&
        version[2] == other.version[2] &&
        label == other.label;
  }

  int get hashCode {
    return 3 * version[0] +
        5 * version[1] +
        7 * version[2] +
        13 * label.hashCode;
  }

  String toString() {
    String labelPart = label == null ? '' : '-$label';
    return '${version[0]}.${version[1]}.${version[2]}$labelPart';
  }
}

Version parseVersion(String text) {
  List<String> labelParts = text.split('-');
  if (labelParts.length > 2) {
    throw new ArgumentError('Not a version: $text.');
  }
  List<String> digitParts = labelParts[0].split('.');
  if (digitParts.length != 3) {
    throw new ArgumentError('Not a version: $text.');
  }
  List<int> digits = digitParts.map(int.parse).toList();
  return new Version(digits, labelParts.length == 2 ? labelParts[1] : null);
}

Future<int> upgradeAgent(
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator,
    SessionState state,
    Uri base,
    Uri packageUri) async {
  if (state.settings.deviceAddress == null) {
    throwFatalError(DiagnosticKind.noAgentFound);
  }

  while (packageUri == null) {
    packageUri =
      await readPackagePathFromUser(base, commandSender, commandIterator);
  }

  if (!await new File.fromUri(packageUri).exists()) {
    print('File not found: $packageUri');
    return 1;
  }

  Version version = parseVersion(extractVersion(packageUri));

  Version existingVersion = parseVersion(
      await withAgentConnection(state,
          (connection) => connection.fletchVersion()));

  if (existingVersion == version) {
    print('Target device is already at $version');
    return 0;
  }

  print("Attempting to upgrade device from "
      "$existingVersion to $version");

  if (existingVersion.isGreaterThan(version)) {
    commandSender.sendStdout("The existing version is greater than the "
            "version you want to use to upgrade.\n"
        "Please confirm this operation by typing 'yes' "
        "(press Enter to abort): ");
    Confirm: while (await commandIterator.moveNext()) {
      ClientCommand command = commandIterator.current;
      switch (command.code) {
        case ClientCommandCode.Stdin:
        if (command.data.length == 0) {
          throwInternalError("Unexpected end of input");
        }
        String line = UTF8.decode(command.data).trim();
        if (line.isEmpty) {
          commandSender.sendStdout("Upgrade aborted\n");
          return 0;
        } else if (line.trim().toLowerCase() == "yes") {
          break Confirm;
        }
        break;

      default:
        throwInternalError("Unexpected ${command.code}");
        return null;
      }
    }
  }

  List<int> data = await new File.fromUri(packageUri).readAsBytes();
  print("Sending package to fletch agent");
  await withAgentConnection(state,
      (connection) => connection.upgradeAgent(version.toString(), data));
  print("Transfer complete, waiting for the Fletch agent to restart. "
      "This can take a few seconds.");

  Version newVersion;
  int remainingTries = 20;
  // Wait for the agent to come back online to verify the version.
  while (--remainingTries > 0) {
    await new Future.delayed(const Duration(seconds: 1));
    try {
      // TODO(karlklose): this functionality should be shared with connect.
      Socket socket = await Socket.connect(
          state.settings.deviceAddress.host,
          state.settings.deviceAddress.port);
      handleSocketErrors(socket, "pollAgentVersion", log: (String info) {
        state.log("Connected to TCP waitForAgentUpgrade $info");
      });
      AgentConnection connection = new AgentConnection(socket);
      newVersion = parseVersion(await connection.fletchVersion());
      disconnectFromAgent(connection);
      if (newVersion != existingVersion) {
        break;
      }
    } on SocketException catch (e) {
      // Ignore this error and keep waiting.
    }
  }

  if (newVersion == existingVersion) {
    print("Failed to upgrade: the device is still at the old version.");
    print("Try running x-upgrade again. "
        "If the upgrade fails again, try rebooting the device.");
    return 1;
  } else if (newVersion == null) {
    print("Could not connect to Fletch agent after upgrade.");
    print("Try running 'fletch show devices' later to see if it has been"
        " restarted. If the device does not show up, try rebooting it.");
    return 1;
  } else {
    print("Upgrade successful.");
  }

  return 0;
}

Future<WorkerConnection> allocateWorker(IsolatePool pool) async {
  WorkerConnection workerConnection =
      new WorkerConnection(await pool.getIsolate(exitOnError: false));
  await workerConnection.beginSession();
  return workerConnection;
}

SharedTask combineTasks(SharedTask task1, SharedTask task2) {
  if (task1 == null) return task2;
  if (task2 == null) return task1;
  return new CombinedTask(task1, task2);
}

class CombinedTask extends SharedTask {
  // Keep this class simple, see note in superclass.

  final SharedTask task1;

  final SharedTask task2;

  const CombinedTask(this.task1, this.task2);

  Future<int> call(
      CommandSender commandSender,
      StreamIterator<ClientCommand> commandIterator) {
    return invokeCombinedTasks(commandSender, commandIterator, task1, task2);
  }
}

Future<int> invokeCombinedTasks(
    CommandSender commandSender,
    StreamIterator<ClientCommand> commandIterator,
    SharedTask task1,
    SharedTask task2) async {
  int result = await task1(commandSender, commandIterator);
  if (result != 0) return result;
  return task2(commandSender, commandIterator);
}

Future<String> getAgentVersion(InternetAddress host, int port) async {
  Socket socket;
  try {
    socket = await Socket.connect(host, port);
    handleSocketErrors(socket, "getAgentVersionSocket");
  } on SocketException catch (e) {
    return 'Error: no agent: $e';
  }
  try {
    AgentConnection connection = new AgentConnection(socket);
    return await connection.fletchVersion();
  } finally {
    socket.close();
  }
}

Future<List<InternetAddress>> discoverDevices(
    {bool prefixWithNumber: false}) async {
  const ipV4AddressLength = 'xxx.xxx.xxx.xxx'.length;
  print("Looking for Fletch capable devices (will search for 5 seconds)...");
  MDnsClient client = new MDnsClient();
  await client.start();
  List<InternetAddress> result = <InternetAddress>[];
  String name = '_fletch_agent._tcp.local';
  await for (ResourceRecord ptr in client.lookup(RRType.PTR, name)) {
    String domain = ptr.domainName;
    await for (ResourceRecord srv in client.lookup(RRType.SRV, domain)) {
      String target = srv.target;
      await for (ResourceRecord a in client.lookup(RRType.A, target)) {
        InternetAddress address = a.address;
        if (!address.isLinkLocal) {
          result.add(address);
          String version = await getAgentVersion(address, AGENT_DEFAULT_PORT);
          String prefix = prefixWithNumber ? "${result.length}: " : "";
          print("${prefix}Device at "
                "${address.address.padRight(ipV4AddressLength + 1)} "
                "$target ($version)");
        }
      }
    }
    // TODO(karlklose): Verify that we got an A/IP4 result for the PTR result.
    // If not, maybe the cache was flushed before access and we need to query
    // for the SRV or A type again.
  }
  client.stop();
  return result;
}

void showSessions() {
  Sessions.names.forEach(print);
}

Future<int> showSessionSettings() async {
  Settings settings = SessionState.current.settings;
  Uri source = settings.source;
  if (source != null) {
    // This should output `source.toFilePath()`, but we do it like this to be
    // consistent with the format of the [Settings.packages] value.
    print('Configured from $source}');
  }
  settings.toJson().forEach((String key, value) {
    print('$key: $value');
  });
  return 0;
}

Address parseAddress(String address, {int defaultPort: 0}) {
  String host;
  int port;
  List<String> parts = address.split(":");
  if (parts.length == 1) {
    host = InternetAddress.LOOPBACK_IP_V4.address;
    port = int.parse(
        parts[0],
        onError: (String source) {
          host = source;
          return defaultPort;
        });
  } else {
    host = parts[0];
    port = int.parse(
        parts[1],
        onError: (String source) {
          throwFatalError(
              DiagnosticKind.expectedAPortNumber, userInput: source);
        });
  }
  return new Address(host, port);
}

class Address {
  final String host;
  final int port;

  const Address(this.host, this.port);

  String toString() => "Address($host, $port)";

  String toJson() => "$host:$port";

  bool operator ==(other) {
    if (other is! Address) return false;
    return other.host == host && other.port == port;
  }

  int get hashCode => host.hashCode ^ port.hashCode;
}

/// See ../verbs/documentation.dart for a definition of this format.
Settings parseSettings(String jsonLikeData, Uri settingsUri) {
  String json = jsonLikeData.split("\n")
      .where((String line) => !line.trim().startsWith("//")).join("\n");
  var userSettings;
  try {
    userSettings = JSON.decode(json);
  } on FormatException catch (e) {
    throwFatalError(
        DiagnosticKind.settingsNotJson, uri: settingsUri, message: e.message);
  }
  if (userSettings is! Map) {
    throwFatalError(DiagnosticKind.settingsNotAMap, uri: settingsUri);
  }
  Uri packages;
  final List<String> options = <String>[];
  final Map<String, String> constants = <String, String>{};
  Address deviceAddress;
  DeviceType deviceType;
  IncrementalMode incrementalMode = IncrementalMode.none;
  userSettings.forEach((String key, value) {
    switch (key) {
      case "packages":
        if (value != null) {
          if (value is! String) {
            throwFatalError(
                DiagnosticKind.settingsPackagesNotAString, uri: settingsUri,
                userInput: '$value');
          }
          packages = settingsUri.resolve(value);
        }
        break;

      case "options":
        if (value != null) {
          if (value is! List) {
            throwFatalError(
                DiagnosticKind.settingsOptionsNotAList, uri: settingsUri,
                userInput: "$value");
          }
          for (var option in value) {
            if (option is! String) {
              throwFatalError(
                  DiagnosticKind.settingsOptionNotAString, uri: settingsUri,
                  userInput: '$option');
            }
            if (option.startsWith("-D")) {
              throwFatalError(
                  DiagnosticKind.settingsCompileTimeConstantAsOption,
                  uri: settingsUri, userInput: '$option');
            }
            options.add(option);
          }
        }
        break;

      case "constants":
        if (value != null) {
          if (value is! Map) {
            throwFatalError(
                DiagnosticKind.settingsConstantsNotAMap, uri: settingsUri);
          }
          value.forEach((String key, value) {
            if (value == null) {
              // Ignore.
            } else if (value is bool || value is int || value is String) {
              constants[key] = '$value';
            } else {
              throwFatalError(
                  DiagnosticKind.settingsUnrecognizedConstantValue,
                  uri: settingsUri, userInput: key,
                  additionalUserInput: '$value');
            }
          });
        }
        break;

      case "device_address":
        if (value != null) {
          if (value is! String) {
            throwFatalError(
                DiagnosticKind.settingsDeviceAddressNotAString,
                uri: settingsUri, userInput: '$value');
          }
          deviceAddress =
              parseAddress(value, defaultPort: AGENT_DEFAULT_PORT);
        }
        break;

      case "device_type":
        if (value != null) {
          if (value is! String) {
            throwFatalError(
                DiagnosticKind.settingsDeviceTypeNotAString,
                uri: settingsUri, userInput: '$value');
          }
          deviceType = parseDeviceType(value);
          if (deviceType == null) {
            throwFatalError(
                DiagnosticKind.settingsDeviceTypeUnrecognized,
                uri: settingsUri, userInput: '$value');
          }
        }
        break;

      case "incremental_mode":
        if (value != null) {
          if (value is! String) {
            throwFatalError(
                DiagnosticKind.settingsIncrementalModeNotAString,
                uri: settingsUri, userInput: '$value');
          }
          incrementalMode = parseIncrementalMode(value);
          if (incrementalMode == null) {
            throwFatalError(
                DiagnosticKind.settingsIncrementalModeUnrecognized,
                uri: settingsUri, userInput: '$value');
          }
        }
        break;

      default:
        throwFatalError(
            DiagnosticKind.settingsUnrecognizedKey, uri: settingsUri,
            userInput: key);
        break;
    }
  });
  return new Settings.fromSource(settingsUri,
      packages, options, constants, deviceAddress, deviceType, incrementalMode);
}

class Settings {
  final Uri source;

  final Uri packages;

  final List<String> options;

  final Map<String, String> constants;

  final Address deviceAddress;

  final DeviceType deviceType;

  final IncrementalMode incrementalMode;

  const Settings(
      this.packages,
      this.options,
      this.constants,
      this.deviceAddress,
      this.deviceType,
      this.incrementalMode) : source = null;

  const Settings.fromSource(
      this.source,
      this.packages,
      this.options,
      this.constants,
      this.deviceAddress,
      this.deviceType,
      this.incrementalMode);

  const Settings.empty()
      : this(null, const <String>[], const <String, String>{}, null, null,
             IncrementalMode.none);

  Settings copyWith({
      Uri packages,
      List<String> options,
      Map<String, String> constants,
      Address deviceAddress,
      DeviceType deviceType,
      IncrementalMode incrementalMode}) {

    if (packages == null) {
      packages = this.packages;
    }
    if (options == null) {
      options = this.options;
    }
    if (constants == null) {
      constants = this.constants;
    }
    if (deviceAddress == null) {
      deviceAddress = this.deviceAddress;
    }
    if (deviceType == null) {
      deviceType = this.deviceType;
    }
    if (incrementalMode == null) {
      incrementalMode = this.incrementalMode;
    }
    return new Settings(
        packages,
        options,
        constants,
        deviceAddress,
        deviceType,
        incrementalMode);
  }

  String toString() {
    return "Settings("
        "packages: $packages, "
        "options: $options, "
        "constants: $constants, "
        "device_address: $deviceAddress, "
        "device_type: $deviceType, "
        "incremental_mode: $incrementalMode)";
  }

  Map<String, dynamic> toJson() {
    Map<String, dynamic> result = <String, dynamic>{};

    void addIfNotNull(String name, value) {
      if (value != null) {
        result[name] = value;
      }
    }

    addIfNotNull("packages", packages == null ? null : "$packages");
    addIfNotNull("options", options);
    addIfNotNull("constants", constants);
    addIfNotNull("device_address", deviceAddress);
    addIfNotNull(
        "device_type",
        deviceType == null ? null : unParseDeviceType(deviceType));
    addIfNotNull(
        "incremental_mode",
        incrementalMode == null
            ? null : unparseIncrementalMode(incrementalMode));

    return result;
  }
}

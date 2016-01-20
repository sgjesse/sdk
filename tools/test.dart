#!/usr/bin/env dart
// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * This file is the entrypoint of the dart test suite.  This suite is used
 * to test:
 *
 *     1. the dart vm
 *     2. the dart2js compiler
 *     3. the static analyzer
 *     4. the dart core library
 *     5. other standard dart libraries (DOM bindings, ui libraries,
 *            io libraries etc.)
 *
 * This script is normally invoked by test.py.  (test.py finds the dart vm
 * and passses along all command line arguments to this script.)
 *
 * The command line args of this script are documented in
 * "tools/testing/dart/test_options.dart"; they are printed
 * when this script is run with "--help".
 *
 * The default test directory layout is documented in
 * "tools/testing/dart/test_suite.dart", above
 * "factory StandardTestSuite.forDirectory".
 */

library test;

import "dart:async";
import "dart:io";
import "dart:math" as math;
import "testing/dart/browser_controller.dart";
import "testing/dart/http_server.dart";
import "testing/dart/test_options.dart";
import "testing/dart/test_progress.dart";
import "testing/dart/test_runner.dart";
import "testing/dart/test_suite.dart";
import "testing/dart/utils.dart";

import 'testing/dart/fletch_warnings_suite.dart' show
    FletchWarningsSuite;

import 'testing/dart/fletch_test_suite.dart' show
    FletchTestSuite;

//import "../runtime/tests/vm/test_config.dart";
//import "../tests/co19/test_config.dart";

/**
 * The directories that contain test suites which follow the conventions
 * required by [StandardTestSuite]'s forDirectory constructor.
 * New test suites should follow this convention because it makes it much
 * simpler to add them to test.dart.  Existing test suites should be
 * moved to here, if possible.
*/
final TEST_SUITE_DIRECTORIES = [
    new Path('tests/coroutine'),
    new Path('tests/ffi'),
    new Path('tests/io'),
    new Path('tests/isolate'),
    new Path('tests/unsorted'),
    new Path('tests/lib'),
    new Path('tests/os'),
    new Path('tests/pkg'),
    new Path('samples'),
    new Path('tests/typed_data'),
];

final DART_SDK_TEST_SUITE_DIRECTORIES = [
    new Path('tests/corelib'),
    new Path('tests/language'),
];

final CC_TEST_SUITE_DIRECTORIES = [
    new Path('tests/cc_tests')
];

void testConfigurations(List<Map> configurations) {
  var startTime = new DateTime.now();
  // Extract global options from first configuration.
  var firstConf = configurations[0];
  bool isKillPersistentProcessEnabled =
      firstConf['kill_persistent_process'] != 0;
  bool isBuildBeforeTestingEnabled = firstConf['build_before_testing'] != 0;
  var maxProcesses = firstConf['tasks'];
  var progressIndicator = firstConf['progress'];
  // TODO(kustermann): Remove this option once the buildbots don't use it
  // anymore.
  var failureSummary = firstConf['failure-summary'];
  BuildbotProgressIndicator.stepName = firstConf['step_name'];
  var verbose = firstConf['verbose'];
  var printTiming = firstConf['time'];
  var listTests = firstConf['list'];

  var recordingPath = firstConf['record_to_file'];
  var recordingOutputPath = firstConf['replay_from_file'];

  Browser.deleteCache = firstConf['clear_browser_cache'];

  if (recordingPath != null && recordingOutputPath != null) {
    print("Fatal: Can't have the '--record_to_file' and '--replay_from_file'"
          "at the same time. Exiting ...");
    exit(1);
  }

  if (!hasSameModeAndArch(configurations)) {
    print("Persistent Fletch process doesn't support multiple "
          "arch and mode configurations");
    exit(1);
  }

  if (!firstConf['append_logs'])  {
    var files = [new File(TestUtils.flakyFileName()),
                 new File(TestUtils.testOutcomeFileName())];
    for (var file in files) {
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  DebugLogger.init(firstConf['write_debug_log'] ?
      TestUtils.debugLogfile() : null, append: firstConf['append_logs']);

  // Print the configurations being run by this execution of
  // test.dart. However, don't do it if the silent progress indicator
  // is used. This is only needed because of the junit tests.
  if (progressIndicator != 'silent') {
    List output_words = configurations.length > 1 ?
        ['Test configurations:'] : ['Test configuration:'];
    for (Map conf in configurations) {
      List settings = ['compiler', 'runtime', 'mode', 'arch']
          .map((name) => conf[name]).toList();
      if (conf['checked']) settings.add('checked');
      if (conf['clang']) settings.add('clang');
      if (conf['asan']) settings.add('asan');
      output_words.add(settings.join('_'));
    }
    print(output_words.join(' '));
  }

  var runningBrowserTests = configurations.any((config) {
    return TestUtils.isBrowserRuntime(config['runtime']);
  });

  if (isKillPersistentProcessEnabled) killDriverMain();
  if (isBuildBeforeTestingEnabled) runBuilds(configurations);

  List<Future> serverFutures = [];
  var testSuites = new List<TestSuite>();
  var maxBrowserProcesses = maxProcesses;
  if (configurations.length > 1 &&
      (configurations[0]['test_server_port'] != 0 ||
       configurations[0]['test_server_cross_origin_port'] != 0)) {
    print("If the http server ports are specified, only one configuration"
          " may be run at a time");
    exit(1);
  }
  for (var conf in configurations) {
    Map<String, RegExp> selectors = conf['selectors'];
    var useContentSecurityPolicy = conf['csp'];
    if (!listTests && runningBrowserTests) {
      // Start global http servers that serve the entire dart repo.
      // The http server is available on window.location.port, and a second
      // server for cross-domain tests can be found by calling
      // getCrossOriginPortNumber().
      var servers = new TestingServers(new Path(TestUtils.buildDir(conf)),
                                       useContentSecurityPolicy,
                                       conf['runtime'],
                                       null,
                                       conf['package_root']);
      serverFutures.add(servers.startServers(conf['local_ip'],
          port: conf['test_server_port'],
          crossOriginPort: conf['test_server_cross_origin_port']));
      conf['_servers_'] = servers;
      if (verbose) {
        serverFutures.last.then((_) {
          var commandline = servers.httpServerCommandline();
          print('Started HttpServers: $commandline');
        });
      }
    }

    if (conf['runtime'].startsWith('ie')) {
      // NOTE: We've experienced random timeouts of tests on ie9/ie10. The
      // underlying issue has not been determined yet. Our current hypothesis
      // is that windows does not handle the IE processes independently.
      // If we have more than one browser and kill a browser we are seeing
      // issues with starting up a new browser just after killing the hanging
      // browser.
      maxBrowserProcesses = 1;
    } else if (conf['runtime'].startsWith('safari')) {
      // Safari does not allow us to run from a fresh profile, so we can only
      // use one browser. Additionally, you can not start two simulators
      // for mobile safari simultainiously.
      maxBrowserProcesses = 1;
    } else if (conf['runtime'] == 'chrome' &&
               Platform.operatingSystem == 'macos') {
      // Chrome on mac results in random timeouts.
      maxBrowserProcesses = math.max(1, maxBrowserProcesses ~/ 2);
    }

    // If we specifically pass in a suite only run that.
    if (conf['suite_dir'] != null) {
      print(conf);
      var suite_path = new Path(conf['suite_dir']);
      testSuites.add(new PKGTestSuite(conf, suite_path));
    } else if (conf['runtime'] == 'fletch_cc_tests') {
      for (final testSuiteDir in CC_TEST_SUITE_DIRECTORIES) {
        final name = testSuiteDir.filename;
        if (selectors.containsKey(name)) {
          testSuites.add(
            new StandardTestSuite.forDirectory(conf, testSuiteDir));
        }
      }
    } else if (conf['runtime'] == 'fletch_warnings') {
      if (selectors.containsKey('warnings')) {
        testSuites.add(new FletchWarningsSuite(conf, 'warnings'));
      }
    } else if (conf['runtime'] == 'fletch_tests') {
      if (selectors.containsKey('fletch_tests')) {
        testSuites.add(new FletchTestSuite(conf, 'tests/fletch_tests'));
      }
    } else {
      for (final testSuiteDir in TEST_SUITE_DIRECTORIES) {
        final name = testSuiteDir.filename;
        if (selectors.containsKey(name)) {
          testSuites.add(
              new StandardTestSuite.forDirectory(conf, testSuiteDir));
        }
      }
      for (final testSuiteDir in DART_SDK_TEST_SUITE_DIRECTORIES) {
        final name = testSuiteDir.filename;
        if (selectors.containsKey(name)) {
          // For these tests suites that we get from the dart repository, the
          // status file is in tests/NAME_OF_SUIITE.status
          testSuites.add(
              new StandardTestSuite.forDirectory(
                  conf,
                  testSuiteDir,
                  statusFilePaths: ['$testSuiteDir.status']));
        }
      }
    }
  }

  void allTestsFinished() {
    for (var conf in configurations) {
      if (conf.containsKey('_servers_')) {
        conf['_servers_'].stopServers();
      }
    }
    DebugLogger.close();
  }

  var eventListener = [];
  if (progressIndicator != 'silent') {
    var printFailures = true;
    var formatter = new Formatter();
    if (progressIndicator == 'color') {
      progressIndicator = 'compact';
      formatter = new ColorFormatter();
    }
    if (progressIndicator == 'diff') {
      progressIndicator = 'compact';
      formatter = new ColorFormatter();
      printFailures = false;
      eventListener.add(new StatusFileUpdatePrinter());
    }
    eventListener.add(new SummaryPrinter());
    eventListener.add(new FlakyLogWriter());
    if (printFailures) {
      // The buildbot has it's own failure summary since it needs to wrap it
      // into '@@@'-annotated sections.
      var printFailureSummary = progressIndicator != 'buildbot';
      eventListener.add(new TestFailurePrinter(printFailureSummary, formatter));
    }
    eventListener.add(progressIndicatorFromName(progressIndicator,
                                                startTime,
                                                formatter));
    if (printTiming) {
      eventListener.add(new TimingPrinter(startTime));
    }
    eventListener.add(new SkippedCompilationsPrinter());
    eventListener.add(new LeftOverTempDirPrinter());
  }
  if (firstConf['write_test_outcome_log']) {
    eventListener.add(new TestOutcomeLogWriter());
  }
  if (firstConf['copy_coredumps']) {
    eventListener.add(new UnexpectedCrashDumpArchiver());
  }

  eventListener.add(new ExitCodeSetter());

  void startProcessQueue() {
    // [firstConf] is needed here, since the ProcessQueue needs to know the
    // settings of 'noBatch' and 'local_ip'
    new ProcessQueue(firstConf,
                     maxProcesses,
                     maxBrowserProcesses,
                     startTime,
                     testSuites,
                     eventListener,
                     allTestsFinished,
                     verbose,
                     listTests,
                     recordingPath,
                     recordingOutputPath);
  }

  // Start all the HTTP servers required before starting the process queue.
  if (serverFutures.isEmpty) {
    startProcessQueue();
  } else {
    Future.wait(serverFutures).then((_) => startProcessQueue());
  }
}

bool hasSameModeAndArch(List<Map> configurations) {
  String mode = configurations[0]['mode'];
  String arch = configurations[0]['arch'];
  for (Map configuration in configurations.skip(1)) {
    if (configuration['mode'] != mode) return false;
    if (configuration['arch'] != arch) return false;
  }
  return true;
}

Future deleteTemporaryDartDirectories() {
  var completer = new Completer();
  var environment = Platform.environment;
  if (environment['DART_TESTING_DELETE_TEMPORARY_DIRECTORIES'] == '1') {
    LeftOverTempDirPrinter.getLeftOverTemporaryDirectories().listen(
        (Directory tempDirectory) {
          try {
            tempDirectory.deleteSync(recursive: true);
          } catch (error) {
            DebugLogger.error(error);
          }
        }, onDone: completer.complete);
  } else {
    completer.complete();
  }
  return completer.future;
}

String runChecked(String executable, List<String> arguments) {
  ProcessResult result = Process.runSync(executable, arguments);
  if (result.exitCode != 0) {
    throw "Running '$executable ${arguments.join(' ')}' failed "
        "(exit code = ${result.exitCode}).\n${result.stdout}\n${result.stderr}";
  }
  return result.stdout;
}

void killDriverMain() {
  String processes = runChecked("/bin/ps", <String>["x", "-opid,args"]);
  for (String process in processes.split("\n")) {
    // It's important to remove white space as output from ps is padded with
    // whitespace.
    process = process.trim();
    if (process.contains("package:fletchc/src/hub/hub_main.dart")) {
      int index = process.indexOf(" ");
      String pidString = process.substring(0, index);
      String arguments = process.substring(index + 1);
      // TODO(ahe): Use [Process.killPid] instead.
      print("Killing $pidString: $arguments");
      print("Use --kill-persistent-process=0 to skip this step.");
      runChecked("kill", <String>[pidString]);
    }
  }
}

void runBuilds(List<Map> configurations) {
  Set<String> completedBuilds = new Set<String>();
  for (Map configuration in configurations) {
    String buildDir = TestUtils.buildDir(configuration);
    if (completedBuilds.add(buildDir)) {
      print("Building in $buildDir.");
      print("Use --build-before-testing=0 to skip this step.");
      runChecked("ninja", <String>["-C", buildDir]);
    }
  }
  print("Building done.");
}

void main(List<String> arguments) {
  // This script is in [dart]/tools.
  TestUtils.setDartDirUri(Platform.script.resolve('..'));
  deleteTemporaryDartDirectories().then((_) {
    var optionsParser = new TestOptionsParser();
    var configurations = optionsParser.parse(arguments);
    if (configurations != null && configurations.length > 0) {
      testConfigurations(configurations);
    }
  });
}


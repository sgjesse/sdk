// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.fletch_compiler;

import 'dart:async' show
    Future;

import 'dart:convert' show
    UTF8;

import 'dart:io' show
    File,
    Link,
    Platform;

import 'package:compiler/compiler_new.dart' show
    CompilerInput,
    CompilerOutput,
    CompilerDiagnostics;

import 'package:compiler/src/source_file_provider.dart' show
    CompilerSourceFileProvider,
    FormattingDiagnosticHandler,
    SourceFileProvider;

import 'package:compiler/src/filenames.dart' show
    appendSlash;

import 'src/fletch_native_descriptor.dart' show
    FletchNativeDescriptor;

import 'src/fletch_backend.dart' show
    FletchBackend;

import 'package:compiler/src/apiimpl.dart' as apiimpl;

import 'src/fletch_compiler_implementation.dart' show
    FletchCompilerImplementation,
    OutputProvider;

import 'fletch_system.dart';

import 'incremental/fletchc_incremental.dart' show
    IncrementalCompiler,
    IncrementalMode;

import 'src/guess_configuration.dart' show
    executable,
    guessFletchVm;

const String _LIBRARY_ROOT =
    const String.fromEnvironment("fletchc-library-root");

const String fletchDeviceType =
    const String.fromEnvironment("fletch.device-type");
const String _NATIVES_JSON =
    const String.fromEnvironment("fletch-natives-json");

const String StringOrUri = "String or Uri";

class FletchCompiler {
  final FletchCompilerImplementation _compiler;

  final Uri script;

  final bool verbose;

  final String platform;

  final Uri nativesJson;

  FletchCompiler._(
      this._compiler,
      this.script,
      this.verbose,
      this.platform,
      this.nativesJson);

  Backdoor get backdoor => new Backdoor(this);

  factory FletchCompiler(
      {CompilerInput provider,
       CompilerOutput outputProvider,
       CompilerDiagnostics handler,
       @StringOrUri libraryRoot,
       @StringOrUri packageConfig,
       @StringOrUri script,
       @StringOrUri fletchVm,
       @StringOrUri currentDirectory,
       @StringOrUri nativesJson,
       List<String> options,
       Map<String, dynamic> environment,
       String platform,
       IncrementalCompiler incrementalCompiler}) {

    Uri base = _computeValidatedUri(
        currentDirectory, name: 'currentDirectory', ensureTrailingSlash: true);
    if (base == null) {
      base = Uri.base;
    }

    if (options == null) {
      options = <String>[];
    } else {
      options = new List<String>.from(options);
    }

    options.add("--platform-config=$platform");

    final bool isVerbose = apiimpl.CompilerImpl.hasOption(options, '--verbose');

    if (provider == null) {
      provider = new CompilerSourceFileProvider()
          ..cwd = base;
    }

    if (handler == null) {
      SourceFileProvider sourceFileProvider = null;
      if (provider is SourceFileProvider) {
        sourceFileProvider = provider;
      }
      handler = new FormattingDiagnosticHandler(sourceFileProvider)
          ..throwOnError = false
          ..verbose = isVerbose;
    }

    if (outputProvider == null) {
      outputProvider = new OutputProvider();
    }

    if (libraryRoot == null && _LIBRARY_ROOT != null) {
      libraryRoot = executable.resolve(appendSlash(_LIBRARY_ROOT));
    }
    libraryRoot = _computeValidatedUri(
        libraryRoot, name: 'libraryRoot', ensureTrailingSlash: true,
        base: base);
    if (libraryRoot == null) {
      libraryRoot = _guessLibraryRoot(platform);
      if (libraryRoot == null) {
        throw new StateError("""
Unable to guess the location of the Dart SDK (libraryRoot).
Try adding command-line option '-Ddart-sdk=<location of the Dart sdk>'.""");
      }
    } else if (!_looksLikeLibraryRoot(libraryRoot, platform)) {
      throw new ArgumentError(
          "[libraryRoot]: Dart SDK library not found in '$libraryRoot'.");
    }

    script = _computeValidatedUri(script, name: 'script', base: base);

    packageConfig = _computeValidatedUri(
        packageConfig, name: 'packageConfig', base: base);
    if (packageConfig == null) {
      if (script != null) {
        packageConfig = script.resolve('.packages');
      } else {
        packageConfig = base.resolve('.packages');
      }
    }

    fletchVm = guessFletchVm(
        _computeValidatedUri(fletchVm, name: 'fletchVm', base: base));

    if (environment == null) {
      environment = <String, dynamic>{};
    }

    if (nativesJson == null && _NATIVES_JSON != null) {
      nativesJson = base.resolve(_NATIVES_JSON);
    }
    nativesJson = _computeValidatedUri(
        nativesJson, name: 'nativesJson', base: base);

    if (nativesJson == null) {
      nativesJson = _guessNativesJson();
      if (nativesJson == null) {
        throw new StateError(
"""
Unable to guess the location of the 'natives.json' file (nativesJson).
Try adding command-line option '-Dfletch-natives-json=<path to natives.json>."""
);
      }
    } else if (!_looksLikeNativesJson(nativesJson)) {
      throw new ArgumentError(
          "[nativesJson]: natives.json not found in '$nativesJson'.");
    }

    FletchCompilerImplementation compiler = new FletchCompilerImplementation(
        provider,
        outputProvider,
        handler,
        libraryRoot,
        packageConfig,
        nativesJson,
        options,
        environment,
        fletchVm,
        incrementalCompiler);

    compiler.log("Using library root: $libraryRoot");
    compiler.log("Using package config: $packageConfig");

    var helper = new FletchCompiler._(
        compiler, script, isVerbose, platform, nativesJson);
    compiler.helper = helper;
    return helper;
  }

  Future<FletchDelta> run([@StringOrUri script]) async {
    // TODO(ahe): Need a base argument.
    script = _computeValidatedUri(script, name: 'script');
    if (script == null) {
      script = this.script;
    }
    if (script == null) {
      throw new StateError("No [script] provided.");
    }
    await _inititalizeContext();
    FletchBackend backend = _compiler.backend;
    return _compiler.run(script).then((_) => backend.computeDelta());
  }

  Future _inititalizeContext() async {
    var data = await _compiler.callUserProvider(nativesJson);
    if (data is! String) {
      if (data.last == 0) {
        data = data.sublist(0, data.length - 1);
      }
      data = UTF8.decode(data);
    }
    Map<String, FletchNativeDescriptor> natives =
        <String, FletchNativeDescriptor>{};
    Map<String, String> names = <String, String>{};
    FletchNativeDescriptor.decode(data, natives, names);
    _compiler.context.nativeDescriptors = natives;
    _compiler.context.setNames(names);
  }

  Uri get fletchVm => _compiler.fletchVm;

  /// Create a new instance of [IncrementalCompiler].
  IncrementalCompiler newIncrementalCompiler(
      IncrementalMode support,
      {List<String> options: const <String>[]}) {
    return new IncrementalCompiler(
        libraryRoot: _compiler.libraryRoot,
        packageConfig: _compiler.packageConfig,
        fletchVm: _compiler.fletchVm,
        nativesJson: _compiler.nativesJson,
        inputProvider: _compiler.provider,
        diagnosticHandler: _compiler.handler,
        options: options,
        outputProvider: _compiler.userOutputProvider,
        environment: _compiler.environment,
        support: support,
        platform: platform);
  }
}

// Backdoor around Dart privacy. For now, certain components (in particular
// incremental compilation) need access to implementation details that shouldn't
// be part of the API of this file.
// TODO(ahe): Delete this class.
class Backdoor {
  final FletchCompiler _compiler;

  Backdoor(this._compiler);

  Future<FletchCompilerImplementation> get compilerImplementation async {
    await _compiler._inititalizeContext();
    return _compiler._compiler;
  }
}

/// Resolves any symbolic links in [uri] if its scheme is "file". Otherwise
/// return the given [uri].
Uri _resolveSymbolicLinks(Uri uri) {
  if (uri.scheme != 'file') return uri;
  File apparentLocation = new File.fromUri(uri);
  String realLocation = apparentLocation.resolveSymbolicLinksSync();
  if (uri.path.endsWith("/")) {
    realLocation = appendSlash(realLocation);
  }
  return new Uri.file(realLocation);
}

bool _containsFile(Uri uri, String expectedFile) {
  if (uri.scheme != 'file') return true;
  return new File.fromUri(uri.resolve(expectedFile)).existsSync();
}

bool _looksLikeLibraryRoot(Uri uri, String platform) {
  return _containsFile(uri, platform);
}

Uri _computeValidatedUri(
    @StringOrUri stringOrUri,
    {String name,
     bool ensureTrailingSlash: false,
     Uri base}) {
  if (base == null) {
    base = Uri.base;
  }
  assert(name != null);
  if (stringOrUri == null) {
    return null;
  } else if (stringOrUri is String) {
    if (ensureTrailingSlash) {
      stringOrUri = appendSlash(stringOrUri);
    }
    return base.resolve(stringOrUri);
  } else if (stringOrUri is Uri) {
    return base.resolveUri(stringOrUri);
  } else {
    throw new ArgumentError("[$name] should be a String or a Uri.");
  }
}

Uri _guessLibraryRoot(String platform) {
  // When running from fletch, [executable] is
  // ".../fletch-repo/fletch/out/$CONFIGURATION/dart", which means that the
  // fletch root is the lib directory in the 2th parent directory (due to
  // how URI resolution works, the filename ("dart") is removed before
  // resolving, for example,
  // ".../fletch-repo/fletch/out/$CONFIGURATION/../../" becomes
  // ".../fletch-repo/fletch/").
  Uri guess = executable.resolve('../../lib/');
  if (_looksLikeLibraryRoot(guess, platform)) return guess;
  return null;
}

bool _looksLikeNativesJson(Uri uri) {
  return new File.fromUri(uri).existsSync();
}

Uri _guessNativesJson() {
  Uri uri = executable.resolve('natives.json');
  return _looksLikeNativesJson(uri) ? uri : null;
}

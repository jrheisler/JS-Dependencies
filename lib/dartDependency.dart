// dartDependency.dart — Analyzer-backed Dart dependency and security crawler
//
// Outputs:
//   * dartDependencies.json — dependency graph with import/export/public API data
//   * dartSecurity.json     — security findings detected via analyzer visitors + text sweeps
//
// Workflow:
//   1. Build a single AnalysisContextCollection for the repo and resolve every Dart unit.
//   2. Collect per-library import/export metadata, public API signatures, and construct the
//      file-level dependency graph (nodes/edges).
//   3. Run AST visitors + textual sweeps for security smells and secrets.
//   4. Emit JSON reports for downstream tooling.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart' show PathNotFoundException;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/source/source.dart';
import 'package:path/path.dart' as p;

import 'hash_utils.dart';

class _CliOptions {
  final bool debug;
  final List<String> entryArgs;
  final String? explain;
  final String? sdkPath;

  const _CliOptions({
    required this.debug,
    required this.entryArgs,
    this.explain,
    this.sdkPath,
  });
}

class _SdkSearchResult {
  final String? path;
  final List<String> attempted;

  const _SdkSearchResult({required this.path, required this.attempted});
}

class _MissingSdkException implements Exception {
  final String message;

  const _MissingSdkException(this.message);

  @override
  String toString() => message;
}

_CliOptions _parseArgs(List<String> args) {
  var debug = false;
  final entryArgs = <String>[];
  String? explain;
  String? sdkPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--debug' || arg == '-d') {
      debug = true;
      continue;
    }
    if (arg.startsWith('--explain=')) {
      explain = arg.substring('--explain='.length);
      continue;
    }
    if (arg == '--explain' && i + 1 < args.length) {
      explain = args[++i];
      continue;
    }
    if (arg.startsWith('--dart-sdk=')) {
      sdkPath = arg.substring('--dart-sdk='.length);
      continue;
    }
    if ((arg == '--dart-sdk' || arg == '--sdk') && i + 1 < args.length) {
      sdkPath = args[++i];
      continue;
    }
    entryArgs.add(arg);
  }

  return _CliOptions(
    debug: debug,
    entryArgs: entryArgs,
    explain: explain,
    sdkPath: sdkPath,
  );
}

_SdkSearchResult _discoverSdkPath(
  String root,
  _CliOptions cli, {
  Map<String, String>? environment,
}) {
  final attempted = <String>[];
  final seen = <String>{};

  final env = environment ?? Platform.environment;

  String? check(String? candidate) {
    if (candidate == null || candidate.trim().isEmpty) return null;
    final normalized = p.normalize(p.absolute(candidate));
    if (!seen.add(normalized)) return null;
    attempted.add(normalized);
    return _looksLikeSdk(normalized) ? normalized : null;
  }

  final explicit = check(cli.sdkPath);
  if (explicit != null) {
    return _SdkSearchResult(path: explicit, attempted: attempted);
  }

  final envSdk = check(env['DART_SDK']);
  if (envSdk != null) {
    return _SdkSearchResult(path: envSdk, attempted: attempted);
  }

  final flutterRoot = env['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    final flutterSdk = check(p.join(flutterRoot, 'bin', 'cache', 'dart-sdk'));
    if (flutterSdk != null) {
      return _SdkSearchResult(path: flutterSdk, attempted: attempted);
    }
  }

  final exeDir = p.dirname(Platform.resolvedExecutable);
  final exeCandidates = [
    p.join(exeDir, 'dart-sdk'),
    p.join(p.dirname(exeDir), 'dart-sdk'),
  ];
  for (final candidate in exeCandidates) {
    final resolved = check(candidate);
    if (resolved != null) {
      return _SdkSearchResult(path: resolved, attempted: attempted);
    }
  }

  final localCandidates = [
    p.join(root, 'dart-sdk'),
    p.join(root, '.dart-sdk'),
    p.join(root, 'tools', 'dart-sdk'),
  ];
  for (final candidate in localCandidates) {
    final resolved = check(candidate);
    if (resolved != null) {
      return _SdkSearchResult(path: resolved, attempted: attempted);
    }
  }

  final pathEnv = env['PATH'];
  for (final candidate in _pathDerivedSdkCandidates(pathEnv)) {
    final resolved = check(candidate);
    if (resolved != null) {
      return _SdkSearchResult(path: resolved, attempted: attempted);
    }
  }

  return _SdkSearchResult(path: null, attempted: attempted);
}

Iterable<String> _pathDerivedSdkCandidates(String? pathEnv) sync* {
  if (pathEnv == null || pathEnv.trim().isEmpty) return;
  final separator = Platform.isWindows ? ';' : ':';
  for (final entry in pathEnv.split(separator)) {
    final normalized = entry.trim();
    if (normalized.isEmpty) continue;
    final resolved = p.normalize(normalized);
    yield resolved;
    yield p.dirname(resolved);
    yield p.join(resolved, 'cache', 'dart-sdk');
    yield p.join(resolved, '..', 'cache', 'dart-sdk');
    yield p.join(resolved, '..', 'dart-sdk');
  }
}

bool _looksLikeSdk(String path) {
  final provider = PhysicalResourceProvider.INSTANCE;
  final version = provider.getFile(p.join(path, 'version'));
  if (!version.exists) return false;
  final libDir = provider.getFolder(p.join(path, 'lib'));
  if (!libDir.exists) return false;
  final metadataJson = provider.getFile(
    p.join(path, 'lib', '_internal', 'sdk_library_metadata', 'lib', 'libraries.json'),
  );
  final metadataDart = provider.getFile(
    p.join(path, 'lib', '_internal', 'sdk_library_metadata', 'lib', 'libraries.dart'),
  );
  return metadataJson.exists || metadataDart.exists;
}

String _missingSdkMessage({
  String? attemptedPath,
  List<String> searched = const <String>[],
  String? failingPath,
}) {
  final buffer = StringBuffer()
    ..writeln('Unable to locate the Dart SDK required for static analysis.');
  if (failingPath != null) {
    buffer.writeln('Analyzer tried to read: $failingPath');
  }
  if (attemptedPath != null) {
    buffer.writeln('Explicit SDK path: $attemptedPath');
  }
  if (searched.isNotEmpty) {
    buffer.writeln('Searched locations:');
    for (final path in searched) {
      buffer.writeln('  - $path');
    }
  }
  buffer
    ..writeln('Provide the SDK path with --dart-sdk <path> or set the DART_SDK environment variable.')
    ..writeln('If Flutter is installed, use <flutter>/bin/cache/dart-sdk.')
    ..writeln('You can also place a dart-sdk directory next to dartDependency.exe.');
  return buffer.toString().trimRight();
}

String _canonicalizePathForMap(String path) {
  var normalized = path;
  if (Platform.isWindows) {
    const extendedPrefix = '\\?\\';
    const extendedPrefixForward = '//?/';
    if (normalized.startsWith(extendedPrefix)) {
      normalized = normalized.substring(extendedPrefix.length);
    } else if (normalized.startsWith(extendedPrefixForward)) {
      normalized = normalized.substring(extendedPrefixForward.length);
    }
    if (normalized.startsWith('UNC\\')) {
      normalized = '\\' + normalized.substring(3);
    }
    normalized = normalized.replaceAll('/', '\\');
  } else {
    normalized = normalized.replaceAll('\\', '/');
  }
  normalized = p.normalize(normalized);
  if (Platform.isWindows) {
    return normalized.toLowerCase();
  }
  return normalized;
}

String _relativePathWithinRoot(String root, String path) {
  final normalizedRoot = p.normalize(root);
  final normalizedPath = p.normalize(path);
  final separator = Platform.isWindows ? '\\' : '/';

  final relative = p.relative(normalizedPath, from: normalizedRoot);
  final altSeparator = separator == '/' ? '\\' : '/';
  final climbsAboveRoot =
      relative == '..' ||
      relative.startsWith('..$separator') ||
      relative.startsWith('..$altSeparator');
  final looksRelative = !p.isAbsolute(relative) && !climbsAboveRoot;
  if (looksRelative) {
    return relative;
  }

  final canonicalRoot = _canonicalizePathForMap(normalizedRoot);
  final canonicalPath = _canonicalizePathForMap(normalizedPath);
  final prefix = canonicalRoot.endsWith(separator)
      ? canonicalRoot
      : '$canonicalRoot$separator';
  if (!canonicalPath.startsWith(prefix)) {
    return relative;
  }

  final remainderCanonical = canonicalPath.substring(prefix.length);
  if (remainderCanonical.isEmpty) {
    return '.';
  }

  final remainderLength = remainderCanonical.length;
  final startIndex = normalizedPath.length - remainderLength;
  if (startIndex >= 0 && startIndex <= normalizedPath.length) {
    return normalizedPath.substring(startIndex);
  }

  if (Platform.isWindows) {
    return remainderCanonical.replaceAll('/', '\\');
  }
  return remainderCanonical.replaceAll('\\', '/');
}

T? _tryGetter<T>(T? Function() getter) {
  try {
    return getter();
  } catch (_) {
    return null;
  }
}

dynamic _importDirectiveElement(ImportDirective directive) {
  return _tryGetter(() => (directive as dynamic).element) ??
      _tryGetter(() => (directive as dynamic).element2);
}

dynamic _exportDirectiveElement(ExportDirective directive) {
  return _tryGetter(() => (directive as dynamic).element) ??
      _tryGetter(() => (directive as dynamic).element2);
}

dynamic _partOfDirectiveElement(PartOfDirective directive) {
  return _tryGetter(() => (directive as dynamic).element) ??
      _tryGetter(() => (directive as dynamic).element2);
}

Source _librarySource(LibraryElement lib) {
  final dynamic dyn = lib;
  final source = _tryGetter(() => dyn.source as Source?) ??
      _tryGetter(() => dyn.librarySource as Source?);
  if (source != null) {
    return source;
  }
  throw StateError('Unable to determine source for library ${lib.name ?? '<unnamed>'}');
}

LibraryElement? _importedLibraryFrom(dynamic element) {
  if (element == null) return null;
  final lib = _tryGetter(() => (element as dynamic).importedLibrary as LibraryElement?);
  if (lib != null) {
    return lib;
  }
  final alt = _tryGetter(() => (element as dynamic).importedLibrary2);
  if (alt != null) {
    final library = _tryGetter(() => (alt as dynamic).library as LibraryElement?);
    if (library != null) {
      return library;
    }
    final elementField = _tryGetter(() => (alt as dynamic).element as LibraryElement?);
    if (elementField != null) {
      return elementField;
    }
  }
  return null;
}

String? _importedLibraryUri(dynamic element) {
  if (element == null) return null;
  final uri = _tryGetter(() => (element as dynamic).uri as String?);
  if (uri != null) {
    return uri;
  }
  final alt = _tryGetter(() => (element as dynamic).uri2);
  if (alt != null) {
    final value = _tryGetter(() => (alt as dynamic).stringValue as String?);
    if (value != null) {
      return value;
    }
    final uriStr = _tryGetter(() => (alt as dynamic).uriStr as String?);
    if (uriStr != null) {
      return uriStr;
    }
  }
  return null;
}

LibraryElement? _exportedLibraryFrom(dynamic element) {
  if (element == null) return null;
  final lib = _tryGetter(() => (element as dynamic).exportedLibrary as LibraryElement?);
  if (lib != null) {
    return lib;
  }
  final alt = _tryGetter(() => (element as dynamic).exportedLibrary2);
  if (alt != null) {
    final library = _tryGetter(() => (alt as dynamic).library as LibraryElement?);
    if (library != null) {
      return library;
    }
    final elementField = _tryGetter(() => (alt as dynamic).element as LibraryElement?);
    if (elementField != null) {
      return elementField;
    }
  }
  return null;
}

String? _exportedLibraryUri(dynamic element) {
  if (element == null) return null;
  final uri = _tryGetter(() => (element as dynamic).uri as String?);
  if (uri != null) {
    return uri;
  }
  final alt = _tryGetter(() => (element as dynamic).uri2);
  if (alt != null) {
    final value = _tryGetter(() => (alt as dynamic).stringValue as String?);
    if (value != null) {
      return value;
    }
    final uriStr = _tryGetter(() => (alt as dynamic).uriStr as String?);
    if (uriStr != null) {
      return uriStr;
    }
  }
  return null;
}

Iterable<dynamic> _libraryImports(LibraryElement lib) {
  final dynamic dyn = lib;
  return _tryGetter(() => dyn.libraryImports as Iterable<dynamic>?) ??
      _tryGetter(() => dyn.imports as Iterable<dynamic>?) ??
      const <dynamic>[];
}

Iterable<dynamic> _libraryExports(LibraryElement lib) {
  final dynamic dyn = lib;
  return _tryGetter(() => dyn.libraryExports as Iterable<dynamic>?) ??
      _tryGetter(() => dyn.exports as Iterable<dynamic>?) ??
      const <dynamic>[];
}

Iterable<dynamic> _libraryParts(LibraryElement lib) {
  final dynamic dyn = lib;
  return _tryGetter(() => dyn.parts as Iterable<dynamic>?) ??
      _tryGetter(() => dyn.libraryParts as Iterable<dynamic>?) ??
      const <dynamic>[];
}

Source? _partElementSource(dynamic element) {
  return _tryGetter(() => (element as dynamic).source as Source?) ??
      _tryGetter(() => (element as dynamic).librarySource as Source?);
}

Map<String, Element> _namespaceElements(dynamic namespace) {
  return _tryGetter(() => namespace.definedNames as Map<String, Element>?) ??
      _tryGetter(() => namespace.definedElements as Map<String, Element>?) ??
      const <String, Element>{};
}

Element? _resolvedElement(Object? node) {
  if (node == null) return null;
  final dynamic dyn = node;
  return _tryGetter(() => dyn.staticElement as Element?) ??
      _tryGetter(() => dyn.element as Element?);
}

String _elementDisplay(Element element) {
  final dynamic dyn = element;
  return _tryGetter(() => dyn.getDisplayString(withNullability: true) as String?) ??
      _tryGetter(() => dyn.displayString(withNullability: true) as String?) ??
      element.displayName;
}

String? _libraryUri(LibraryElement? library) {
  if (library == null) return null;
  return _librarySource(library).uri.toString();
}

String? _elementLibraryUri(Element? element) {
  return _libraryUri(element?.library);
}

Future<void> main(List<String> args) async {
  final cli = _parseArgs(args);
  final cwd = p.normalize(p.absolute('.'));

  final packageName = await _readPackageName(cwd);
  final sdkSearch = _discoverSdkPath(cwd, cli);
  late final Map<String, ResolvedUnitResult> units;
  try {
    units = await _resolveUnits(
      cwd,
      sdkPath: sdkSearch.path,
      sdkSearchPaths: sdkSearch.attempted,
    );
  } on _MissingSdkException catch (e) {
    stderr.writeln('[error] ${e.message}');
    exitCode = 64;
    return;
  }

  final explicitEntries = _normalizeEntryArgs(cli.entryArgs, cwd);

  final graph = await _buildDependencyGraph(
    cwd,
    units,
    packageName,
    explicitEntries,
  );

  final exportsByFile = <String, Map<String, dynamic>>{};
  final exportsByCanonical = <String, Map<String, dynamic>>{};
  for (final libSummary in graph.libraries) {
    final groups = <String, dynamic>{};
    libSummary.publicApi.forEach((kind, value) {
      if (value is List && value.isNotEmpty) {
        groups[kind] = value.map(_cloneJsonLike).toList();
      }
    });
    if (groups.isNotEmpty) {
      exportsByFile[libSummary.path] = groups;
      exportsByCanonical[_canonicalizePathForMap(libSummary.path)] = groups;
    }
  }

  final nodesJson = graph.nodes.map((n) {
    final nodeJson = n.toJson();
    Map<String, dynamic>? exports = exportsByFile[n.id];
    exports ??= exportsByCanonical[_canonicalizePathForMap(n.id)];
    if (exports != null && exports.isNotEmpty) {
      nodeJson['exports'] = _cloneJsonLike(exports);
    }
    return nodeJson;
  }).toList();

  final depsJson = <String, dynamic>{
    'nodes': nodesJson,
    'edges': graph.edges.map((e) => e.toJson()).toList(),
    'libraries': graph.libraries.map((l) => l.toJson()).toList(),
    'entries': graph.entries,
  };
  if (exportsByFile.isNotEmpty) {
    depsJson['exports'] = exportsByFile;
  }

  final security = await _runSecurity(cwd, units);
  final findingsByFile = <String, List<Map<String, dynamic>>>{};
  final rawFindings = security['findings'];
  if (rawFindings is List) {
    for (final entry in rawFindings) {
      if (entry is! Map) continue;
      final file = entry['file'];
      if (file == null) continue;
      final key = file.toString().trim();
      if (key.isEmpty) continue;
      final cloned = _cloneJsonLike(entry);
      if (cloned is Map<String, dynamic>) {
        findingsByFile.putIfAbsent(key, () => []);
        findingsByFile[key]!.add(cloned);
      }
    }
  }
  if (findingsByFile.isNotEmpty) {
    depsJson['securityFindings'] = findingsByFile;
  }
  if ((security['findings'] is List && (security['findings'] as List).isNotEmpty) ||
      (security['summary'] is Map && (security['summary'] as Map).isNotEmpty)) {
    depsJson['security'] = _cloneJsonLike(security);
  }

  final depsPath = p.join(cwd, 'dartDependencies.json');
  await _writeJson(depsPath, depsJson);
  final secPath = p.join(cwd, 'dartSecurity.json');
  await _writeJson(secPath, security);

  final total = graph.nodes.length;
  final used = graph.nodes.where((n) => n.state == 'used').length;
  final unused = graph.nodes.where((n) => n.state == 'unused').length;
  final externals = graph.nodes.where((n) => n.type == 'external').length;
  final maxDeg = graph.nodes.fold<int>(0, (acc, n) {
    final deg = n.inDeg + n.outDeg;
    return deg > acc ? deg : acc;
  });

  if (cli.debug) {
    stderr.writeln('[debug] cwd=$cwd');
    if (sdkSearch.path != null) {
      stderr.writeln('[debug] dartSdk=${sdkSearch.path}');
    }
    if (sdkSearch.path == null && sdkSearch.attempted.isNotEmpty) {
      stderr.writeln('[debug] sdkCandidates=${sdkSearch.attempted}');
    }
    stderr.writeln('[debug] explicitEntries=${explicitEntries.toList()..sort()}');
    stderr.writeln('[debug] autoEntries=${graph.autoEntries.toList()..sort()}');
    stderr.writeln('[debug] finalEntries=${graph.entries}');
    stderr.writeln('[debug] reachableFiles=${graph.reachable.length}/${graph.fileIds.length}');
    final unreachable = graph.fileIds.difference(graph.reachable).toList()..sort();
    if (unreachable.isNotEmpty) {
      final sample = unreachable.length > 10 ? unreachable.sublist(0, 10) : unreachable;
      stderr.writeln('[debug] sampleUnused=${sample.join(', ')}${unreachable.length > sample.length ? ' ...' : ''}');
    }
  }

  if (cli.explain != null) {
    final target = _coerceToRelId(cli.explain!, cwd);
    final path = _findPath(graph.entries, graph.edges, target, graph.fileIds);
    if (path != null) {
      stderr.writeln('[explain] $target reachable via ${path.join(' -> ')}');
    } else {
      stderr.writeln('[explain] $target is not reachable from current entries');
    }
  }

  stderr.writeln('[info] Wrote: ${p.relative(depsPath, from: cwd)}');
  stderr.writeln('[info] Wrote: ${p.relative(secPath, from: cwd)}');
  stderr.writeln('[stats] nodes=$total edges=${graph.edges.length} used=$used unused=$unused externals=$externals maxDeg=$maxDeg findings=${(security['findings'] as List).length}');
}

Future<Map<String, ResolvedUnitResult>> _resolveUnits(
  String root, {
  String? sdkPath,
  List<String> sdkSearchPaths = const <String>[],
}) async {
  AnalysisContextCollection collection;
  try {
    collection = AnalysisContextCollection(
      includedPaths: [root],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: sdkPath,
    );
  } on PathNotFoundException catch (e) {
    throw _MissingSdkException(
      _missingSdkMessage(
        attemptedPath: sdkPath,
        searched: sdkSearchPaths,
        failingPath: e.path,
      ),
    );
  }

  final result = <String, ResolvedUnitResult>{};
  for (final context in collection.contexts) {
    final session = context.currentSession;
    final files = context.contextRoot
        .analyzedFiles()
        .where((path) => path.endsWith('.dart'))
        .map(p.normalize);

    for (final file in files) {
      if (!_isWithinRoot(root, file)) continue;
      if (_shouldIgnore(root, file)) continue;
      final resolved = await session.getResolvedUnit(file);
      if (resolved is ResolvedUnitResult) {
        result[file] = resolved;
      }
    }
  }
  return result;
}

class _DependencyGraphResult {
  final List<_Node> nodes;
  final List<_Edge> edges;
  final List<_LibrarySummary> libraries;
  final List<String> entries;
  final Set<String> reachable;
  final Set<String> fileIds;
  final Set<String> autoEntries;

  const _DependencyGraphResult({
    required this.nodes,
    required this.edges,
    required this.libraries,
    required this.entries,
    required this.reachable,
    required this.fileIds,
    required this.autoEntries,
  });
}

Future<_DependencyGraphResult> _buildDependencyGraph(
  String root,
  Map<String, ResolvedUnitResult> units,
  String? packageName,
  Set<String> explicitEntries,
) async {
  final nodes = <String, _Node>{};
  final edges = <_Edge>[];
  final edgeKeys = <String>{};
  final libraries = <_LibrarySummary>[];
  final externalNodes = <String>{};
  final processedLibraries = <String>{};
  final shaCache = <String, String?>{};

  final normalizedUnits = <String, ResolvedUnitResult>{};
  units.forEach((path, unit) {
    normalizedUnits[_canonicalizePathForMap(path)] = unit;
  });

  for (final unit in normalizedUnits.values) {
    final lib = unit.libraryElement;
    if (lib == null || lib.isSynthetic) continue;

    final libSource = _librarySource(lib);
    final libPath = libSource.fullName;
    if (!_isWithinRoot(root, libPath)) continue;

    final libKey = _canonicalizePathForMap(libPath);
    final unitKey = _canonicalizePathForMap(unit.path);
    if (unitKey != libKey) continue;
    if (!processedLibraries.add(libKey)) continue;

    final summary = await _summarizeLibrary(
      root,
      lib,
      unit,
      normalizedUnits,
      nodes,
      edges,
      edgeKeys,
      externalNodes,
      packageName,
      shaCache,
    );
    libraries.add(summary);
  }

  for (final unit in normalizedUnits.values) {
    final absPath = p.normalize(unit.path);
    if (!_isWithinRoot(root, absPath)) continue;
    final relPath = _relativePathWithinRoot(root, absPath);
    await _ensureFileNode(
      nodes,
      absPath,
      relPath,
      unit,
      packageName,
      shaCache,
    );
  }

  if (edges.isEmpty) {
    await _collectEdgesFromAst(
      root,
      normalizedUnits,
      nodes,
      edges,
      edgeKeys,
      externalNodes,
      packageName,
      shaCache,
    );
  }

  final nodeList = nodes.values.toList();
  _computeDegrees(nodeList, edges);

  final fileIds = nodeList.where((n) => n.type == 'file').map((n) => n.id).toSet();
  final autoEntrySet = _discoverEntryFiles(root, libraries, packageName);
  autoEntrySet.removeWhere((id) => !fileIds.contains(id));

  final entrySet = <String>{}..addAll(explicitEntries)..addAll(autoEntrySet);
  entrySet.removeWhere((id) => !fileIds.contains(id));
  final entries = entrySet.toList()..sort();

  final reachable = _reach(entries, edges, fileIds);

  for (final node in nodeList) {
    if (node.type == 'external') {
      node.state = 'used';
      continue;
    }
    if (reachable.contains(node.id)) {
      node.state = 'used';
    } else if (node.inDeg > 0 || node.outDeg > 0) {
      node.state = 'used';
    } else {
      node.state = 'unused';
    }
  }

  return _DependencyGraphResult(
    nodes: nodeList,
    edges: edges,
    libraries: libraries,
    entries: entries,
    reachable: reachable,
    fileIds: fileIds,
    autoEntries: autoEntrySet,
  );
}

Future<_LibrarySummary> _summarizeLibrary(
  String root,
  LibraryElement lib,
  ResolvedUnitResult definingUnit,
  Map<String, ResolvedUnitResult> units,
  Map<String, _Node> nodes,
  List<_Edge> edges,
  Set<String> edgeKeys,
  Set<String> externalNodes,
  String? packageName,
  Map<String, String?> shaCache,
) async {
  final absPath = p.normalize(_librarySource(lib).fullName);
  final relPath = _relativePathWithinRoot(root, absPath);

  await _ensureFileNode(
    nodes,
    absPath,
    relPath,
    definingUnit,
    packageName,
    shaCache,
  );

  final imports = <_ImportExportSummary>[];
  for (final imp in _libraryImports(lib)) {
    final target = imp.importedLibrary;
    String targetId;
    if (target != null) {
      final targetPath = p.normalize(_librarySource(target).fullName);
      if (_isWithinRoot(root, targetPath)) {
        final relTarget = _relativePathWithinRoot(root, targetPath);
        final targetUnit = units[_canonicalizePathForMap(targetPath)];
        await _ensureFileNode(
          nodes,
          targetPath,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'import',
            certainty: 'static');
        targetId = relTarget;
      } else {
        final extId = _externalNodeId(_librarySource(target).uri, imp.uri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'import',
            certainty: 'static');
        targetId = extId;
      }
    } else {
      final resolved = _resolveRelativeUri(absPath, imp.uri);
      if (resolved != null && _isWithinRoot(root, resolved) && File(resolved).existsSync()) {
        final relTarget = _relativePathWithinRoot(root, resolved);
        final targetUnit = units[_canonicalizePathForMap(resolved)];
        await _ensureFileNode(
          nodes,
          resolved,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'import',
            certainty: 'static');
        targetId = relTarget;
      } else {
        final extId = _externalNodeId(null, imp.uri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'import',
            certainty: 'static');
        targetId = extId;
      }
    }

    imports.add(_ImportExportSummary(
      uri: imp.uri,
      target: targetId,
      prefix: imp.prefix?.element.name,
      deferred: imp.isDeferred,
      show: _collectShown(imp.combinators),
      hide: _collectHidden(imp.combinators),
    ));
  }

  final exports = <_ImportExportSummary>[];
  for (final ex in _libraryExports(lib)) {
    final target = ex.exportedLibrary;
    String targetId;
    if (target != null) {
      final targetPath = p.normalize(_librarySource(target).fullName);
      if (_isWithinRoot(root, targetPath)) {
        final relTarget = _relativePathWithinRoot(root, targetPath);
        final targetUnit = units[_canonicalizePathForMap(targetPath)];
        await _ensureFileNode(
          nodes,
          targetPath,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'export',
            certainty: 'static');
        targetId = relTarget;
      } else {
        final extId = _externalNodeId(_librarySource(target).uri, ex.uri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'export',
            certainty: 'static');
        targetId = extId;
      }
    } else {
      final resolved = _resolveRelativeUri(absPath, ex.uri);
      if (resolved != null && _isWithinRoot(root, resolved) && File(resolved).existsSync()) {
        final relTarget = _relativePathWithinRoot(root, resolved);
        final targetUnit = units[_canonicalizePathForMap(resolved)];
        await _ensureFileNode(
          nodes,
          resolved,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'export',
            certainty: 'static');
        targetId = relTarget;
      } else {
        final extId = _externalNodeId(null, ex.uri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'export',
            certainty: 'static');
        targetId = extId;
      }
    }

    exports.add(_ImportExportSummary(
      uri: ex.uri,
      target: targetId,
      prefix: null,
      deferred: false,
      show: _collectShown(ex.combinators),
      hide: _collectHidden(ex.combinators),
    ));
  }

  final parts = <String>{};
  for (final part in _libraryParts(lib)) {
    final source = _partElementSource(part);
    if (source == null) continue;
    final partPath = p.normalize(source.fullName);
    if (!_isWithinRoot(root, partPath)) continue;
    final relPart = _relativePathWithinRoot(root, partPath);
    final partUnit = units[_canonicalizePathForMap(partPath)];
    await _ensureFileNode(
      nodes,
      partPath,
      relPart,
      partUnit,
      packageName,
      shaCache,
    );
    if (parts.add(relPart)) {
      _pushEdge(edges, edgeKeys,
          source: relPath,
          target: relPart,
          kind: 'part',
          certainty: 'static');
      _pushEdge(edges, edgeKeys,
          source: relPart,
          target: relPath,
          kind: 'part-of',
          certainty: 'static');
    }
  }

  final publicApi = _collectPublicApi(lib);

  final libName = lib.name;
  return _LibrarySummary(
    path: relPath,
    libraryName: (libName == null || libName.isEmpty) ? null : libName,
    hasMain: _libraryHasMain(lib, definingUnit, units),
    imports: imports,
    exports: exports,
    parts: parts.toList()..sort(),
    publicApi: publicApi,
  );
}

bool _libraryHasMain(
  LibraryElement lib,
  ResolvedUnitResult definingUnit,
  Map<String, ResolvedUnitResult> units,
) {
  if (lib.entryPoint != null) {
    return true;
  }

  bool unitDeclaresMain(ResolvedUnitResult? unit) {
    if (unit == null) return false;
    for (final declaration in unit.unit.declarations) {
      if (declaration is FunctionDeclaration) {
        final name = declaration.name.lexeme;
        if (name == 'main' && !declaration.isGetter && !declaration.isSetter) {
          return true;
        }
      }
    }
    return false;
  }

  if (unitDeclaresMain(definingUnit)) {
    return true;
  }

  for (final part in _libraryParts(lib)) {
    final source = _partElementSource(part);
    if (source == null) continue;
    final partPath = _canonicalizePathForMap(p.normalize(source.fullName));
    if (unitDeclaresMain(units[partPath])) {
      return true;
    }
  }

  return false;
}

List<String> _collectShown(List<NamespaceCombinator> combinators) {
  final result = <String>[];
  for (final combinator in combinators) {
    if (combinator is ShowElementCombinator) {
      result.addAll(combinator.shownNames);
    }
  }
  return result;
}

List<String> _collectHidden(List<NamespaceCombinator> combinators) {
  final result = <String>[];
  for (final combinator in combinators) {
    if (combinator is HideElementCombinator) {
      result.addAll(combinator.hiddenNames);
    }
  }
  return result;
}

Future<void> _ensureFileNode(
  Map<String, _Node> nodes,
  String absPath,
  String relPath,
  ResolvedUnitResult? unit,
  String? packageName,
  Map<String, String?> shaCache,
) async {
  if (nodes.containsKey(relPath)) return;
  int? loc;
  if (unit != null) {
    loc = _countLoc(unit.content);
  } else if (File(absPath).existsSync()) {
    loc = await _estimateLocFromFile(absPath);
  }
  final sha = await _cachedSha(absPath, shaCache);
  nodes[relPath] = _Node(
    id: relPath,
    type: 'file',
    state: 'unused',
    sizeLOC: loc,
    packageName: packageName,
    sha256: sha,
  );
}

void _ensureExternalNode(
  Map<String, _Node> nodes,
  Set<String> externalNodes,
  String id,
) {
  if (externalNodes.add(id)) {
    nodes[id] = _Node(id: id, type: 'external', state: 'used');
  }
}

void _pushEdge(
  List<_Edge> edges,
  Set<String> edgeKeys, {
  required String source,
  required String target,
  required String kind,
  required String certainty,
}) {
  final key = '$source::$target::$kind::$certainty';
  if (edgeKeys.add(key)) {
    edges.add(_Edge(
      source: source,
      target: target,
      kind: kind,
      certainty: certainty,
    ));
  }
}

Future<void> _collectEdgesFromAst(
  String root,
  Map<String, ResolvedUnitResult> units,
  Map<String, _Node> nodes,
  List<_Edge> edges,
  Set<String> edgeKeys,
  Set<String> externalNodes,
  String? packageName,
  Map<String, String?> shaCache,
) async {
  for (final unit in units.values) {
    final absPath = p.normalize(unit.path);
    if (!_isWithinRoot(root, absPath)) continue;
    final relPath = _relativePathWithinRoot(root, absPath);

    for (final directive in unit.unit.directives.whereType<ImportDirective>()) {
      final importElement = _importDirectiveElement(directive);
      final rawUri = directive.uri.stringValue ?? _importedLibraryUri(importElement);
      final targetLibrary = _importedLibraryFrom(importElement);
      if (targetLibrary != null) {
        final targetPath = p.normalize(_librarySource(targetLibrary).fullName);
        if (_isWithinRoot(root, targetPath)) {
          final relTarget = _relativePathWithinRoot(root, targetPath);
          final targetUnit = units[_canonicalizePathForMap(targetPath)];
          await _ensureFileNode(
            nodes,
            targetPath,
            relTarget,
            targetUnit,
            packageName,
            shaCache,
          );
          _pushEdge(edges, edgeKeys,
              source: relPath,
              target: relTarget,
              kind: 'import',
              certainty: 'static');
        } else {
          final uri = _librarySource(targetLibrary).uri;
          final extId = _externalNodeId(uri, rawUri ?? uri.toString());
          _ensureExternalNode(nodes, externalNodes, extId);
          _pushEdge(edges, edgeKeys,
              source: relPath,
              target: extId,
              kind: 'import',
              certainty: 'static');
        }
        continue;
      }

      if (rawUri == null || rawUri.isEmpty) {
        continue;
      }
      final resolved = _resolveRelativeUri(absPath, rawUri);
      if (resolved != null &&
          _isWithinRoot(root, resolved) &&
          File(resolved).existsSync()) {
        final relTarget = _relativePathWithinRoot(root, resolved);
        final targetUnit = units[_canonicalizePathForMap(resolved)];
        await _ensureFileNode(
          nodes,
          resolved,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'import',
            certainty: 'static');
      } else {
        final extId = _externalNodeId(null, rawUri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'import',
            certainty: 'static');
      }
    }

    for (final directive in unit.unit.directives.whereType<ExportDirective>()) {
      final exportElement = _exportDirectiveElement(directive);
      final rawUri = directive.uri.stringValue ?? _exportedLibraryUri(exportElement);
      final targetLibrary = _exportedLibraryFrom(exportElement);
      if (targetLibrary != null) {
        final targetPath = p.normalize(_librarySource(targetLibrary).fullName);
        if (_isWithinRoot(root, targetPath)) {
          final relTarget = _relativePathWithinRoot(root, targetPath);
          final targetUnit = units[_canonicalizePathForMap(targetPath)];
          await _ensureFileNode(
            nodes,
            targetPath,
            relTarget,
            targetUnit,
            packageName,
            shaCache,
          );
          _pushEdge(edges, edgeKeys,
              source: relPath,
              target: relTarget,
              kind: 'export',
              certainty: 'static');
        } else {
          final uri = _librarySource(targetLibrary).uri;
          final extId = _externalNodeId(uri, rawUri ?? uri.toString());
          _ensureExternalNode(nodes, externalNodes, extId);
          _pushEdge(edges, edgeKeys,
              source: relPath,
              target: extId,
              kind: 'export',
              certainty: 'static');
        }
        continue;
      }

      if (rawUri == null || rawUri.isEmpty) {
        continue;
      }
      final resolved = _resolveRelativeUri(absPath, rawUri);
      if (resolved != null &&
          _isWithinRoot(root, resolved) &&
          File(resolved).existsSync()) {
        final relTarget = _relativePathWithinRoot(root, resolved);
        final targetUnit = units[_canonicalizePathForMap(resolved)];
        await _ensureFileNode(
          nodes,
          resolved,
          relTarget,
          targetUnit,
          packageName,
          shaCache,
        );
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: relTarget,
            kind: 'export',
            certainty: 'static');
      } else {
        final extId = _externalNodeId(null, rawUri);
        _ensureExternalNode(nodes, externalNodes, extId);
        _pushEdge(edges, edgeKeys,
            source: relPath,
            target: extId,
            kind: 'export',
            certainty: 'static');
      }
    }

    for (final directive in unit.unit.directives.whereType<PartDirective>()) {
      final rawUri = directive.uri.stringValue;
      if (rawUri == null || rawUri.isEmpty) {
        continue;
      }
      final resolved = _resolveRelativeUri(absPath, rawUri);
      if (resolved == null ||
          !_isWithinRoot(root, resolved) ||
          !File(resolved).existsSync()) {
        continue;
      }
      final relPart = _relativePathWithinRoot(root, resolved);
      final partUnit = units[_canonicalizePathForMap(resolved)];
      await _ensureFileNode(
        nodes,
        resolved,
        relPart,
        partUnit,
        packageName,
        shaCache,
      );
      _pushEdge(edges, edgeKeys,
          source: relPath,
          target: relPart,
          kind: 'part',
          certainty: 'static');
      _pushEdge(edges, edgeKeys,
          source: relPart,
          target: relPath,
          kind: 'part-of',
          certainty: 'static');
    }

    for (final directive in unit.unit.directives.whereType<PartOfDirective>()) {
      LibraryElement? library = unit.libraryElement;
      final element = _partOfDirectiveElement(directive);
      final resolvedLibrary = _tryGetter(
        () => (element as dynamic).library as LibraryElement?,
      );
      library ??= resolvedLibrary;
      if (library == null) {
        continue;
      }
      final libraryPath = p.normalize(_librarySource(library).fullName);
      if (!_isWithinRoot(root, libraryPath)) {
        continue;
      }
      final relLibrary = _relativePathWithinRoot(root, libraryPath);
      final libraryUnit = units[_canonicalizePathForMap(libraryPath)];
      await _ensureFileNode(
        nodes,
        libraryPath,
        relLibrary,
        libraryUnit,
        packageName,
        shaCache,
      );
      _pushEdge(edges, edgeKeys,
          source: relLibrary,
          target: relPath,
          kind: 'part',
          certainty: 'static');
      _pushEdge(edges, edgeKeys,
          source: relPath,
          target: relLibrary,
          kind: 'part-of',
          certainty: 'static');
    }
  }
}

dynamic _cloneJsonLike(dynamic value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((key, val) {
      if (key == null) return;
      result[key.toString()] = _cloneJsonLike(val);
    });
    return result;
  }
  if (value is List) {
    return value.map(_cloneJsonLike).toList();
  }
  return value;
}

String? _resolveRelativeUri(String fromPath, String uri) {
  try {
    final base = Uri.file(fromPath);
    final resolved = base.resolveUri(Uri.parse(uri));
    if (resolved.scheme == 'file') {
      return p.normalize(resolved.toFilePath());
    }
  } catch (_) {}
  return null;
}

String _externalNodeId(Uri? uri, String raw) {
  String? _pubIdFromUri(Uri? candidate) {
    if (candidate == null) return null;
    if (candidate.scheme != 'package') return null;
    if (candidate.pathSegments.isNotEmpty) {
      return 'pub:${candidate.pathSegments.first}';
    }
    final path = candidate.path;
    if (path.isNotEmpty) {
      final slash = path.indexOf('/');
      final pkg = slash >= 0 ? path.substring(0, slash) : path;
      if (pkg.isNotEmpty) {
        return 'pub:$pkg';
      }
    }
    return null;
  }

  if (uri == null) {
    if (raw.startsWith('dart:')) {
      return raw;
    }
    if (raw.startsWith('package:')) {
      final parsed = Uri.tryParse(raw);
      final pubId = _pubIdFromUri(parsed);
      if (pubId != null) {
        return pubId;
      }
      final remainder = raw.substring('package:'.length);
      final slash = remainder.indexOf('/');
      final pkg = slash >= 0 ? remainder.substring(0, slash) : remainder;
      if (pkg.isNotEmpty) {
        return 'pub:$pkg';
      }
      if (remainder.isNotEmpty) {
        return 'pub:$remainder';
      }
      return 'external:$raw';
    }
    return 'external:$raw';
  }
  if (uri.scheme == 'dart') {
    return 'dart:${uri.path}';
  }
  if (uri.scheme == 'package') {
    final pubId = _pubIdFromUri(uri);
    if (pubId != null) {
      return pubId;
    }
  }
  if (uri.scheme.isEmpty) {
    return raw;
  }
  return uri.toString();
}

int _countLoc(String content) {
  return content.split('\n').where((line) => line.trim().isNotEmpty).length;
}

Future<int?> _estimateLocFromFile(String path) async {
  try {
    final text = await File(path).readAsString();
    return _countLoc(text);
  } catch (_) {
    return null;
  }
}

Future<String?> _cachedSha(String path, Map<String, String?> cache) async {
  if (cache.containsKey(path)) {
    return cache[path];
  }
  final sha = await fileSha256(path);
  cache[path] = sha;
  return sha;
}

Set<String> _discoverEntryFiles(String root, List<_LibrarySummary> libraries, String? packageName) {
  final entries = <String>{};
  for (final lib in libraries) {
    if (lib.hasMain) {
      entries.add(lib.path);
    }
  }

  final common = [
    p.join('bin', 'main.dart'),
    p.join('lib', 'main.dart'),
    p.join('web', 'main.dart'),
    p.join('tool', 'main.dart'),
    p.join('example', 'main.dart'),
    p.join('test', 'main.dart'),
    p.join('lib', 'src', 'main.dart'),
  ];

  for (final rel in common) {
    final abs = p.join(root, rel);
    if (File(abs).existsSync()) {
      entries.add(_relativePathWithinRoot(root, abs));
    }
  }

  if (packageName != null && packageName.isNotEmpty) {
    final normalized = packageName.replaceAll('-', '_');
    final candidates = [
      p.join(root, 'lib', '$normalized.dart'),
      p.join(root, 'lib', '$packageName.dart'),
    ];
    for (final abs in candidates) {
      if (File(abs).existsSync()) {
        entries.add(_relativePathWithinRoot(root, abs));
      }
    }
  }

  return entries;
}

void _computeDegrees(List<_Node> nodes, List<_Edge> edges) {
  final byId = {for (final node in nodes) node.id: node};
  for (final node in nodes) {
    node.inDeg = 0;
    node.outDeg = 0;
  }
  for (final edge in edges) {
    final source = byId[edge.source];
    final target = byId[edge.target];
    if (source != null) {
      source.outDeg++;
    }
    if (target != null) {
      target.inDeg++;
    }
  }
}

Set<String> _reach(List<String> entries, List<_Edge> edges, Set<String> fileIds) {
  if (entries.isEmpty) return <String>{};
  final out = <String, List<String>>{};
  for (final edge in edges) {
    if (!fileIds.contains(edge.source)) continue;
    if (!fileIds.contains(edge.target)) continue;
    out.putIfAbsent(edge.source, () => []).add(edge.target);
  }
  final seen = <String>{};
  final stack = <String>[]..addAll(entries);
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (!seen.add(current)) continue;
    final next = out[current];
    if (next == null) continue;
    for (final target in next) {
      stack.add(target);
    }
  }
  return seen;
}

List<String>? _findPath(
  List<String> entries,
  List<_Edge> edges,
  String target,
  Set<String> fileIds,
) {
  if (entries.isEmpty) return null;
  final queue = <List<String>>[];
  final seen = <String>{};
  final out = <String, List<String>>{};
  for (final edge in edges) {
    if (!fileIds.contains(edge.source) || !fileIds.contains(edge.target)) continue;
    out.putIfAbsent(edge.source, () => []).add(edge.target);
  }
  for (final entry in entries) {
    queue.add([entry]);
    seen.add(entry);
  }
  while (queue.isNotEmpty) {
    final path = queue.removeAt(0);
    final node = path.last;
    if (node == target) return path;
    final next = out[node];
    if (next == null) continue;
    for (final candidate in next) {
      if (seen.add(candidate)) {
        final newPath = List<String>.from(path)..add(candidate);
        queue.add(newPath);
      }
    }
  }
  return null;
}

Future<void> _writeJson(String path, Map<String, dynamic> data) async {
  final file = File(path);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

Set<String> _normalizeEntryArgs(List<String> args, String root) {
  final entries = <String>{};
  for (final arg in args) {
    final abs = p.normalize(p.isAbsolute(arg) ? arg : p.join(root, arg));
    if (File(abs).existsSync()) {
      entries.add(_relativePathWithinRoot(root, abs));
    }
  }
  return entries;
}

String _coerceToRelId(String input, String root) {
  final absolute = p.normalize(p.isAbsolute(input) ? input : p.join(root, input));
  if (File(absolute).existsSync()) {
    return _relativePathWithinRoot(root, absolute);
  }
  return input.replaceAll('\\', '/');
}

Future<String?> _readPackageName(String root) async {
  final file = File(p.join(root, 'pubspec.yaml'));
  if (!await file.exists()) return null;
  try {
    final lines = await file.readAsLines();
    for (var raw in lines) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final hashIndex = line.indexOf('#');
      if (hashIndex >= 0) {
        line = line.substring(0, hashIndex).trim();
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim();
      if (key != 'name') continue;
      var value = line.substring(colon + 1).trim();
      if (value.isEmpty) continue;
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        if (value.length <= 2) continue;
        value = value.substring(1, value.length - 1).trim();
      }
      if (value.isNotEmpty) {
        return value;
      }
    }
  } catch (_) {}
  return null;
}

const Set<String> _ignoredDirs = {
  '.dart_tool',
  '.git',
  '.idea',
  '.vscode',
  '.cache',
  'build',
  'dist',
  'node_modules',
  'out',
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
};

bool _isWithinRoot(String root, String candidate) {
  final canonicalRoot = _canonicalizePathForMap(root);
  final canonicalCandidate = _canonicalizePathForMap(candidate);
  if (canonicalCandidate == canonicalRoot) {
    return true;
  }
  final separator = Platform.isWindows ? '\\' : '/';
  final prefix = canonicalRoot.endsWith(separator)
      ? canonicalRoot
      : '$canonicalRoot$separator';
  return canonicalCandidate.startsWith(prefix);
}

bool _shouldIgnore(String root, String path) {
  final rel = _relativePathWithinRoot(root, path);
  final segments = p.split(rel);
  return segments.any(_ignoredDirs.contains);
}

class _Node {
  final String id;
  final String type;
  String state;
  final String lang;
  final int? sizeLOC;
  final String? packageName;
  final String? sha256;
  int inDeg;
  int outDeg;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.packageName,
    this.sha256,
    this.lang = 'dart',
    this.inDeg = 0,
    this.outDeg = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (packageName != null) 'package': packageName,
        'inDeg': inDeg,
        'outDeg': outDeg,
        if (sha256 != null) 'sha256': sha256,
      };
}

class _Edge {
  final String source;
  final String target;
  final String kind;
  final String certainty;

  _Edge({
    required this.source,
    required this.target,
    required this.kind,
    required this.certainty,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _ImportExportSummary {
  final String uri;
  final String target;
  final String? prefix;
  final bool deferred;
  final List<String> show;
  final List<String> hide;

  const _ImportExportSummary({
    required this.uri,
    required this.target,
    this.prefix,
    required this.deferred,
    required this.show,
    required this.hide,
  });

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'target': target,
        if (prefix != null) 'prefix': prefix,
        if (deferred) 'deferred': deferred,
        if (show.isNotEmpty) 'show': show,
        if (hide.isNotEmpty) 'hide': hide,
      };
}

class _LibrarySummary {
  final String path;
  final String? libraryName;
  final bool hasMain;
  final List<_ImportExportSummary> imports;
  final List<_ImportExportSummary> exports;
  final List<String> parts;
  final Map<String, dynamic> publicApi;

  const _LibrarySummary({
    required this.path,
    required this.libraryName,
    required this.hasMain,
    required this.imports,
    required this.exports,
    required this.parts,
    required this.publicApi,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        if (libraryName != null && libraryName!.isNotEmpty) 'library': libraryName,
        'isEntry': hasMain,
        'imports': imports.map((i) => i.toJson()).toList(),
        'exports': exports.map((e) => e.toJson()).toList(),
        if (parts.isNotEmpty) 'parts': parts,
        'publicApi': publicApi,
      };
}

Map<String, dynamic> _collectPublicApi(LibraryElement lib) {
  final classes = <Map<String, dynamic>>[];
  final functions = <Map<String, String>>[];
  final typedefs = <Map<String, String>>[];
  final extensions = <Map<String, String>>[];
  final variables = <Map<String, String>>[];

  final namespace = lib.exportNamespace;
  for (final element in _namespaceElements(namespace).values) {
    if (!element.isPublic) continue;

    if (element is InterfaceElement) {
      final kind = element is EnumElement
          ? 'enum'
          : element is MixinElement
              ? 'mixin'
              : 'class';
      final members = <String>[];
      for (final field in element.fields) {
        if (!field.isPublic || field.isSynthetic) continue;
        members.add('${field.type.getDisplayString(withNullability: true)} ${field.name}');
      }
      for (final method in element.methods) {
        if (!method.isPublic || method.isSynthetic) continue;
        members.add(_elementDisplay(method));
      }
      for (final ctor in element.constructors) {
        if (!ctor.isPublic || ctor.isSynthetic) continue;
        members.add(_elementDisplay(ctor));
      }
      final classEntry = <String, dynamic>{
        'name': element.name ?? element.displayName,
        'kind': kind,
      };
      if (members.isNotEmpty) {
        members.sort();
        classEntry['members'] = members;
      }
      classes.add(classEntry);
      continue;
    }

    if (element is ExecutableElement && element.kind == ElementKind.FUNCTION) {
      final name = element.name ?? element.displayName;
      functions.add({
        'name': name,
        'signature': _elementDisplay(element),
      });
      continue;
    }

    if (element is TypeAliasElement) {
      final name = element.name ?? element.displayName;
      typedefs.add({
        'name': name,
        'aliasedType': element.aliasedType.getDisplayString(withNullability: true),
      });
      continue;
    }

    if (element is ExtensionElement) {
      final name = element.name;
      extensions.add({
        'name': (name == null || name.isEmpty) ? element.displayName : name,
        'on': element.extendedType.getDisplayString(withNullability: true),
      });
      continue;
    }

    if (element is TopLevelVariableElement) {
      if (element.isSynthetic) continue;
      final name = element.name ?? element.displayName;
      variables.add({
        'name': name,
        'type': element.type.getDisplayString(withNullability: true),
      });
      continue;
    }
  }

  classes.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  functions.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  typedefs.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  extensions.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  variables.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  return {
    'classes': classes,
    'functions': functions,
    'typedefs': typedefs,
    'extensions': extensions,
    'variables': variables,
  };
}

Future<Map<String, dynamic>> _runSecurity(
  String root,
  Map<String, ResolvedUnitResult> units,
) async {
  final findings = <_SecurityFinding>[];
  for (final entry in units.entries) {
    final path = entry.key;
    if (!_isWithinRoot(root, path)) continue;
    if (_shouldIgnore(root, path)) continue;

    final rel = _relativePathWithinRoot(root, path);
    final unit = entry.value;
    final collector = _SecurityCollector(rel, unit.content, unit.lineInfo);

    unit.unit.accept(_SecurityVisitor(collector));

    for (final directive in unit.unit.directives) {
      if (directive is ImportDirective) {
        final uri = directive.uri.stringValue;
        if (uri == 'dart:mirrors') {
          collector.addNode(
            'dart.mirrors.use',
            'low',
            'Importing dart:mirrors is discouraged and unsupported on many runtimes.',
            directive,
          );
        }
      }
    }

    _scanSecretPatterns(collector, unit.content);

    findings.addAll(collector.findings);
  }

  final summary = <String, int>{};
  for (final finding in findings) {
    summary[finding.severity] = (summary[finding.severity] ?? 0) + 1;
  }

  return {
    'findings': findings.map((f) => f.toJson()).toList(),
    'summary': summary,
  };
}

class _SecurityCollector {
  final String file;
  final String content;
  final LineInfo lineInfo;
  final List<_SecurityFinding> findings = [];
  final Set<String> _seen = {};

  _SecurityCollector(this.file, this.content, this.lineInfo);

  void addNode(String ruleId, String severity, String message, AstNode node) {
    add(ruleId, severity, message, node.offset, node.end);
  }

  void add(String ruleId, String severity, String message, int start, int end) {
    final key = '$ruleId@$start@$end';
    if (!_seen.add(key)) return;
    final location = lineInfo.getLocation(start);
    findings.add(_SecurityFinding(
      ruleId: ruleId,
      severity: severity,
      message: message,
      file: file,
      line: location.lineNumber,
      column: location.columnNumber,
      snippet: _snippet(content, start, end),
    ));
  }
}

class _SecurityFinding {
  final String ruleId;
  final String severity;
  final String message;
  final String file;
  final int line;
  final int column;
  final String snippet;

  const _SecurityFinding({
    required this.ruleId,
    required this.severity,
    required this.message,
    required this.file,
    required this.line,
    required this.column,
    required this.snippet,
  });

  Map<String, dynamic> toJson() => {
        'ruleId': ruleId,
        'id': ruleId,
        'severity': severity,
        'message': message,
        'file': file,
        'line': line,
        'col': column,
        'snippet': snippet,
      };
}

class _SecurityVisitor extends RecursiveAstVisitor<void> {
  final _SecurityCollector collector;

  _SecurityVisitor(this.collector);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = _resolvedElement(node.methodName);
    if (element is MethodElement) {
      final libraryUri = _libraryUri(element.library);
      final enclosing = element.enclosingElement?.name;
      if (libraryUri == 'dart:io' && enclosing == 'Process') {
        if (element.name == 'run' || element.name == 'start') {
          final shell = _namedBoolArg(node.argumentList.arguments, 'runInShell') == true;
          if (shell) {
            collector.addNode(
              'dart.process.run.shell',
              'high',
              'Process.${element.name} with runInShell:true can allow command injection.',
              node,
            );
          } else {
            collector.addNode(
              'dart.process.run',
              'medium',
              'Process.${element.name} executes external commands.',
              node,
            );
          }
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final resolved = _resolvedElement(node.constructorName);
    final constructor = resolved is ConstructorElement ? resolved : null;
    if (constructor != null) {
      final enclosing = constructor.enclosingElement;
      final libraryUri = _libraryUri(enclosing?.library);
      if (enclosing?.name == 'Random' && libraryUri == 'dart:math') {
        if (node.constructorName.name == null) {
          collector.addNode(
            'dart.random.insecure',
            'medium',
            'Random() is not cryptographically secure. Use Random.secure() or a crypto RNG.',
            node,
          );
        }
      }
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final writeElement = node.writeElement;
    if (writeElement is PropertyAccessorElement) {
      final variable = writeElement.variable;
      final libraryUri = _libraryUri(variable.library);
      if (variable.name == 'badCertificateCallback' && libraryUri == 'dart:io') {
        collector.addNode(
          'dart.http.badcert',
          'high',
          'Setting HttpClient.badCertificateCallback disables TLS certificate validation.',
          node,
        );
      }
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = _resolvedElement(node);
    final libraryUri = _elementLibraryUri(element);
    if (node.prefix.name == 'Platform' && node.identifier.name == 'environment' && libraryUri == 'dart:io') {
      collector.addNode(
        'dart.platform.env',
        'info',
        'Platform.environment can expose sensitive environment variables.',
        node,
      );
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final element = _resolvedElement(node.propertyName);
    final libraryUri = _elementLibraryUri(element);
    if (node.target is Identifier) {
      final targetName = (node.target as Identifier).name;
      if (targetName == 'Platform' && node.propertyName.name == 'environment' && libraryUri == 'dart:io') {
        collector.addNode(
          'dart.platform.env',
          'info',
          'Platform.environment can expose sensitive environment variables.',
          node,
        );
      }
    }
    super.visitPropertyAccess(node);
  }
}

class _SecretPattern {
  final RegExp pattern;
  final String ruleId;
  final String severity;
  final String message;
  final bool reportWhenSanitizedBlank;

  const _SecretPattern({
    required this.pattern,
    required this.ruleId,
    required this.severity,
    required this.message,
    this.reportWhenSanitizedBlank = false,
  });
}

final List<_SecretPattern> _secretPatterns = [
  _SecretPattern(
    pattern: RegExp(r'AKIA[0-9A-Z]{16}'),
    ruleId: 'dart.secret.aws-access-key',
    severity: 'high',
    message: 'Possible AWS access key detected.',
    reportWhenSanitizedBlank: true,
  ),
  _SecretPattern(
    pattern: RegExp(r'xox[baprs]-[0-9A-Za-z-]{10,48}'),
    ruleId: 'dart.secret.slack-token',
    severity: 'high',
    message: 'Possible Slack token detected.',
    reportWhenSanitizedBlank: true,
  ),
  _SecretPattern(
    pattern: RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
    ruleId: 'dart.secret.jwt',
    severity: 'high',
    message: 'String looks like a JWT token.',
    reportWhenSanitizedBlank: true,
  ),
  _SecretPattern(
    pattern: RegExp(r'-----BEGIN (?:RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----'),
    ruleId: 'dart.secret.private-key',
    severity: 'high',
    message: 'Private key material detected.',
    reportWhenSanitizedBlank: true,
  ),
  _SecretPattern(
    pattern: RegExp('http://[^\\s\'"]+'),
    ruleId: 'dart.http.http-url',
    severity: 'medium',
    message: 'HTTP URL detected. Prefer HTTPS to avoid clear-text traffic.',
    reportWhenSanitizedBlank: true,
  ),
];

void _scanSecretPatterns(_SecurityCollector collector, String content) {
  final sanitized = _stripStringsAndComments(content);
  for (final pattern in _secretPatterns) {
    for (final match in pattern.pattern.allMatches(content)) {
      final start = match.start;
      final end = match.end;
      final sanitizedSlice = sanitized.substring(start, end);
      if (sanitizedSlice.trim().isEmpty && !pattern.reportWhenSanitizedBlank) {
        continue;
      }
      collector.add(pattern.ruleId, pattern.severity, pattern.message, start, end);
    }
  }
}

String _stripStringsAndComments(String input) {
  final codes = input.codeUnits;
  final sanitized = List<int>.from(codes);
  final length = codes.length;
  var i = 0;
  while (i < length) {
    final c = codes[i];
    if (c == 47 && i + 1 < length) {
      final next = codes[i + 1];
      if (next == 47) {
        var j = i;
        while (j < length && codes[j] != 10) {
          sanitized[j] = 32;
          j++;
        }
        i = j;
        continue;
      }
      if (next == 42) {
        var j = i + 2;
        while (j + 1 < length && !(codes[j] == 42 && codes[j + 1] == 47)) {
          sanitized[j] = 32;
          j++;
        }
        if (j + 1 < length) {
          sanitized[i] = sanitized[i + 1] = 32;
          sanitized[j] = sanitized[j + 1] = 32;
          j += 2;
          i = j;
        } else {
          for (var k = i; k < length; k++) {
            sanitized[k] = 32;
          }
          break;
        }
        continue;
      }
    }
    if (c == 39 || c == 34) {
      final quote = c;
      var j = i + 1;
      var triple = false;
      if (j + 1 < length && codes[j] == quote && codes[j + 1] == quote) {
        triple = true;
        sanitized[j] = sanitized[j + 1] = 32;
        j += 2;
      }
      sanitized[i] = 32;
      while (j < length) {
        sanitized[j] = 32;
        if (!triple) {
          if (codes[j] == quote && (j == i + 1 || codes[j - 1] != 92)) {
            break;
          }
          if (codes[j] == 92 && j + 1 < length) {
            sanitized[j + 1] = 32;
            j += 2;
            continue;
          }
          j++;
        } else {
          if (codes[j] == quote &&
              j + 2 < length &&
              codes[j + 1] == quote &&
              codes[j + 2] == quote) {
            sanitized[j + 1] = 32;
            sanitized[j + 2] = 32;
            j += 2;
            break;
          }
          j++;
        }
      }
      if (j < length) {
        sanitized[j] = 32;
      }
      i = j + 1;
      continue;
    }
    i++;
  }
  return String.fromCharCodes(sanitized);
}

String _snippet(String content, int start, int end, {int maxLength = 200}) {
  if (start < 0 || start >= content.length) return '';
  final safeEnd = end < 0
      ? 0
      : (end > content.length
          ? content.length
          : end);
  var snippet = content.substring(start, safeEnd);
  snippet = snippet.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (snippet.length > maxLength) {
    snippet = snippet.substring(0, maxLength) + '...';
  }
  return snippet;
}

bool? _namedBoolArg(NodeList<Expression> args, String name) {
  for (final arg in args) {
    if (arg is NamedExpression && arg.name.label.name == name) {
      final expression = arg.expression;
      if (expression is BooleanLiteral) {
        return expression.value;
      }
    }
  }
  return null;
}

// dartDependency.dart — V0 Dart dependency crawler (no external packages)
// Produces: dartDependencies.json in the current working directory.
//
// What it does:
// - Recursively scans for *.dart (skips .dart_tool, build, ios/android platform dirs, etc).
// - Parses directives: import/export/part (basic regex; ignores comments).
// - Detects entries: any file with `main(...)` + common paths (bin/main.dart, lib/main.dart).
// - Resolves URIs:
//     * Relative ("./", "../") -> real file under repo
//     * package:<self>/<path>  -> <cwd>/lib/<path> (internal, using pubspec.yaml name)
//     * package:<other>/<...>  -> external node "pub:<other>"
//     * dart:<lib>             -> external node "dart:<lib>"
// - Builds edges (kind: import|export|part), computes degrees and reachability -> state used/unused.
//
// Limitations (V0):
// - Does not evaluate conditional imports, deferred/as, or mirrors. They’re treated as normal imports.
// - `part of` resolution to its library file is not guaranteed; we record edges for `part` directives from
//   library file to part file. (You can add `library`/`part of` linking later if needed.)
// - Mixed Flutter/web/server projects work fine; entry detection relies on `main()` + common roots.
//
// Build:
//   dart compile exe .\dartDependency.dart -o .\dartDependency.exe
// Run:
//   .\dartDependency.exe   # writes dartDependencies.json

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _normalize(String p) {
  var x = p;
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(x)) {
    x = '$x\\';
  }
  return Uri.file(x, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _rel(String target, String from) {
  final T = _normalize(_abs(target));
  final F = _normalize(_abs(from));
  if (T == F) return '.';
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T; // fallback absolute
}
bool _isWithinRepo(String target, String root) {
  final T = _normalize(_abs(target));
  final R = _normalize(_abs(root));
  return T == R || T.startsWith(R + _sep);
}
String _join(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final s = a.endsWith(_sep) ? a.substring(0, a.length - 1) : a;
  final t = b.startsWith(_sep) ? b.substring(1) : b;
  return '$s$_sep$t';
}
String _dir(String p) {
  final s = p.replaceAll('\\', '/');
  final i = s.lastIndexOf('/');
  if (i < 0) return Platform.isWindows ? '${p.substring(0, 2)}\\' : '/';
  var d = p.substring(0, i);
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(d)) d = '$d\\';
  return d;
}
String _base(String p) {
  final s = p.replaceAll('\\', '/');
  final i = s.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}
String _ext(String p) {
  final b = _base(p);
  final dot = b.lastIndexOf('.');
  return dot <= 0 ? '' : b.substring(dot);
}

// ---------------- models ----------------
class _Node {
  String id;            // repo-relative file path for files; external id for externals
  String type;          // file | external
  String state;         // used | unused
  String lang = 'dart';
  int? sizeLOC;
  String? packageName;  // from pubspec.yaml (for local files)
  int inDeg = 0;
  int outDeg = 0;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.packageName,
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
      };
}

class _Edge {
  final String source;   // file id (relative path)
  final String target;   // file id (relative path) OR external id
  final String kind;     // 'import' | 'export' | 'part'
  final String certainty; // 'static'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _Directive {
  final String kind; // import | export | part
  final String uri;
  _Directive(this.kind, this.uri);
}

class _FileFacts {
  final String absPath;
  final String relId;
  final List<_Directive> directives;
  final bool hasMain;
  _FileFacts(this.absPath, this.relId, this.directives, this.hasMain);
}

// ---------------- main ----------------
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) Discover project info
  final pub = await _readPubspec(cwd); // get self package name if any
  final localPackages = await _readPackageConfig(cwd);

  // 2) Collect Dart files
  final files = await _collectDartFiles(cwd);

  // 3) Parse facts
  final facts = <_FileFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractFacts(cwd, f, text));
  }

  // 4) Build edges and externals
  final edges = <_Edge>[];
  final externals = <String>{};
  final referencedFileAbs = <String, String>{};

  for (final ff in facts) {
    for (final d in ff.directives) {
      final resolved = _resolveUri(cwd, ff.absPath, d.uri, pub?.name, localPackages);
      if (resolved.type == 'file' && resolved.path != null) {
        final relTarget = _rel(resolved.path!, cwd);
        referencedFileAbs.putIfAbsent(relTarget, () => resolved.path!);
        edges.add(_Edge(
          source: ff.relId,
          target: relTarget,
          kind: d.kind,
          certainty: 'static',
        ));
      } else if (resolved.type == 'external' && resolved.extId != null) {
        externals.add(resolved.extId!);
        edges.add(_Edge(
          source: ff.relId,
          target: resolved.extId!,
          kind: d.kind,
          certainty: 'static',
        ));
      }
    }
  }

  // 5) Nodes (files + externals)
  final nodes = <_Node>[];
  final existingIds = <String>{};
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused', // provisional; set by reachability
      sizeLOC: await _estimateLOC(ff.absPath),
      packageName: pub?.name,
    ));
    existingIds.add(ff.relId);
  }

  for (final entry in referencedFileAbs.entries) {
    if (existingIds.contains(entry.key)) continue;
    nodes.add(_Node(
      id: entry.key,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(entry.value),
    ));
    existingIds.add(entry.key);
  }
  for (final ext in externals) {
    nodes.add(_Node(id: ext, type: 'external', state: 'used'));
  }

  // 6) Degrees
  _computeDegrees(nodes, edges);

  // 7) Entry files
  final entries = _discoverEntryFiles(cwd, facts);

  // 8) Reachability
  final usedSet = _reach(entries, edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 9) Write output
  final outPath = _join(cwd, 'dartDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));

  // 10) Stats
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[info] Wrote: ${_rel(outPath, cwd)}');
  stderr.writeln('[stats] nodes=$total edges=${edges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// ---------------- crawl ----------------
Future<List<String>> _collectDartFiles(String root) async {
  final ignoreDirs = <String>{
    '.dart_tool','build','node_modules','dist','out','.git','.idea','.vscode','.cache','android','ios','macos','linux','windows'
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final rel = _rel(sp, root);
    final parts = rel.split(_sep);
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp) == '.dart') result.add(_normalize(sp));
  }
  return result;
}

// ---------------- parse .dart ----------------
_FileFacts _extractFacts(String cwd, String fileAbs, String text) {
  // Drop block comments /* */ and doc comments ///? Keep simple; remove /*...*/ and triple-slash style lines via regex
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = noBlock.split('\n');

  final directives = <_Directive>[];
  bool hasMain = false;

  // import '...';  export '...';  part '...';
  final reImport = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
  final reExport = RegExp(r'''^\s*export\s+['"]([^'"]+)['"]''');
  final rePart   = RegExp(r'''^\s*part\s+['"]([^'"]+)['"]''');
  // main(): allow void main(), Future<void> main(), or parameterized
  final reMain = RegExp(r'^\s*(?:Future\s*<\s*void\s*>\s+)?void\s+main\s*\(');

  for (var raw in lines) {
    final line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final m1 = reImport.firstMatch(line);
    if (m1 != null) { directives.add(_Directive('import', m1.group(1)!)); continue; }

    final m2 = reExport.firstMatch(line);
    if (m2 != null) { directives.add(_Directive('export', m2.group(1)!)); continue; }

    final m3 = rePart.firstMatch(line);
    if (m3 != null) { directives.add(_Directive('part', m3.group(1)!)); continue; }

    if (!hasMain && reMain.hasMatch(line)) hasMain = true;
  }

  return _FileFacts(fileAbs, _rel(fileAbs, cwd), directives, hasMain);
}

// ---------------- pubspec ----------------
class _Pubspec { final String name; _Pubspec(this.name); }
Future<_Pubspec?> _readPubspec(String cwd) async {
  final f = File(_join(cwd, 'pubspec.yaml'));
  if (!await f.exists()) return null;
  try {
    final s = await f.readAsString();
    final m = RegExp(r'^\s*name\s*:\s*([A-Za-z0-9_\-]+)\s*$', multiLine: true).firstMatch(s);
    if (m != null) return _Pubspec(m.group(1)!);
  } catch (_) {}
  return null;
}

Future<Map<String, String>> _readPackageConfig(String cwd) async {
  final result = <String, String>{};
  final configPath = _join(cwd, '.dart_tool${_sep}package_config.json');
  final file = File(configPath);
  if (!await file.exists()) return result;
  try {
    final text = await file.readAsString();
    final data = jsonDecode(text);
    if (data is Map && data['packages'] is List) {
      final packages = data['packages'] as List;
      final configDir = _dir(configPath);
      final configUri = Uri.directory(configDir, windows: Platform.isWindows);
      for (final entry in packages) {
        if (entry is! Map) continue;
        final name = entry['name'];
        final rootUriRaw = entry['rootUri'];
        final packageUriRaw = entry['packageUri'];
        if (name is! String) continue;
        final rootUri = rootUriRaw is String
            ? configUri.resolve(rootUriRaw)
            : configUri;
        final packageUri = packageUriRaw is String
            ? rootUri.resolve(packageUriRaw)
            : rootUri;
        final basePath = _normalize(packageUri.toFilePath(windows: Platform.isWindows));
        if (_isWithinRepo(basePath, cwd)) {
          result[name] = basePath;
        }
      }
    }
  } catch (_) {}
  return result;
}

// ---------------- resolve URIs ----------------
class _Resolved {
  final String type;  // 'file' | 'external'
  final String? path; // absolute file path if type=file
  final String? extId; // external id
  _Resolved.file(this.path) : type = 'file', extId = null;
  _Resolved.external(this.extId) : type = 'external', path = null;
}

bool _isLikelyRelativeImport(String uri) {
  if (uri.startsWith('./') || uri.startsWith('../')) return true;
  if (uri.startsWith('/') || uri.startsWith('\\')) return false;
  if (uri.contains('://')) return false;
  if (uri.contains(':')) return false;
  return true;
}

_Resolved _resolveUri(String cwd, String fromFileAbs, String uri, String? selfPkg,
    Map<String, String> localPackages) {
  // dart:core, dart:io ...
  if (uri.startsWith('dart:')) {
    final name = uri.substring('dart:'.length);
    return _Resolved.external('dart:$name');
  }

  // package:foo/path.dart
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length); // foo/path.dart
    final slash = rest.indexOf('/');
    final pkg = slash >= 0 ? rest.substring(0, slash) : rest;
    final sub = slash >= 0 ? rest.substring(slash + 1) : '';
    if (selfPkg != null && pkg == selfPkg) {
      // Resolve to ./lib/<sub>
      final abs = _normalize(_join(cwd, _join('lib', sub.replaceAll('/', _sep))));
      if (File(abs).existsSync() || _isWithinRepo(abs, cwd)) return _Resolved.file(abs);
      // If not present, treat as external (perhaps build step)
    }
    final localBase = localPackages[pkg];
    if (localBase != null) {
      final abs = _normalize(_join(localBase, sub.replaceAll('/', _sep)));
      if (File(abs).existsSync() || _isWithinRepo(abs, cwd)) return _Resolved.file(abs);
    }
    return _Resolved.external('pub:$pkg');
  }

  // Relative URI: './', '../', or bare paths like 'src/foo.dart'
  if (_isLikelyRelativeImport(uri)) {
    final baseDir = _dir(fromFileAbs);
    final candidate = uri.replaceAll('/', _sep).replaceAll('\\', _sep);
    final abs = _normalize(_join(baseDir, candidate));
    if (File(abs).existsSync() || _isWithinRepo(abs, cwd)) return _Resolved.file(abs);
    return _Resolved.external('pub:unknown'); // fallback (should be rare)
  }

  // Absolute file path (unlikely in Dart imports) — try to normalize
  if (uri.contains(':') || uri.startsWith(_sep)) {
    final abs = _normalize(uri);
    if (File(abs).existsSync() || _isWithinRepo(abs, cwd)) return _Resolved.file(abs);
    return _Resolved.external('pub:unknown');
  }

  // Bare library names (uncommon) -> external
  return _Resolved.external('pub:$uri');
}

// ---------------- entries ----------------
List<String> _discoverEntryFiles(String cwd, List<_FileFacts> facts) {
  final entries = <String>{};

  // (a) Any file with `main(...)`
  for (final ff in facts) {
    if (ff.hasMain) entries.add(ff.relId);
  }

  // (b) Common paths
  final common = [
    _join(cwd, 'bin${_sep}main.dart'),
    _join(cwd, 'lib${_sep}main.dart'),
    _join(cwd, 'web${_sep}main.dart'),
    _join(cwd, 'tool${_sep}main.dart'),
    _join(cwd, 'example${_sep}main.dart'),
    _join(cwd, 'test${_sep}main.dart'), // sometimes integration test runs a main
    _join(cwd, 'lib${_sep}src${_sep}main.dart'),
  ];
  for (final p in common) {
    if (File(p).existsSync()) entries.add(_rel(p, cwd));
  }

  return entries.toList();
}

// ---------------- graph utils ----------------
void _computeDegrees(List<_Node> nodes, List<_Edge> edges) {
  final byId = {for (final n in nodes) n.id: n};
  for (final n in nodes) { n.inDeg = 0; n.outDeg = 0; }
  for (final e in edges) {
    byId[e.source]?.outDeg++;
    byId[e.target]?.inDeg++;
  }
}

Set<String> _reach(List<String> entries, List<_Edge> edges) {
  final gOut = <String, List<String>>{};
  for (final e in edges) {
    gOut.putIfAbsent(e.source, () => []).add(e.target);
  }
  final seen = <String>{};
  final stack = <String>[];
  stack.addAll(entries);
  while (stack.isNotEmpty) {
    final x = stack.removeLast();
    if (!seen.add(x)) continue;
    final outs = gOut[x] ?? const [];
    for (final y in outs) stack.add(y);
  }
  return seen;
}

// ---------------- misc ----------------
Future<int> _estimateLOC(String file) async {
  try {
    final s = await File(file).readAsString();
    return s.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

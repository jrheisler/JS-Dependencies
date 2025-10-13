// goDependency.dart — V0 Go dependency crawler (no external packages)
// Produces: goDependencies.json in the current working directory.
//
// What it does:
// - Recursively scans for *.go (skips vendor, tests, and common build dirs).
// - Parses package name, imports (single & block), and detects files with func main() in package main.
// - Reads go.mod to get the module path. Imports beginning with module path are resolved to local dirs.
// - For a local import path, links the importing file to ALL .go files in the target package directory (excluding *_test.go).
// - Standard library imports => external nodes: std:<path>.
// - Third-party imports => external nodes: go:<module/or/domain/path>.
// - Computes degrees and reachability from all entry files (package main with func main()).
//
// Limitations (V0):
// - Does not handle replace directives, workspace, or GOPATH. Module path resolution is heuristic but works for typical repos.
// - Relative imports are ignored (deprecated in modules).
// - Large packages may result in many edges; you can later collapse to a package-level node if desired.

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
  String lang = 'go';
  int? sizeLOC;
  String? pkg;          // package name
  int inDeg = 0;
  int outDeg = 0;

  _Node({required this.id, required this.type, required this.state, this.sizeLOC, this.pkg});

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (pkg != null) 'package': pkg,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source;   // file id (relative path)
  final String target;   // file id (relative path) OR external id (std:..., go:...)
  final String kind;     // 'import'
  final String certainty; // 'static'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _GoFacts {
  final String absPath;
  final String relId;
  final String pkgName;
  final List<String> imports;
  final bool isMainPkg;
  final bool hasMainFunc;
  _GoFacts(this.absPath, this.relId, this.pkgName, this.imports, this.isMainPkg, this.hasMainFunc);
}

// ---------------- main ----------------
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) Collect go files
  final files = await _collectGoFiles(cwd);

  // 2) Read go.mod for module path (if exists)
  final modulePath = await _readModulePath(cwd);

  // 3) Parse facts
  final facts = <_GoFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractFacts(cwd, f, text));
  }

  // 4) Build package directories map: importPath -> directory (for local) and dir -> files
  //    We'll attempt to resolve local import "modulePath/xyz/abc" to <cwd>/xyz/abc
  final dirToFiles = <String, List<String>>{};
  for (final f in files) {
    final d = _dir(f);
    (dirToFiles[d] ??= <String>[]).add(f);
  }

  // 5) Build edges and externals
  final edges = <_Edge>[];
  final externals = <String>{};

  for (final ff in facts) {
    final src = ff.relId;
    for (final imp in ff.imports) {
      final resolved = _resolveImportToLocalDir(cwd, modulePath, imp);
      if (resolved != null) {
        // Link to all .go files in that directory (excluding tests)
        final filesInPkg = dirToFiles[resolved] ?? const <String>[];
        for (final tgtAbs in filesInPkg) {
          if (_base(tgtAbs).endsWith('_test.go')) continue;
          edges.add(_Edge(source: src, target: _rel(tgtAbs, cwd), kind: 'import', certainty: 'static'));
        }
        // If directory exists but contains no files (unlikely), skip linking.
      } else {
        // External: std or third-party
        final extId = _externalIdForImport(imp);
        externals.add(extId);
        edges.add(_Edge(source: src, target: extId, kind: 'import', certainty: 'static'));
      }
    }
  }

  // 6) Build nodes (files + externals)
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(ff.absPath),
      pkg: ff.pkgName,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(id: ext, type: 'external', state: 'used'));
  }

  // 7) Degrees
  _computeDegrees(nodes, edges);

  // 8) Entries: files in package main with func main()
  final entryFiles = facts
      .where((f) => f.isMainPkg && f.hasMainFunc)
      .map((f) => f.relId)
      .toList();

  // 9) Reachability
  final usedSet = _reach(entryFiles, edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 10) Write output
  final outPath = _join(cwd, 'goDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));

  // 11) Stats
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[info] Wrote: ${_rel(outPath, cwd)}');
  stderr.writeln('[stats] nodes=$total edges=${edges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// ---------------- crawl ----------------
Future<List<String>> _collectGoFiles(String root) async {
  final ignoreDirs = <String>{
    'vendor','node_modules','dist','build','target','out','.git','.idea','.vscode','.cache','.turbo','.parcel-cache'
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final rel = _rel(sp, root);
    final parts = rel.split(_sep);
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp) == '.go') result.add(_normalize(sp));
  }
  return result;
}

// ---------------- parse ----------------
_GoFacts _extractFacts(String cwd, String fileAbs, String text) {
  // Remove block comments /* */ and per-line // comments for import/func scanning lines,
  // but keep original for LOC counting elsewhere.
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = noBlock.split('\n');

  String pkgName = 'main';
  final imports = <String>[];
  bool inImportBlock = false;

  bool isMainPkg = false;
  bool hasMainFunc = false;

  final rePackage = RegExp(r'^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)\s*$');
  final reImportStart = RegExp(r'^\s*import\s*\(\s*$');
  final reImportSingle = RegExp(r'^\s*import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?\"([^\"]+)\"\s*$'); // import "x" or import alias "x"
  final reImportLine = RegExp(r'^\s*\"([^\"]+)\"\s*$'); // lines within import (...)
  final reFuncMain = RegExp(r'^\s*func\s+main\s*\(\s*\)\s*\{'); // crude

  for (var raw in lines) {
    var line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final pm = rePackage.firstMatch(line);
    if (pm != null) {
      pkgName = pm.group(1)!;
      isMainPkg = pkgName == 'main';
      continue;
    }

    if (reImportStart.hasMatch(line)) {
      inImportBlock = true;
      continue;
    }
    if (inImportBlock) {
      if (line.contains(')')) {
        inImportBlock = false;
        continue;
      }
      final im = reImportLine.firstMatch(line);
      if (im != null) {
        imports.add(im.group(1)!);
      }
      continue;
    }

    final im2 = reImportSingle.firstMatch(line);
    if (im2 != null) {
      imports.add(im2.group(1)!);
      continue;
    }

    if (isMainPkg && !hasMainFunc && reFuncMain.hasMatch(line)) {
      hasMainFunc = true;
    }
  }

  return _GoFacts(
    fileAbs,
    _rel(fileAbs, cwd),
    pkgName,
    imports,
    isMainPkg,
    hasMainFunc,
  );
}

// ---------------- go.mod ----------------
Future<String?> _readModulePath(String cwd) async {
  final f = File(_join(cwd, 'go.mod'));
  if (!await f.exists()) return null;
  try {
    final s = await f.readAsString();
    final m = RegExp(r'^\s*module\s+([^\s]+)\s*$', multiLine: true).firstMatch(s);
    return m?.group(1);
  } catch (_) {
    return null;
  }
}

// ---------------- resolution ----------------
String? _resolveImportToLocalDir(String cwd, String? modulePath, String importPath) {
  // If we have a module path, only import paths starting with "<modulePath>/" are local.
  if (modulePath != null && importPath.startsWith(modulePath + '/')) {
    final suffix = importPath.substring(modulePath.length + 1);
    final targetDir = _join(cwd, suffix.replaceAll('/', _sep));
    final dir = Directory(targetDir);
    if (dir.existsSync()) {
      return _normalize(dir.path);
    }
    // If not found directly, fall back to null (treat as external).
    return null;
  }
  // Heuristic fallback: no module path, try direct directory from repo root
  // e.g., import "pkg/sub" -> cwd/pkg/sub
  final tryDir = _join(cwd, importPath.replaceAll('/', _sep));
  if (Directory(tryDir).existsSync()) {
    return _normalize(tryDir);
  }
  return null;
}

String _externalIdForImport(String importPath) {
  // stdlib: first segment has no dot (e.g., "fmt", "net/http", "crypto/rand")
  // third-party: first segment contains a dot ("github.com/...") => go:<path>
  final first = importPath.split('/').first;
  if (!first.contains('.')) {
    return 'std:$importPath';
  }
  return 'go:$importPath';
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

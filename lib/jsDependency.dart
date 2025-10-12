// jsDependency.dart — Crawl JS/TS, build a dependency graph, write jsDependencies.json
//
// Usage:
//   dart run jsDependency.dart
//   # or compiled binary with no args
//
// What it does (V0):
// - Walks the current directory recursively
// - Collects *.js, *.mjs, *.cjs, *.ts, *.tsx, *.jsx (skips node_modules, dist, build, .git, coverage, .next, out)
// - Extracts import edges via regex (ESM, CJS require, export-from, dynamic import('literal'))
// - Resolves only *relative* specifiers (./, ../) to real files using Node-like rules (extensions + index)
// - Detects entries from package.json: main/module/exports (first file found); fallbacks to src/main.* or index.*
// - Reachability from entries marks state: used / unused (side_effect_only if only side-effect imported)
// - Writes jsDependencies.json with {nodes, edges}; computes inDeg/outDeg
//
// Limitations:
// - No parsing of alias paths (@/*), tsconfig paths, or bare specifiers ('react') → those become "external" nodes
// - Dynamic non-literal imports and require(variable) are ignored
// - Heuristic side-effect detection: side-effect import (import 'x') marks target as side_effect_only
//
// You can iterate to V1 by reading tsconfig.json paths and resolving bare specifiers into node_modules.

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final cwd = p.normalize(p.absolute(Directory.current.path));
  stderr.writeln('[info] Scanning: $cwd');

  final files = await _collectSourceFiles(cwd);
  stderr.writeln('[info] Source files: ${files.length}');

  final pkg = await _readPackageJson(cwd);
  final entries = _discoverEntries(cwd, pkg, files);
  if (entries.isEmpty) {
    stderr.writeln('[warn] No entry points found. Using heuristic fallbacks (src/main.* or index.*).');
  } else {
    stderr.writeln('[info] Entries: ${entries.map((e) => p.relative(e, from: cwd)).join(', ')}');
  }

  // Parse imports/exports
  final fileFacts = <String, _FileFacts>{};
  for (final f in files) {
    final text = await File(f).readAsString();
    fileFacts[f] = _extractFacts(f, text);
  }

  // Build edges (resolve only relative specifiers to actual files; mark others as external)
  final edges = <_Edge>[];
  final nodeSet = <String>{}..addAll(files);
  final externals = <String>{};

  for (final facts in fileFacts.values) {
    for (final imp in facts.imports) {
      final resolved = _resolveSpecifier(cwd, facts.path, imp.specifier);
      if (resolved != null) {
        if (nodeSet.contains(resolved)) {
          edges.add(_Edge(source: facts.path, target: resolved, kind: imp.kind, certainty: 'static'));
        } else {
          // It resolved to a file that isn't in our collected set (rare) → treat as external
          final extId = _externalId(resolved);
          externals.add(extId);
          edges.add(_Edge(source: facts.path, target: extId, kind: imp.kind, certainty: 'static'));
        }
      } else {
        // bare or unresolvable → external
        final extId = _externalId(imp.specifier);
        externals.add(extId);
        edges.add(_Edge(source: facts.path, target: extId, kind: imp.kind, certainty: 'static'));
      }
    }
  }

  // Build nodes
  final nodes = <_Node>[];
  for (final f in files) {
    nodes.add(_Node(
      id: p.relative(f, from: cwd),
      type: 'file',
      state: 'unused', // provisional; updated after reachability
      sizeLOC: await _estimateLOC(f),
      packageName: null,
      hasSideEffects: fileFacts[f]?.hasSideEffectImport ?? false,
      absPath: f,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(
      id: ext,
      type: 'external',
      state: 'used', // reachable if any file imports it
      sizeLOC: null,
      packageName: _guessPackageName(ext),
      hasSideEffects: null,
      absPath: null,
    ));
  }

  // Normalize edge ids to relative paths
  final relEdges = edges.map((e) {
    final src = e.source.startsWith(cwd) ? p.relative(e.source, from: cwd) : e.source;
    final tgt = e.target.startsWith(cwd) ? p.relative(e.target, from: cwd) : e.target;
    return _Edge(source: src, target: tgt, kind: e.kind, certainty: e.certainty);
  }).toList();

  // Compute degrees
  _computeDegrees(nodes, relEdges);

  // Reachability from entries
  final entryRel = entries.map((e) => p.relative(e, from: cwd)).toList();
  final usedSet = _reach(entryRel, relEdges);
  final sideEffectOnly = _sideEffectOnlyTargets(fileFacts, cwd);

  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    if (usedSet.contains(n.id)) {
      // If it’s only ever imported with side-effect-only, mark it
      n.state = sideEffectOnly.contains(n.id) ? 'side_effect_only' : 'used';
    } else {
      n.state = 'unused';
    }
  }

  // Write output
  final outPath = p.join(cwd, 'jsDependencies.json');
  final jsonOut = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': relEdges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(jsonOut));
  stderr.writeln('[info] Wrote: ${p.relative(outPath, from: cwd)}');

  // Stats
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used' || n.state == 'side_effect_only').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[stats] nodes=$total edges=${relEdges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// ---------------- model ----------------

class _Node {
  String id;
  String type; // file | external
  String state; // used | unused | side_effect_only
  int? sizeLOC;
  String? packageName;
  bool? hasSideEffects;
  int inDeg = 0;
  int outDeg = 0;
  final String? absPath; // for internal use

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.packageName,
    this.hasSideEffects,
    required this.absPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (packageName != null) 'package': packageName,
        if (hasSideEffects != null) 'hasSideEffects': hasSideEffects,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source;
  final String target;
  final String kind;      // import | reexport | require | dynamic | side_effect
  final String certainty; // static | heuristic
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {'source': source, 'target': target, 'kind': kind, 'certainty': certainty};
}

class _ImportFact {
  final String specifier;
  final String kind; // import | reexport | require | dynamic | side_effect
  _ImportFact(this.specifier, this.kind);
}

class _FileFacts {
  final String path;
  final List<_ImportFact> imports;
  final bool hasSideEffectImport; // saw: import 'x'
  _FileFacts(this.path, this.imports, this.hasSideEffectImport);
}

// ---------------- crawl & parse ----------------

Future<List<String>> _collectSourceFiles(String root) async {
  final ignoreDirs = <String>{'node_modules', 'dist', 'build', '.git', 'coverage', '.next', 'out', '.turbo', '.vite', '.parcel-cache'};
  final exts = <String>{'.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx'};

  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final parts = p.split(p.relative(sp, from: root));
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (exts.contains(p.extension(sp))) {
      result.add(p.normalize(sp));
    }
  }
  return result;
}

_FileFacts _extractFacts(String filePath, String text) {
  final imports = <_ImportFact>[];
  bool sideEffectOnly = false;

  // Remove simple /* ... */ comments
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

  // Handle line comments by stripping trailing // (but keep strings)
  // (Heuristic: okay for v0)
  final lines = noBlock.split('\n');

  final reImport = RegExp(r'''^\s*import\s+(?:[^'"]+from\s+)?['"]([^'"]+)['"]''');
  final reExportFrom = RegExp(r'''^\s*export\s+[^;]*\s+from\s+['"]([^'"]+)['"]''');
  final reSideEffect = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
  final reRequire = RegExp(r'''require\s*\(\s*['"]([^'"]+)['"]\s*\)''');
  final reDynImport = RegExp(r'''import\s*\(\s*['"]([^'"]+)['"]\s*\)''');

  for (var raw in lines) {
    final line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final m1 = reImport.firstMatch(line);
    if (m1 != null) {
      final spec = m1.group(1)!;
      final isSide = reSideEffect.hasMatch(line);
      imports.add(_ImportFact(spec, isSide ? 'side_effect' : 'import'));
      if (isSide) sideEffectOnly = true;
      continue;
    }

    final m2 = reExportFrom.firstMatch(line);
    if (m2 != null) {
      imports.add(_ImportFact(m2.group(1)!, 'reexport'));
      continue;
    }

    for (final m in reRequire.allMatches(line)) {
      imports.add(_ImportFact(m.group(1)!, 'require'));
    }

    for (final m in reDynImport.allMatches(line)) {
      imports.add(_ImportFact(m.group(1)!, 'dynamic'));
    }
  }

  return _FileFacts(filePath, imports, sideEffectOnly);
}

// ---------------- resolution ----------------

String? _resolveSpecifier(String cwd, String fromFile, String spec) {
  // Only resolve relative paths here
  if (!(spec.startsWith('./') || spec.startsWith('../'))) return null;

  final baseDir = p.dirname(fromFile);
  final candidate = p.normalize(p.absolute(baseDir, spec));
  final resolved = _tryFileResolutions(candidate);
  return resolved;
}

String? _tryFileResolutions(String absNoExt) {
  // Try as-file with extension, then directory index
  // Order inspired by Node + TS projects
  final tryExts = [
    '', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  ];
  for (final ext in tryExts) {
    final path = absNoExt + ext;
    if (File(path).existsSync()) return p.normalize(path);
  }
  // Directory index
  final idxs = [
    p.join(absNoExt, 'index.ts'),
    p.join(absNoExt, 'index.tsx'),
    p.join(absNoExt, 'index.js'),
    p.join(absNoExt, 'index.jsx'),
    p.join(absNoExt, 'index.mjs'),
    p.join(absNoExt, 'index.cjs'),
  ];
  for (final idx in idxs) {
    if (File(idx).existsSync()) return p.normalize(idx);
  }
  return null;
}

String _externalId(String raw) {
  // Keep as given; viewer will show as external node
  return raw;
}

String? _guessPackageName(String externalId) {
  // crude: first path segment before slash
  final s = externalId.replaceAll('\\', '/');
  if (s.startsWith('@')) {
    // @scope/pkg/...
    final m = RegExp(r'^@[^/]+/[^/]+').firstMatch(s);
    return m?.group(0);
  }
  final m = RegExp(r'^[^/]+').firstMatch(s);
  return m?.group(0);
}

// ---------------- entries & reachability ----------------

Future<Map<String, dynamic>?> _readPackageJson(String cwd) async {
  final pj = File(p.join(cwd, 'package.json'));
  if (!await pj.exists()) return null;
  try { return jsonDecode(await pj.readAsString()) as Map<String, dynamic>; }
  catch (_) { return null; }
}

List<String> _discoverEntries(String cwd, Map<String, dynamic>? pkg, List<String> files) {
  final entries = <String>[];
  String? pushIfFile(String? rel) {
    if (rel == null || rel.isEmpty) return null;
    final abs = p.normalize(p.absolute(cwd, rel));
    if (File(abs).existsSync()) { entries.add(abs); }
    return null;
  }

  if (pkg != null) {
    pushIfFile(pkg['module'] as String?);
    pushIfFile(pkg['main'] as String?);

    // Basic exports field handling (strings only)
    final exp = pkg['exports'];
    if (exp is String) pushIfFile(exp);
    if (exp is Map) {
      for (final v in exp.values) {
        if (v is String) pushIfFile(v);
        if (v is Map) {
          for (final vv in v.values) {
            if (vv is String) pushIfFile(vv);
          }
        }
      }
    }
  }

  // Heuristics
  final tryRel = [
    'src/main.ts', 'src/main.tsx', 'src/main.js', 'src/index.ts',
    'src/index.tsx', 'src/index.js', 'index.ts', 'index.js',
  ];
  for (final rel in tryRel) {
    final abs = p.normalize(p.absolute(cwd, rel));
    if (File(abs).existsSync()) entries.add(abs);
  }

  // Fallback: if still empty, treat files with no incoming edges (after we parse)—but here we just return heuristics.
  return entries.toSet().toList();
}

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

Set<String> _sideEffectOnlyTargets(Map<String, _FileFacts> facts, String cwd) {
  final targets = <String>{};
  facts.forEach((path, ff) {
    final rel = p.relative(path, from: cwd);
    for (final imp in ff.imports) {
      if (imp.kind == 'side_effect') {
        final resolved = _resolveSpecifier(cwd, path, imp.specifier);
        if (resolved != null) {
          targets.add(p.relative(resolved, from: cwd));
        }
      }
    }
  });
  return targets;
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

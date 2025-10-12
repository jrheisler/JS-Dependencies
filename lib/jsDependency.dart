// jsDependency.dart — V0 crawler, no external packages

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _dirname(String p) {
  final i = p.replaceAll('\\', '/').lastIndexOf('/');
  return i <= 0 ? (Platform.isWindows ? p.substring(0, 2) : '/') : p.substring(0, i);
}
String _join(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final s = a.endsWith(_sep) ? a.substring(0, a.length - 1) : a;
  final t = b.startsWith(_sep) ? b.substring(1) : b;
  return '$s$_sep$t';
}
String _ext(String p) {
  final s = p.replaceAll('\\', '/');
  final base = s.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot);
}
String _normalize(String p) {
  // normalize ./ and ../ using Uri
  return Uri.file(p, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _rel(String target, String from) {
  final T = _normalize(_abs(target));
  final F = _normalize(_abs(from));
  if (T == F) return '.';
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T; // fallback: absolute
}
List<String> _split(String p) => p.split(_sep);

// ------------------------------------------------

void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));
  stderr.writeln('[info] Scanning: $cwd');

  final files = await _collectSourceFiles(cwd);
  stderr.writeln('[info] Source files: ${files.length}');

  final pkg = await _readPackageJson(cwd);
  final entriesAbs = _discoverEntries(cwd, pkg, files);
  final entriesRel = entriesAbs.map((e) => _rel(e, cwd)).toList();

  if (entriesRel.isEmpty) {
    stderr.writeln('[warn] No entry points found. Using heuristic fallbacks (src/main.* or index.* if present).');
  } else {
    stderr.writeln('[info] Entries: ${entriesRel.join(', ')}');
  }

  // Parse imports
  final factsByPath = <String, _FileFacts>{};
  for (final f in files) {
    final text = await File(f).readAsString();
    factsByPath[f] = _extractFacts(f, text);
  }

  // Build edges + external nodes
  final edges = <_Edge>[];
  final nodeSet = <String>{}..addAll(files);
  final externals = <String>{};

  for (final facts in factsByPath.values) {
    for (final imp in facts.imports) {
      final resolved = _resolveSpecifier(cwd, facts.path, imp.specifier);
      if (resolved != null) {
        if (nodeSet.contains(resolved)) {
          edges.add(_Edge(source: facts.path, target: resolved, kind: imp.kind, certainty: 'static'));
        } else {
          final extId = _externalId(resolved);
          externals.add(extId);
          edges.add(_Edge(source: facts.path, target: extId, kind: imp.kind, certainty: 'static'));
        }
      } else {
        final extId = _externalId(imp.specifier);
        externals.add(extId);
        edges.add(_Edge(source: facts.path, target: extId, kind: imp.kind, certainty: 'static'));
      }
    }
  }

  // Nodes
  final nodes = <_Node>[];
  for (final f in files) {
    nodes.add(_Node(
      id: _rel(f, cwd),
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(f),
      packageName: null,
      hasSideEffects: factsByPath[f]?.hasSideEffectImport ?? false,
      absPath: f,
    ));
  }
  for (final e in externals) {
    nodes.add(_Node(
      id: e,
      type: 'external',
      state: 'used',
      sizeLOC: null,
      packageName: _guessPackageName(e),
      hasSideEffects: null,
      absPath: null,
    ));
  }

  // Relativize edges
  final relEdges = edges.map((e) {
    final src = e.source.startsWith(cwd) ? _rel(e.source, cwd) : e.source;
    final tgt = e.target.startsWith(cwd) ? _rel(e.target, cwd) : e.target;
    return _Edge(source: src, target: tgt, kind: e.kind, certainty: e.certainty);
  }).toList();

  // Degrees
  _computeDegrees(nodes, relEdges);

  // Reachability
  final usedSet = _reach(entriesRel, relEdges);
  final sideEffectOnly = _sideEffectOnlyTargets(factsByPath, cwd);

  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    if (usedSet.contains(n.id)) {
      n.state = sideEffectOnly.contains(n.id) ? 'side_effect_only' : 'used';
    } else {
      n.state = 'unused';
    }
  }

  // Output
  final outPath = _join(cwd, 'jsDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': relEdges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));
  stderr.writeln('[info] Wrote: ${_rel(outPath, cwd)}');

  // Stats
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used' || n.state == 'side_effect_only').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[stats] nodes=$total edges=${relEdges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// -------- models --------
class _Node {
  String id;
  String type; // file | external
  String state; // used | unused | side_effect_only
  int? sizeLOC;
  String? packageName;
  bool? hasSideEffects;
  int inDeg = 0;
  int outDeg = 0;
  final String? absPath;

  _Node({required this.id, required this.type, required this.state, this.sizeLOC, this.packageName, this.hasSideEffects, required this.absPath});
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
  final String source, target, kind, certainty;
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {'source': source, 'target': target, 'kind': kind, 'certainty': certainty};
}

class _ImportFact {
  final String specifier, kind; // import | reexport | require | dynamic | side_effect
  _ImportFact(this.specifier, this.kind);
}

class _FileFacts {
  final String path;
  final List<_ImportFact> imports;
  final bool hasSideEffectImport;
  _FileFacts(this.path, this.imports, this.hasSideEffectImport);
}

// -------- crawl & parse --------
Future<List<String>> _collectSourceFiles(String root) async {
  final ignoreDirs = <String>{'node_modules','dist','build','.git','coverage','.next','out','.turbo','.vite','.parcel-cache'};
  final exts = <String>{'.js','.mjs','.cjs','.ts','.tsx','.jsx'};
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final parts = _split(_rel(sp, root));
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (exts.contains(_ext(sp))) result.add(_normalize(sp));
  }
  return result;
}

_FileFacts _extractFacts(String filePath, String text) {
  final imports = <_ImportFact>[];
  bool sideEffectOnly = false;

  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
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

// -------- resolution --------
String? _resolveSpecifier(String cwd, String fromFile, String spec) {
  if (!(spec.startsWith('./') || spec.startsWith('../'))) return null;
  final baseDir = _dirname(fromFile);
  final candidate = _normalize(_abs(_join(baseDir, spec)));
  return _tryFileResolutions(candidate);
}

String? _tryFileResolutions(String absNoExt) {
  final tryExts = ['', '.ts','.tsx','.js','.jsx','.mjs','.cjs'];
  for (final ext in tryExts) {
    final p = absNoExt + ext;
    if (File(p).existsSync()) return _normalize(p);
  }
  final idxs = [
    _join(absNoExt, 'index.ts'),
    _join(absNoExt, 'index.tsx'),
    _join(absNoExt, 'index.js'),
    _join(absNoExt, 'index.jsx'),
    _join(absNoExt, 'index.mjs'),
    _join(absNoExt, 'index.cjs'),
  ];
  for (final p in idxs) {
    if (File(p).existsSync()) return _normalize(p);
  }
  return null;
}

String _externalId(String raw) => raw;
String? _guessPackageName(String externalId) {
  final s = externalId.replaceAll('\\', '/');
  if (s.startsWith('@')) {
    final m = RegExp(r'^@[^/]+/[^/]+').firstMatch(s);
    return m?.group(0);
  }
  return RegExp(r'^[^/]+').firstMatch(s)?.group(0);
}

// -------- entries & reachability --------
Future<Map<String, dynamic>?> _readPackageJson(String cwd) async {
  final pj = File(_join(cwd, 'package.json'));
  if (!await pj.exists()) return null;
  try { return jsonDecode(await pj.readAsString()) as Map<String, dynamic>; }
  catch (_) { return null; }
}

List<String> _discoverEntries(String cwd, Map<String, dynamic>? pkg, List<String> filesAbs) {
  final entries = <String>{};

  void addIfFile(String? rel) {
    if (rel == null || rel.isEmpty) return;
    final abs = _normalize(_abs(_join(cwd, rel)));
    if (File(abs).existsSync()) entries.add(abs);
  }

  if (pkg != null) {
    addIfFile(pkg['module'] as String?);
    addIfFile(pkg['main'] as String?);
    final exp = pkg['exports'];
    if (exp is String) addIfFile(exp);
    if (exp is Map) {
      for (final v in exp.values) {
        if (v is String) addIfFile(v);
        if (v is Map) {
          for (final vv in v.values) {
            if (vv is String) addIfFile(vv);
          }
        }
      }
    }
  }

  // Heuristics
  for (final rel in ['src/main.ts','src/main.tsx','src/main.js','src/index.ts','src/index.tsx','src/index.js','index.ts','index.js']) {
    final abs = _normalize(_abs(_join(cwd, rel)));
    if (File(abs).existsSync()) entries.add(abs);
  }

  return entries.toList();
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
  return seen.map((s) => s.startsWith('.') ? s : s).toSet();
}

Set<String> _sideEffectOnlyTargets(Map<String, _FileFacts> facts, String cwd) {
  final targets = <String>{};
  facts.forEach((path, ff) {
    final relFrom = _rel(path, cwd);
    for (final imp in ff.imports) {
      if (imp.kind == 'side_effect') {
        final resolved = _resolveSpecifier(cwd, path, imp.specifier);
        if (resolved != null) {
          targets.add(_rel(resolved, cwd));
        }
      }
    }
  });
  return targets;
}

// -------- misc --------
Future<int> _estimateLOC(String file) async {
  try {
    final s = await File(file).readAsString();
    return s.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

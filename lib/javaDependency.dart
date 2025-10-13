// javaDependency.dart — V0 crawler aligned with jsDependency.dart structure

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _basename(String p) {
  final parts = p.replaceAll('\\', '/').split('/');
  return parts.isEmpty ? p : parts.last;
}
String _basenameNoExt(String p) {
  final base = _basename(p);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
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
  return Uri.file(p, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _rel(String target, String from) {
  final T = _normalize(_abs(target));
  final F = _normalize(_abs(from));
  if (T == F) return '.';
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T;
}
List<String> _split(String p) => p.split(_sep);

// ------------------------------------------------

void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));
  final files = await _collectSourceFiles(cwd);

  final factsByPath = <String, _JavaFileFacts>{};
  for (final f in files) {
    final text = await File(f).readAsString();
    factsByPath[f] = _extractFacts(f, text);
  }

  final classIndex = <String, String>{};
  for (final facts in factsByPath.values) {
    for (final type in facts.declaredTypes) {
      final fq = facts.packageName == null || facts.packageName!.isEmpty
          ? type
          : '${facts.packageName}.$type';
      classIndex[fq] = facts.path;
    }
  }

  final edges = <_Edge>[];
  final nodeSet = <String>{}..addAll(files);
  final externals = <String>{};

  for (final facts in factsByPath.values) {
    for (final imp in facts.imports) {
      final resolved = _resolveImport(imp.specifier, classIndex);
      if (resolved != null && nodeSet.contains(resolved)) {
        edges.add(_Edge(source: facts.path, target: resolved, kind: imp.kind, certainty: 'static'));
      } else {
        final extId = _externalId(imp.specifier);
        externals.add(extId);
        edges.add(_Edge(source: facts.path, target: extId, kind: imp.kind, certainty: 'static'));
      }
    }
  }

  final nodes = <_Node>[];
  for (final facts in factsByPath.values) {
    nodes.add(_Node(
      id: _rel(facts.path, cwd),
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(facts.path),
      packageName: facts.packageName,
      hasSideEffects: false,
      absPath: facts.path,
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

  final relEdges = edges.map((e) {
    final src = e.source.startsWith(cwd) ? _rel(e.source, cwd) : e.source;
    final tgt = e.target.startsWith(cwd) ? _rel(e.target, cwd) : e.target;
    return _Edge(source: src, target: tgt, kind: e.kind, certainty: e.certainty);
  }).toList();

  _computeDegrees(nodes, relEdges);

  final entriesAbs = _discoverEntries(factsByPath.values);
  final entriesRel = entriesAbs.map((e) => _rel(e, cwd)).toList();

  final usedSet = _reach(entriesRel, relEdges);
  final sideEffectOnly = _sideEffectOnlyTargets();

  for (final n in nodes) {
    if (n.type == 'external') {
      n.state = 'used';
      continue;
    }
    if (usedSet.contains(n.id)) {
      n.state = sideEffectOnly.contains(n.id) ? 'side_effect_only' : 'used';
    } else {
      n.state = 'unused';
    }
  }

  final outPath = _join(cwd, 'javaDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': relEdges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));
}

// -------- models --------
class _Node {
  String id;
  String type;
  String state;
  int? sizeLOC;
  String? packageName;
  bool? hasSideEffects;
  int inDeg = 0;
  int outDeg = 0;
  final String? absPath;

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
  final String source, target, kind, certainty;
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {'source': source, 'target': target, 'kind': kind, 'certainty': certainty};
}

class _JavaImportFact {
  final String specifier, kind;
  _JavaImportFact(this.specifier, this.kind);
}

class _JavaFileFacts {
  final String path;
  final String? packageName;
  final List<String> declaredTypes;
  final List<_JavaImportFact> imports;
  final bool hasMainMethod;

  _JavaFileFacts({
    required this.path,
    required this.packageName,
    required this.declaredTypes,
    required this.imports,
    required this.hasMainMethod,
  });
}

// -------- crawl & parse --------
Future<List<String>> _collectSourceFiles(String root) async {
  final ignoreDirs = <String>{
    '.git',
    'build',
    'out',
    'target',
    'bin',
    '.idea',
    '.gradle',
    '.settings',
  };
  final exts = <String>{'.java'};
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

_JavaFileFacts _extractFacts(String filePath, String text) {
  final imports = <_JavaImportFact>[];
  String? packageName;

  final blockStripped = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final hasMain = RegExp(r'public\s+static\s+void\s+main\s*\(').hasMatch(blockStripped);

  final lines = blockStripped.split('\n');
  for (var raw in lines) {
    final line = raw.replaceFirst(RegExp(r'//.*$'), '').trim();
    if (line.isEmpty) continue;

    final pkgMatch = RegExp(r'^package\s+([a-zA-Z0-9_.]+)\s*;').firstMatch(line);
    if (pkgMatch != null) {
      packageName = pkgMatch.group(1);
      continue;
    }

    final impMatch = RegExp(r'^import\s+(static\s+)?([a-zA-Z0-9_.*]+)\s*;').firstMatch(line);
    if (impMatch != null) {
      final isStatic = impMatch.group(1) != null;
      final spec = impMatch.group(2)!;
      imports.add(_JavaImportFact(spec, isStatic ? 'import_static' : 'import'));
      continue;
    }
  }

  final declaredTypes = <String>{};
  final typeMatches = RegExp(r'\b(class|interface|enum|record)\s+([A-Za-z0-9_]+)');
  for (final m in typeMatches.allMatches(blockStripped)) {
    declaredTypes.add(m.group(2)!);
  }
  if (declaredTypes.isEmpty) {
    declaredTypes.add(_basenameNoExt(filePath));
  }

  return _JavaFileFacts(
    path: _normalize(filePath),
    packageName: packageName,
    declaredTypes: declaredTypes.toList(),
    imports: imports,
    hasMainMethod: hasMain,
  );
}

// -------- resolution --------
String? _resolveImport(String spec, Map<String, String> classIndex) {
  final normalized = spec.trim();
  if (normalized.endsWith('.*')) return null;
  return classIndex[normalized];
}

String _externalId(String raw) => raw;
String? _guessPackageName(String externalId) {
  final cleaned = externalId.replaceAll('/', '.');
  final parts = cleaned.split('.');
  if (parts.length >= 2) return '${parts[0]}.${parts[1]}';
  return parts.isEmpty ? null : parts.first;
}

// -------- entries & reachability --------
List<String> _discoverEntries(Iterable<_JavaFileFacts> facts) {
  final entries = <String>{};
  for (final f in facts) {
    if (f.hasMainMethod) entries.add(f.path);
  }
  if (entries.isEmpty) {
    for (final f in facts) {
      final base = _basenameNoExt(f.path);
      if (base.toLowerCase().contains('main') || base.toLowerCase().contains('application')) {
        entries.add(f.path);
      }
    }
  }
  if (entries.isEmpty) {
    for (final f in facts) {
      entries.add(f.path);
    }
  }
  return entries.map(_normalize).toList();
}

void _computeDegrees(List<_Node> nodes, List<_Edge> edges) {
  final byId = {for (final n in nodes) n.id: n};
  for (final n in nodes) {
    n.inDeg = 0;
    n.outDeg = 0;
  }
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

Set<String> _sideEffectOnlyTargets() => <String>{};

// -------- misc --------
Future<int> _estimateLOC(String file) async {
  try {
    final s = await File(file).readAsString();
    return s.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

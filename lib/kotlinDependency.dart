// kotlinDependency.dart — Kotlin dependency crawler (no external packages)
// Produces: kotlinDependencies.json in the current working directory.
//
// Features:
// - Recursively scans *.kt while skipping common build/cache directories.
// - Extracts package names, imports (including alias + wildcard), primary declarations, and main() entry points.
// - Builds a map of fully-qualified names to files, resolves imports to internal files, and records externals heuristically.
// - Computes node degrees and reachability from entry files (those declaring `fun main`).
//
// Limitations (V0):
// - Only explicit imports are tracked; unqualified same-package references are not inferred.
// - Files with multiple declarations are simplified to the first class/object/interface/enum encountered.
// - Wildcard imports expand to all declarations that share the prefix; sparse packages may resolve as externals.
// - External resolution is heuristic and namespaces imports by their leading segments.
//
// Build:
//   dart compile exe .\\kotlinDependency.dart -o .\\kotlinDependency.exe
// Run:
//   .\\kotlinDependency.exe   # writes kotlinDependencies.json

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
  return T;
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

// ---------------- models ----------------
class _Node {
  String id; // repo-relative file path for files; external id for externals
  String type; // file | external
  String state; // used | unused
  String lang;
  int? sizeLOC;
  String? packageName;
  String? declarationName;
  String? fqn;
  bool hasMain;
  int inDeg = 0;
  int outDeg = 0;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.lang = 'kotlin',
    this.sizeLOC,
    this.packageName,
    this.declarationName,
    this.fqn,
    this.hasMain = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (packageName != null) 'package': packageName,
        if (declarationName != null) 'declaration': declarationName,
        if (fqn != null) 'fqn': fqn,
        if (hasMain) 'main': hasMain,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source;
  final String target;
  final String kind; // import | import_wildcard
  final String certainty; // static

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

class _KtFacts {
  final String filePathAbs;
  final String fileIdRel;
  final String? packageName;
  final String? declarationName;
  final String? fqn;
  final bool hasMain;
  final List<_KtImport> imports;
  final int loc;

  _KtFacts({
    required this.filePathAbs,
    required this.fileIdRel,
    required this.packageName,
    required this.declarationName,
    required this.fqn,
    required this.hasMain,
    required this.imports,
    required this.loc,
  });
}

class _KtImport {
  final String raw;
  final bool isWildcard;
  _KtImport(this.raw, {this.isWildcard = false});
}

// ---------------- main ----------------
Future<void> main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  final files = await _collectKtFiles(cwd);
  final facts = <_KtFacts>[];
  for (final file in files) {
    final abs = _normalize(file);
    final text = await File(abs).readAsString();
    facts.add(_extractFacts(cwd, abs, text));
  }

  final fqnToFile = <String, String>{};
  final packageToFiles = <String, List<String>>{};
  for (final fact in facts) {
    if (fact.fqn != null) {
      fqnToFile[fact.fqn!] = fact.fileIdRel;
    }
    if (fact.packageName != null) {
      packageToFiles.putIfAbsent(fact.packageName!, () => <String>[]).add(fact.fileIdRel);
    }
  }

  final pkgDirToFiles = <String, List<String>>{};
  for (final file in files) {
    final rel = _rel(file, cwd);
    final pkgDir = _packageDirForFile(rel);
    (pkgDirToFiles[pkgDir] ??= <String>[]).add(_normalize(file));
  }

  final nodes = <String, _Node>{};
  for (final fact in facts) {
    nodes[fact.fileIdRel] = _Node(
      id: fact.fileIdRel,
      type: 'file',
      state: 'unused',
      sizeLOC: fact.loc,
      packageName: fact.packageName,
      declarationName: fact.declarationName,
      fqn: fact.fqn,
      hasMain: fact.hasMain,
    );
  }

  final edges = <_Edge>[];
  final externals = <String, _Node>{};

  for (final fact in facts) {
    for (final imp in fact.imports) {
      if (imp.isWildcard) {
        final prefix = imp.raw.replaceFirst(RegExp(r'\.\*$'), '');
        final internalTargets = <String>{};

        internalTargets.addAll(fqnToFile.entries
            .where((entry) => entry.key == prefix || entry.key.startsWith('$prefix.'))
            .map((entry) => entry.value));

        final pkgMatches = packageToFiles[prefix];
        if (pkgMatches != null) {
          internalTargets.addAll(pkgMatches);
        }

        if (internalTargets.isEmpty) {
          final dirAbs = _resolvePackageDir(cwd, prefix);
          if (dirAbs != null) {
            final filesInPkg = pkgDirToFiles[_relDir(dirAbs, cwd)] ?? const <String>[];
            for (final tgtAbs in filesInPkg) {
              internalTargets.add(_rel(tgtAbs, cwd));
            }
          }
        }

        if (internalTargets.isEmpty) {
          final extId = _externalForImport('$prefix.*');
          externals.putIfAbsent(
            extId,
            () => _Node(id: extId, type: 'external', state: 'used', lang: 'external'),
          );
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: extId,
            kind: 'import_wildcard',
            certainty: 'static',
          ));
        } else {
          for (final target in internalTargets) {
            edges.add(_Edge(
              source: fact.fileIdRel,
              target: target,
              kind: 'import_wildcard',
              certainty: 'static',
            ));
          }
        }
      } else {
        String? target = fqnToFile[imp.raw];
        if (target == null) {
          final resolvedAbs = _resolveExactImport(cwd, imp.raw);
          if (resolvedAbs != null) {
            final rel = _rel(resolvedAbs, cwd);
            if (nodes.containsKey(rel)) {
              target = rel;
            }
          }
        }

        if (target != null) {
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: target,
            kind: 'import',
            certainty: 'static',
          ));
        } else {
          final extId = _externalForImport(imp.raw);
          externals.putIfAbsent(
            extId,
            () => _Node(id: extId, type: 'external', state: 'used', lang: 'external'),
          );
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: extId,
            kind: 'import',
            certainty: 'static',
          ));
        }
      }
    }
  }

  nodes.addAll(externals);

  final nodeList = nodes.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  _computeDegrees(nodeList, edges);

  final entryFiles = facts.where((f) => f.hasMain).map((f) => f.fileIdRel).toList();
  final usedSet = _reach(entryFiles, edges);

  for (final node in nodeList) {
    if (node.type == 'external') {
      node.state = 'used';
    } else {
      node.state = usedSet.contains(node.id) ? 'used' : 'unused';
    }
  }

  final json = {
    'meta': {
      'generatedBy': 'kotlinDependency.dart',
      'cwd': cwd,
      'fileCount': facts.length,
      'timestamp': DateTime.now().toIso8601String(),
      'entryCount': entryFiles.length,
    },
    'nodes': nodeList.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };

  final outFile = File(_join(cwd, 'kotlinDependencies.json'));
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(json));

  final total = nodeList.length;
  final used = nodeList.where((n) => n.state == 'used' && n.type == 'file').length;
  final unused = nodeList.where((n) => n.state == 'unused').length;
  final externCount = nodeList.where((n) => n.type == 'external').length;
  final maxDeg = nodeList.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);

  stderr.writeln('[info] Wrote: ${_rel(outFile.path, cwd)}');
  stderr.writeln('[stats] nodes=$total edges=${edges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// ---------------- crawl ----------------
Future<List<String>> _collectKtFiles(String root) async {
  final ignoreDirs = <String>{
    '.git',
    '.svn',
    '.hg',
    '.idea',
    '.gradle',
    '.vscode',
    '.cache',
    '.turbo',
    '.parcel-cache',
    'build',
    'dist',
    'out',
    'target',
    'node_modules',
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final rel = _rel(sp, root);
    final parts = rel.split(_sep);
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp) == '.kt') result.add(_normalize(sp));
  }
  result.sort();
  return result;
}

// ---------------- parse ----------------
final _packageReg = RegExp(r'^\\s*package\\s+([A-Za-z0-9_.]+)\\s*$', multiLine: true);
final _importReg =
    RegExp(r'^\\s*import\\s+([A-Za-z_][A-Za-z0-9_.]*\\*?)(?:\\s+as\\s+[A-Za-z_][A-Za-z0-9_]*)?\\s*$', multiLine: true);
final _declarationReg = RegExp(
  r'^(?:\\s*(?:public|internal|private|protected)\\s+)?(?:data\\s+)?(class|object|interface|enum)\\s+([A-Za-z0-9_]+)',
  multiLine: true,
);
final _mainReg = RegExp(r'^\\s*fun\\s+main\\s*\\(', multiLine: true);

_KtFacts _extractFacts(String cwd, String absPath, String text) {
  final normalized = _normalize(absPath);
  final noBlock = text.replaceAll(RegExp(r'/\\*[\\s\\S]*?\\*/'), '');
  final cleaned = noBlock.replaceAll(RegExp(r'//.*$', multiLine: true), '');

  final packageMatch = _packageReg.firstMatch(cleaned);
  final packageName = packageMatch != null ? packageMatch.group(1) : null;

  final imports = <_KtImport>[];
  for (final match in _importReg.allMatches(cleaned)) {
    final raw = match.group(1)!;
    if (raw.endsWith('.*')) {
      imports.add(_KtImport(raw, isWildcard: true));
    } else {
      imports.add(_KtImport(raw));
    }
  }

  String? declName;
  final declMatch = _declarationReg.firstMatch(cleaned);
  if (declMatch != null) {
    declName = declMatch.group(2);
  }

  final hasMain = _mainReg.hasMatch(cleaned);
  final fileIdRel = _rel(normalized, cwd);

  final fqn = (packageName != null && declName != null)
      ? '$packageName.$declName'
      : (declName != null
          ? declName
          : packageName); // package-level declarations fall back to package name.

  final loc = text
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .length;

  return _KtFacts(
    filePathAbs: normalized,
    fileIdRel: fileIdRel,
    packageName: packageName,
    declarationName: declName,
    fqn: fqn,
    hasMain: hasMain,
    imports: imports,
    loc: loc,
  );
}

// ---------------- resolution ----------------
String? _resolveExactImport(String cwd, String importPath) {
  final tryRoots = <String>[
    _join(cwd, 'src${_sep}main${_sep}kotlin'),
    _join(cwd, 'src${_sep}test${_sep}kotlin'),
    _join(cwd, 'src'),
    cwd,
  ];
  final parts = importPath.split('.');
  if (parts.isEmpty) return null;
  final name = parts.last;
  final dirParts = parts.sublist(0, parts.length - 1);
  final relDir = dirParts.join(_sep);

  for (final root in tryRoots) {
    final dir = _join(root, relDir);
    final candidate = _join(dir, '$name.kt');
    if (File(candidate).existsSync()) return _normalize(candidate);
  }
  return null;
}

String? _resolvePackageDir(String cwd, String pkgPath) {
  final tryRoots = <String>[
    _join(cwd, 'src${_sep}main${_sep}kotlin'),
    _join(cwd, 'src${_sep}test${_sep}kotlin'),
    _join(cwd, 'src'),
    cwd,
  ];
  final relDir = pkgPath.replaceAll('.', _sep);
  for (final root in tryRoots) {
    final dir = _join(root, relDir);
    final d = Directory(dir);
    if (d.existsSync()) return _normalize(d.path);
  }
  return null;
}

String _packageDirForFile(String relFile) {
  final s = relFile.replaceAll('\\', '/');
  final i = s.lastIndexOf('/');
  return i < 0 ? '' : s.substring(0, i);
}

String _relDir(String absDir, String from) {
  final T = _normalize(absDir);
  final F = _normalize(_abs(from));
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T;
}

String _externalForImport(String importPath) {
  if (importPath.startsWith('kotlin.')) {
    final top = importPath.split('.').take(2).join('.');
    return 'kotlin:$top';
  }
  if (importPath.startsWith('java.')) {
    final top = importPath.split('.').take(2).join('.');
    return 'java:$top';
  }
  final segs = importPath.split('.');
  if (segs.length >= 2) return 'mvn:${segs[0]}.${segs[1]}';
  return 'mvn:${segs[0]}';
}

// ---------------- graph utils ----------------
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
    for (final y in outs) {
      stack.add(y);
    }
  }
  return seen;
}

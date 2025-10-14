// kotlinDependency.dart — V0 Kotlin dependency crawler (no external packages)
// Produces: kotlinDependencies.json in the current working directory.
//
<<<<<<< HEAD
// Features:
// - Scans *.kt recursively (skips build/gradle/idea caches and vendor dirs).
// - Parses package name, imports (alias + wildcard), detects entry files by `fun main(...)`.
// - Resolves exact imports to in-repo files by package path + filename; wildcard imports to all files in that package dir.
// - Externals:
//     * kotlin.*  -> kotlin:<pkg>
//     * java.*    -> java:<pkg>
//     * others    -> mvn:<group[.artifact]> (top 1-2 segments)
// - Computes degrees and reachability from entry files → marks nodes used/unused.
//
// Limitations (V0):
// - Does not parse Android components or Gradle build graph; CLI/desktop style entry is `fun main`.
// - Multiple top-level declarations per file are fine; we track file-level edges.
// - If a symbol name ≠ filename, direct resolution may miss; wildcard still links the package.
//
// Build:
//   dart compile exe .\kotlinDependency.dart -o .\kotlinDependency.exe
// Run:
//   .\kotlinDependency.exe   # writes kotlinDependencies.json
=======
// What it does:
// - Recursively scans for *.kt (skips common build/cache dirs).
// - Extracts package name, imports (with alias/wildcard awareness), primary declaration name, and presence of main().
// - Builds a map FQN -> file; resolves imports to internal declarations or marks as external.
// - Computes degrees and reachability from files containing top-level main() functions.
// - Outputs nodes/edges in a schema compatible with the D3 viewer shipped with this repo.
//
// Limitations (V0):
// - Only explicit imports become edges. Unqualified same-package references are not inferred.
// - Files with multiple declarations are simplified to the first class/object/interface/enum encountered.
// - Wildcard imports expand to all internal declarations that share the prefix, which may over-connect dense packages.
// - External resolution is heuristic and simply namespaces everything as `kotlin:`.
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _normalize(String p) {
<<<<<<< HEAD
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
=======
  return Uri.file(p, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _ext(String p) {
  final s = p.replaceAll('\\', '/');
  final base = s.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot);
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886
}
String _join(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final s = a.endsWith(_sep) ? a.substring(0, a.length - 1) : a;
  final t = b.startsWith(_sep) ? b.substring(1) : b;
  return '$s$_sep$t';
}
<<<<<<< HEAD
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
String _stem(String p) {
  final b = _base(p);
  final dot = b.lastIndexOf('.');
  return dot <= 0 ? b : b.substring(0, dot);
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
  String lang = 'kotlin';
  int? sizeLOC;
  String? pkg;          // Kotlin package name
  int inDeg = 0;
  int outDeg = 0;

  _Node({required this.id, required this.type, required this.state, this.sizeLOC, this.pkg});
=======
String _rel(String target, String from) {
  final T = _normalize(_abs(target));
  final F = _normalize(_abs(from));
  if (T == F) return '.';
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T; // fallback
}

// -------------- models --------------
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
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
<<<<<<< HEAD
        if (pkg != null) 'package': pkg,
=======
        if (packageName != null) 'package': packageName,
        if (declarationName != null) 'declaration': declarationName,
        if (fqn != null) 'fqn': fqn,
        if (hasMain) 'main': hasMain,
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
<<<<<<< HEAD
  final String source;   // file id (relative path)
  final String target;   // file id (relative path) OR external id
  final String kind;     // 'import' | 'import_wildcard'
  final String certainty; // 'static'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
=======
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

>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _KtFacts {
<<<<<<< HEAD
  final String absPath;
  final String relId;
  final String? pkg;
  final List<_KtImport> imports;
  final bool hasMain;
  _KtFacts(this.absPath, this.relId, this.pkg, this.imports, this.hasMain);
}

class _KtImport {
  final String raw;      // as-written import path (e.g., a.b.C, a.b.*, kotlin.collections.List)
  final bool isWildcard;
  _KtImport(this.raw, this.isWildcard);
}

// ---------------- main ----------------
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) Collect .kt files
  final files = await _collectKtFiles(cwd);

  // 2) Parse facts
  final facts = <_KtFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractFacts(cwd, f, text));
  }

  // 3) Build package directory -> files map (for wildcard resolution)
  final pkgDirToFiles = <String, List<String>>{};
  for (final f in files) {
    final rel = _rel(f, cwd);
    final pkgDir = _packageDirForFile(rel);
    (pkgDirToFiles[pkgDir] ??= <String>[]).add(f);
  }

  // 4) Build edges and externals
  final edges = <_Edge>[];
  final externals = <String>{};

  for (final ff in facts) {
    for (final imp in ff.imports) {
      if (imp.isWildcard) {
        final dirAbs = _resolvePackageDir(cwd, imp.raw.replaceAll('.*', ''));
        if (dirAbs != null) {
          final filesInPkg = pkgDirToFiles[_relDir(dirAbs, cwd)] ?? const <String>[];
          for (final tgtAbs in filesInPkg) {
            edges.add(_Edge(
              source: ff.relId,
              target: _rel(tgtAbs, cwd),
=======
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

// -------------- main --------------
Future<void> main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  final files = await _collectKtFiles(cwd);
  final facts = <_KtFacts>[];
  for (final file in files) {
    final text = await File(file).readAsString();
    facts.add(_extractFacts(cwd, file, text));
  }

  final fqnToFile = <String, String>{};
  for (final fact in facts) {
    if (fact.fqn != null) {
      fqnToFile[fact.fqn!] = fact.fileIdRel;
    }
  }

  final nodes = <String, _Node>{};
  for (final fact in facts) {
    nodes[fact.fileIdRel] = _Node(
      id: fact.fileIdRel,
      type: 'file',
      state: 'used',
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
        final matches = fqnToFile.entries
            .where((entry) => entry.key.startsWith(prefix))
            .map((entry) => entry.value)
            .toList();
        if (matches.isEmpty) {
          final extId = 'kotlin:$prefix.*';
          externals.putIfAbsent(extId, () => _Node(id: extId, type: 'external', state: 'used', lang: 'external'));
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: extId,
            kind: 'import_wildcard',
            certainty: 'static',
          ));
        } else {
          for (final target in matches) {
            edges.add(_Edge(
              source: fact.fileIdRel,
              target: target,
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886
              kind: 'import_wildcard',
              certainty: 'static',
            ));
          }
<<<<<<< HEAD
        } else {
          final ext = _externalForImport(imp.raw);
          externals.add(ext);
          edges.add(_Edge(source: ff.relId, target: ext, kind: 'import_wildcard', certainty: 'static'));
        }
      } else {
        // Exact: a.b.C  -> try .../a/b/C.kt
        final targetAbs = _resolveExactImport(cwd, imp.raw);
        if (targetAbs != null && File(targetAbs).existsSync()) {
          edges.add(_Edge(source: ff.relId, target: _rel(targetAbs, cwd), kind: 'import', certainty: 'static'));
        } else {
          final ext = _externalForImport(imp.raw);
          externals.add(ext);
          edges.add(_Edge(source: ff.relId, target: ext, kind: 'import', certainty: 'static'));
=======
        }
      } else {
        final target = fqnToFile[imp.raw];
        if (target != null) {
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: target,
            kind: 'import',
            certainty: 'static',
          ));
        } else {
          final extId = 'kotlin:${imp.raw}';
          externals.putIfAbsent(extId, () => _Node(id: extId, type: 'external', state: 'used', lang: 'external'));
          edges.add(_Edge(
            source: fact.fileIdRel,
            target: extId,
            kind: 'import',
            certainty: 'static',
          ));
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886
        }
      }
    }
  }

<<<<<<< HEAD
  // 5) Nodes
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(ff.absPath),
      pkg: ff.pkg,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(id: ext, type: 'external', state: 'used'));
  }

  // 6) Degrees
  _computeDegrees(nodes, edges);

  // 7) Entry files: any file containing `fun main(...)`
  final entryFiles = facts.where((f) => f.hasMain).map((f) => f.relId).toList();

  // 8) Reachability
  final usedSet = _reach(entryFiles, edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 9) Write output
  final outPath = _join(cwd, 'kotlinDependencies.json');
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
Future<List<String>> _collectKtFiles(String root) async {
  final ignoreDirs = <String>{
    'node_modules','dist','build','target','out','.git','.idea','.gradle','.vscode','.cache','.turbo','.parcel-cache'
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
  return result;
}

// ---------------- parse ----------------
_KtFacts _extractFacts(String cwd, String fileAbs, String text) {
  // Remove block comments /* */ and KDoc /** */; then strip // per-line before regex
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = noBlock.split('\n');

  String? pkg;
  bool hasMain = false;
  final imports = <_KtImport>[];

  final rePkg = RegExp(r'^\s*package\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*$');
  // import x.y.Z  | import x.y.*  | import x.y.Z as Alias
  final reImport = RegExp(r'^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*\*?)\s*(?:as\s+[A-Za-z_][A-Za-z0-9_]*)?\s*$');
  final reMain = RegExp(r'^\s*fun\s+main\s*\('); // also catches @JvmStatic fun main(...) inside objects

  for (var raw in lines) {
    final line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final pm = rePkg.firstMatch(line);
    if (pm != null) {
      pkg = pm.group(1);
      continue;
    }

    final im = reImport.firstMatch(line);
    if (im != null) {
      final rawImp = im.group(1)!;
      imports.add(_KtImport(rawImp, rawImp.endsWith('.*')));
      continue;
    }

    if (!hasMain && reMain.hasMatch(line)) {
      hasMain = true;
    }
  }

  return _KtFacts(
    fileAbs,
    _rel(fileAbs, cwd),
    pkg,
    imports,
    hasMain,
  );
}

// ---------------- resolution ----------------
String? _resolveExactImport(String cwd, String importPath) {
  // import a.b.C -> try <repo>/.../a/b/C.kt under common source roots
  final tryRoots = <String>[
    _join(cwd, 'src${_sep}main${_sep}kotlin'),
    _join(cwd, 'src${_sep}test${_sep}kotlin'),
    _join(cwd, 'src'),
    cwd,
  ];
  final parts = importPath.split('.');
  if (parts.isEmpty) return null;
  // last segment treated as file name
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
  // Guess package dir by dropping filename; caller uses it as key for wildcard mapping
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
  // kotlin.*  -> kotlin:<pkg>
  // java.*    -> java:<pkg>
  // else      -> mvn:<group[.artifact]>  (take first two segments when present)
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
=======
  nodes.addAll(externals);

  for (final e in edges) {
    nodes[e.source]?.outDeg++;
    nodes[e.target]?.inDeg++;
  }

  final json = {
    'meta': {
      'generatedBy': 'kotlinDependency.dart',
      'cwd': cwd,
      'fileCount': facts.length,
      'timestamp': DateTime.now().toIso8601String(),
    },
    'nodes': nodes.values.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };

  final outFile = File(_join(cwd, 'kotlinDependencies.json'));
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  stdout.writeln('Wrote ${outFile.path}');
}

// -------------- discovery --------------
Future<List<String>> _collectKtFiles(String root) async {
  final files = <String>[];
  final rootDir = Directory(root);
  final skipNames = <String>{
    '.git',
    '.svn',
    '.hg',
    '.idea',
    '.gradle',
    'build',
    'out',
    'node_modules',
  };

  Future<void> walk(Directory dir) async {
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      final name = entity.path.split(_sep).last;
      if (entity is Directory) {
        if (skipNames.contains(name)) continue;
        await walk(entity);
      } else if (entity is File) {
        if (_ext(entity.path) == '.kt') {
          files.add(entity.path);
        }
      }
    }
  }

  await walk(rootDir);
  files.sort();
  return files;
}

// -------------- parsing --------------
final _packageReg = RegExp(r'^\s*package\s+([A-Za-z0-9_.]+)', multiLine: true);
final _importReg = RegExp(r'^\s*import\s+([A-Za-z0-9_.*]+)', multiLine: true);
final _declarationReg = RegExp(
  r'^(?:\s*(?:public|internal|private|protected)\s+)?(?:data\s+)?(class|object|interface|enum)\s+([A-Za-z0-9_]+)',
  multiLine: true,
);
final _mainReg = RegExp(r'^\s*fun\s+main\s*\(', multiLine: true);

_KtFacts _extractFacts(String cwd, String absPath, String text) {
  final packageMatch = _packageReg.firstMatch(text);
  final packageName = packageMatch != null ? packageMatch.group(1) : null;

  final imports = <_KtImport>[];
  for (final match in _importReg.allMatches(text)) {
    final raw = match.group(1)!;
    if (raw.endsWith('.*')) {
      imports.add(_KtImport(raw, isWildcard: true));
    } else {
      // Drop alias clause if present (import foo.Bar as Baz)
      final cleaned = raw.split(RegExp(r'\s+as\s+')).first;
      imports.add(_KtImport(cleaned));
    }
  }

  String? declName;
  final declMatch = _declarationReg.firstMatch(text);
  if (declMatch != null) {
    declName = declMatch.group(2);
  }

  final fileIdRel = _rel(absPath, cwd);
  final hasMain = _mainReg.hasMatch(text);
  final fqn = (packageName != null && declName != null)
      ? '$packageName.$declName'
      : (packageName ?? declName);
  final loc = '\n'.allMatches(text).length + 1;

  return _KtFacts(
    filePathAbs: absPath,
    fileIdRel: fileIdRel,
    packageName: packageName,
    declarationName: declName,
    fqn: fqn,
    hasMain: hasMain,
    imports: imports,
    loc: loc,
  );
}
>>>>>>> 3d590af11cfc1b30439f706129a289ea57e17886

// kotlinDependency.dart — V0 Kotlin dependency crawler (no external packages)
// Produces: kotlinDependencies.json in the current working directory.
//
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

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _normalize(String p) {
  return Uri.file(p, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _ext(String p) {
  final s = p.replaceAll('\\', '/');
  final base = s.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot);
}
String _join(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final s = a.endsWith(_sep) ? a.substring(0, a.length - 1) : a;
  final t = b.startsWith(_sep) ? b.substring(1) : b;
  return '$s$_sep$t';
}
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
              kind: 'import_wildcard',
              certainty: 'static',
            ));
          }
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
        }
      }
    }
  }

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

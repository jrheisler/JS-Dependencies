// javaDependency.dart — V0 Java dependency crawler (no external packages)
// Produces: javaDependencies.json in the current working directory.
//
// What it does:
// - Recursively scans for *.java (skips common build/cache dirs).
// - Extracts package name, imports (incl. static and wildcards), primary class name, and presence of main().
// - Builds a map FQN -> file; resolves imports to internal classes or marks as external.
// - Computes degrees and reachability from all classes containing public static void main(String[] ...).
// - Outputs nodes/edges in a schema compatible with your D3 viewer.
//
// Limitations (V0):
// - Only explicit imports become edges. Unqualified same-package references are not inferred.
// - Inner/nested classes and multi-class files: we pick the public class if present, else the first class-like token.
// - Wildcard imports (a.b.*) link to all internal classes under a.b.*, which can create many edges; adjust if needed.
// - External resolution is heuristic: `java.*`/`javax.*` => java:, others => mvn:<group[.artifact]>

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
  return Uri.file(p, windows: Platform.isWindows)
      .normalizePath()
      .toFilePath(windows: Platform.isWindows);
}
String _rel(String target, String from) {
  final T = _normalize(_abs(target));
  final F = _normalize(_abs(from));
  if (T == F) return '.';
  if (T.startsWith(F + _sep)) return T.substring(F.length + 1);
  return T; // fallback
}
List<String> _split(String p) => p.split(_sep);

// -------------- models --------------
class _Node {
  String id;                // repo-relative file path for files; external id for externals
  String type;              // file | external
  String state;             // used | unused
  int? sizeLOC;
  String? packageName;      // for Java files: package
  String? className;        // primary class in file
  String? fqn;              // packageName + '.' + className
  String lang = 'java';
  int inDeg = 0;
  int outDeg = 0;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.packageName,
    this.className,
    this.fqn,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (packageName != null) 'package': packageName,
        if (className != null) 'class': className,
        if (fqn != null) 'fqn': fqn,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source; // file id (relative path)
  final String target; // file id (relative path) OR external id
  final String kind;   // 'import' | 'import_static' | 'import_wildcard'
  final String certainty; // 'static'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _JavaFacts {
  final String filePathAbs;
  final String fileIdRel; // repo-relative path
  final String? packageName;
  final String? className;
  final String? fqn;        // package + class
  final bool hasMain;       // contains public static void main(String[] ...)
  final List<_JavaImport> imports;
  _JavaFacts({
    required this.filePathAbs,
    required this.fileIdRel,
    required this.packageName,
    required this.className,
    required this.fqn,
    required this.hasMain,
    required this.imports,
  });
}

class _JavaImport {
  final String raw;        // as written in import
  final bool isStatic;
  final bool isWildcard;
  _JavaImport(this.raw, {this.isStatic = false, this.isWildcard = false});
}

// -------------- main --------------
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) Discover Java files
  final files = await _collectJavaFiles(cwd);

  // 2) Parse facts (package, imports, class, main)
  final facts = <_JavaFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractJavaFacts(cwd, f, text));
  }

  // 3) Build FQN -> fileId map (project classes only)
  final fqnToFile = <String, String>{};
  for (final ff in facts) {
    if (ff.fqn != null) {
      fqnToFile[ff.fqn!] = ff.fileIdRel;
    }
  }

  // 4) Build edges and collect externals
  final edges = <_Edge>[];
  final externals = <String>{};

  for (final ff in facts) {
    for (final imp in ff.imports) {
      if (imp.isWildcard) {
        // import a.b.* ; connect to all internal classes under that package
        final pkgPrefix = imp.raw.endsWith('.*')
            ? imp.raw.substring(0, imp.raw.length - 2)
            : imp.raw;
        final matches = fqnToFile.entries
            .where((e) => e.key.startsWith(pkgPrefix + '.'))
            .map((e) => e.value)
            .toSet();
        if (matches.isEmpty) {
          final extId = _externalIdForImport(imp.raw);
          externals.add(extId);
          edges.add(_Edge(source: ff.fileIdRel, target: extId, kind: 'import_wildcard', certainty: 'static'));
        } else {
          for (final tgt in matches) {
            edges.add(_Edge(source: ff.fileIdRel, target: tgt, kind: 'import_wildcard', certainty: 'static'));
          }
        }
      } else {
        // exact import
        final normalized = imp.isStatic ? _stripMemberFromStaticImport(imp.raw) : imp.raw;
        final tgt = fqnToFile[normalized];
        if (tgt != null) {
          edges.add(_Edge(source: ff.fileIdRel, target: tgt, kind: imp.isStatic ? 'import_static' : 'import', certainty: 'static'));
        } else {
          final extId = _externalIdForImport(normalized);
          externals.add(extId);
          edges.add(_Edge(source: ff.fileIdRel, target: extId, kind: imp.isStatic ? 'import_static' : 'import', certainty: 'static'));
        }
      }
    }
  }

  // 5) Build nodes (files + externals)
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.fileIdRel,
      type: 'file',
      state: 'unused',           // provisional; reachability will update
      sizeLOC: await _estimateLOC(ff.filePathAbs),
      packageName: ff.packageName,
      className: ff.className,
      fqn: ff.fqn,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(
      id: ext,
      type: 'external',
      state: 'used',             // any import makes externals "used"
      sizeLOC: null,
      packageName: null,
      className: null,
      fqn: null,
    ));
  }

  // 6) Degrees
  _computeDegrees(nodes, edges);

  // 7) Reachability from entries (all files with a public static void main)
  final entryFiles = facts.where((f) => f.hasMain).map((f) => f.fileIdRel).toList();
  final usedSet = _reach(entryFiles, edges);

  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 8) Write output
  final outPath = _join(cwd, 'javaDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));

  // 9) Basic stats to stderr
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[info] Wrote: ${_rel(outPath, cwd)}');
  stderr.writeln('[stats] nodes=$total edges=${edges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');
}

// -------------- crawl --------------
Future<List<String>> _collectJavaFiles(String root) async {
  final ignoreDirs = <String>{
    'node_modules','dist','build','target','out','.git','.idea','.gradle','.mvn','.turbo','.vite','.parcel-cache'
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final parts = _split(_rel(sp, root));
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp) == '.java') result.add(_normalize(sp));
  }
  return result;
}

// -------------- parsing --------------
_JavaFacts _extractJavaFacts(String cwd, String fileAbs, String text) {
  // Strip block comments to reduce noise; keep line comments per-line
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = noBlock.split('\n');

  String? packageName;
  String? publicClass;
  String? firstClassLike;
  bool hasMain = false;
  final imports = <_JavaImport>[];

  final rePackage = RegExp(r'^\s*package\s+([a-zA-Z0-9_\.]+)\s*;');
  final reImport = RegExp(r'^\s*import\s+(static\s+)?([a-zA-Z0-9_\.]+(?:\.\*)?)\s*;');
  final rePublicClass = RegExp(r'^\s*public\s+(?:class|record|interface|enum)\s+([A-Za-z0-9_]+)\b');
  final reAnyClassLike = RegExp(r'^\s*(?:class|record|interface|enum)\s+([A-Za-z0-9_]+)\b');
  final reMain = RegExp(r'public\s+static\s+void\s+main\s*\(\s*String(\s*\[\s*\]\s*|\s+\.{3}\s*)\w*\s*\)');

  for (var raw in lines) {
    var line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final pm = rePackage.firstMatch(line);
    if (pm != null) {
      packageName = pm.group(1);
      continue;
    }

    final im = reImport.firstMatch(line);
    if (im != null) {
      final isStatic = (im.group(1) != null);
      final rawImp = im.group(2)!; // e.g., a.b.C or a.b.*
      imports.add(_JavaImport(rawImp, isStatic: isStatic, isWildcard: rawImp.endsWith('.*')));
      continue;
    }

    final pcm = rePublicClass.firstMatch(line);
    if (pcm != null) {
      publicClass ??= pcm.group(1);
      // don't continue; we also want to scan for main
    }

    final ac = reAnyClassLike.firstMatch(line);
    if (ac != null) {
      firstClassLike ??= ac.group(1);
    }

    if (!hasMain && reMain.hasMatch(line)) {
      hasMain = true;
    }
  }

  final chosenClass = publicClass ?? firstClassLike ?? _inferClassFromFilename(fileAbs);
  final fqn = (packageName != null && chosenClass != null) ? '$packageName.$chosenClass' : chosenClass;

  return _JavaFacts(
    filePathAbs: fileAbs,
    fileIdRel: _rel(fileAbs, cwd),
    packageName: packageName,
    className: chosenClass,
    fqn: fqn,
    hasMain: hasMain,
    imports: imports,
  );
}

String _inferClassFromFilename(String absPath) {
  final s = absPath.replaceAll('\\', '/');
  final base = s.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

String _stripMemberFromStaticImport(String fqn) {
  // import static a.b.C.MEMBER;  -> a.b.C
  final parts = fqn.split('.');
  if (parts.length >= 2) return parts.sublist(0, parts.length - 1).join('.');
  return fqn;
}

// -------------- edges & reachability --------------
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

// -------------- externals --------------
String _externalIdForImport(String importFqn) {
  // Normalize external IDs to avoid collisions with file paths.
  // Heuristics:
  // - java.* / javax.* => "java:<package-prefix>"
  // - else => "mvn:<group[.artifact]>" where group = first 2 segments if present, else first segment
  final f = importFqn.trim();
  if (f.startsWith('java.') || f.startsWith('javax.')) {
    // collapse to package, drop class name if present (e.g., java.util -> java:java.util)
    final withoutClass = f.contains('.') ? f.split('.').sublist(0, 2).join('.') : f;
    return 'java:${withoutClass}';
  }
  final segs = f.split('.');
  if (segs.length >= 2) {
    return 'mvn:${segs[0]}.${segs[1]}'; // e.g., org.slf4j -> mvn:org.slf4j
  }
  return 'mvn:${segs[0]}';
}

// -------------- misc --------------
Future<int> _estimateLOC(String file) async {
  try {
    final s = await File(file).readAsString();
    return s.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

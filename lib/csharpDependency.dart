// csharpDependency.dart — V0 C# dependency crawler (no external packages)
// Output: csharpDependencies.json in the current working directory.
//
// What it does (heuristics, fast):
// - Recursively scans for *.cs (skips bin/obj/.git/.vs/etc).
// - Parses: namespace (file-scoped or block), using/global using, using static, and alias using.
// - Entry detection: files with static Main(...), files named Program.cs, or project OutputType=Exe.
// - Resolves imports:
//    * If import namespace is defined in repo => edge to an "anchor" file in that namespace.
//    * If `using static A.B.C` => try repo/<...>/A/B/C.cs, else external.
//    * Else external: System.* => dotnet:System, otherwise nuget:<first.two.segments>.
// - Computes degrees, reachability from entries, marks nodes state used/unused.
// - sizeLOC = non-empty lines.
// Limitations:
// - Edges are namespace-level (to an anchor file) rather than symbol-level.
// - Top-level statements detection is heuristic (Program.cs considered entry).
// - No solution/proj graph load; <ProjectReference> and <PackageReference> are not required.
//
// Build:
//   dart compile exe .\csharpDependency.dart -o .\csharpDependency.exe
// Run:
//   .\csharpDependency.exe

import 'dart:convert';
import 'dart:io';

import 'hash_utils.dart';

final _sep = Platform.pathSeparator;

// ---- tiny path utils (no package:path)
String _abs(String p) => File(p).absolute.path;
String _normalize(String p) {
  var x = p;
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(x)) x = '$x\\';
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

// ---- models
class _Node {
  String id;           // repo-relative file path or external id
  String type;         // file | external
  String state;        // used | unused
  String lang = 'csharp';
  int? sizeLOC;
  String? namespaceName;
  int inDeg = 0;
  int outDeg = 0;
  String? sha256;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.namespaceName,
    this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'state': state,
    'lang': lang,
    if (sizeLOC != null) 'sizeLOC': sizeLOC,
    if (namespaceName != null) 'namespace': namespaceName,
    'inDeg': inDeg,
    'outDeg': outDeg,
    if (sha256 != null) 'sha256': sha256,
  };
}

class _Edge {
  final String source, target, kind, certainty;
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {'source': source, 'target': target, 'kind': kind, 'certainty': certainty};
}

class _CsFacts {
  final String absPath;
  final String relId;
  final String? namespaceName;      // declared namespace of the file
  final List<String> usingNamespaces; // e.g., Foo.Bar (no trailing .*)
  final List<String> usingStaticTypes; // e.g., Foo.Bar.Baz (type name at end)
  final bool hasMain;
  _CsFacts(this.absPath, this.relId, this.namespaceName, this.usingNamespaces, this.usingStaticTypes, this.hasMain);
}

// ---- main
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) collect files
  final files = await _collectCsFiles(cwd);

  // 2) parse facts
  final facts = <_CsFacts>[];
  final factsByAbs = <String, _CsFacts>{};
  final fileHashes = <String, String>{};
  for (final f in files) {
    final text = await File(f).readAsString();
    final fact = _extractFacts(cwd, f, text);
    facts.add(fact);
    factsByAbs[fact.absPath] = fact;
    final hash = await fileSha256(f);
    if (hash != null) {
      fileHashes[fact.relId] = hash;
    }
  }

  // 3) build namespace -> files map
  final nsToFiles = <String, List<String>>{};
  for (final ff in facts) {
    if (ff.namespaceName != null && ff.namespaceName!.isNotEmpty) {
      (nsToFiles[ff.namespaceName!] ??= <String>[]).add(ff.absPath);
    }
  }

  // 4) choose anchors for namespaces (file that best represents a namespace)
  final nsAnchor = <String, String>{};
  nsToFiles.forEach((ns, list) {
    // anchor preference: file whose stem matches last segment of ns, else first file
    final last = ns.split('.').last;
    final preferred = list.firstWhere(
      (p) => _stem(p).toLowerCase() == last.toLowerCase(),
      orElse: () => list.first,
    );
    nsAnchor[ns] = preferred;
  });

  // 5) edges + externals
  final edges = <_Edge>[];
  final externals = <String>{};
  final edgeKeys = <String>{};

  void addEdge(_Edge edge) {
    final key = '${edge.source}\u0000${edge.target}\u0000${edge.kind}';
    if (edgeKeys.add(key)) edges.add(edge);
  }

  for (final ff in facts) {
    // using namespaces
    for (final ns in ff.usingNamespaces) {
      final targetAbs = nsAnchor[ns];
      if (targetAbs != null) {
        addEdge(_Edge(
          source: ff.relId,
          target: _rel(targetAbs, cwd),
          kind: 'using',
          certainty: 'static',
        ));
      } else {
        final ext = _externalForNamespace(ns);
        externals.add(ext);
        addEdge(_Edge(source: ff.relId, target: ext, kind: 'using', certainty: 'static'));
      }
    }
    // using static Foo.Bar.Baz -> try resolve file Baz.cs
    for (final fqType in ff.usingStaticTypes) {
      final resolved = _resolveTypeToFile(cwd, fqType);
      if (resolved != null && File(resolved).existsSync()) {
        addEdge(_Edge(
          source: ff.relId,
          target: _rel(resolved, cwd),
          kind: 'using_static',
          certainty: 'static',
        ));
      } else {
        final ext = _externalForType(fqType);
        externals.add(ext);
        addEdge(_Edge(source: ff.relId, target: ext, kind: 'using_static', certainty: 'static'));
      }
    }
  }

  // Files within the same namespace implicitly depend on one another.
  nsToFiles.forEach((ns, list) {
    if (list.length < 2) return;
    final anchorAbs = nsAnchor[ns];
    if (anchorAbs == null) return;
    final anchorFacts = factsByAbs[anchorAbs];
    if (anchorFacts == null) return;
    final anchorRel = anchorFacts.relId;
    for (final abs in list) {
      final facts = factsByAbs[abs];
      if (facts == null) continue;
      if (abs == anchorAbs) continue;
      addEdge(_Edge(
        source: facts.relId,
        target: anchorRel,
        kind: 'namespace_peer',
        certainty: 'heuristic',
      ));
      addEdge(_Edge(
        source: anchorRel,
        target: facts.relId,
        kind: 'namespace_peer',
        certainty: 'heuristic',
      ));
    }
  });

  // 6) nodes
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused', // will be updated after reachability
      sizeLOC: await _estimateLOC(ff.absPath),
      namespaceName: ff.namespaceName,
      sha256: fileHashes[ff.relId],
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(id: ext, type: 'external', state: 'used'));
  }

  // 7) degrees
  _computeDegrees(nodes, edges);

  // 8) entries
  final entryIds = _discoverEntries(cwd, facts);

  // 9) reachability
  final used = _reach(entryIds, edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = used.contains(n.id) ? 'used' : 'unused';
  }

  // 10) write JSON
  final outPath = _join(cwd, 'csharpDependencies.json');
  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));

  // stats
  final total = nodes.length;
  final filesCount = nodes.where((n) => n.type == 'file').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final usedCount = nodes.where((n) => n.type == 'file' && n.state == 'used').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[info] Wrote: ${_rel(outPath, cwd)}');
  stderr.writeln('[stats] files=$filesCount externals=$externCount used=$usedCount nodes=$total edges=${edges.length} maxDeg=$maxDeg');
}

// ---- crawl
Future<List<String>> _collectCsFiles(String root) async {
  final ignoreDirs = <String>{
    'bin','obj','.git','.svn','.hg','.vs','.idea','.vscode','.cache','packages','node_modules','dist','out','artifacts','TestResults'
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final rel = _rel(sp, root);
    final parts = rel.split(_sep);
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp).toLowerCase() == '.cs') result.add(_normalize(sp));
  }
  return result;
}

// ---- parse .cs
_CsFacts _extractFacts(String cwd, String fileAbs, String text) {
  // Strip /* */ and /// XML docs, then remove // comments line-by-line
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '').replaceAll(RegExp(r'^\s*///.*$', multiLine: true), '');
  final lines = noBlock.split('\n');

  String? ns;
  final usingNs = <String>[];
  final usingStatic = <String>[];
  bool hasMain = false;

  // file-scoped: `namespace Foo.Bar;`  block: `namespace Foo.Bar {`
  final reNs = RegExp(r'^\s*namespace\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*;?');
  // using forms:
  // using A.B.C;
  // global using A.B.C;
  // using Alias = A.B.C;
  // using static A.B.C;
  final reUsingSimple = RegExp(r'^\s*(?:global\s+)?using\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*;\s*$');
  final reUsingAlias  = RegExp(r'^\s*using\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*;\s*$');
  final reUsingStatic = RegExp(r'^\s*(?:global\s+)?using\s+static\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*;\s*$');

  // Main detection (static void Main(...), static Task Main(...), async variations)
  final reMain = RegExp(r'\bstatic\s+(?:async\s+)?(?:void|Task|Task<\s*int\s*>)\s+Main\s*\(');

  for (var raw in lines) {
    var line = raw.replaceFirst(RegExp(r'//.*$'), '');

    if (ns == null) {
      final mns = reNs.firstMatch(line);
      if (mns != null) {
        ns = mns.group(1);
        // don't continue — line could also have a using after file-scoped ns; but it's rare
      }
    }

    final ms = reUsingStatic.firstMatch(line);
    if (ms != null) {
      usingStatic.add(ms.group(1)!);
      continue;
    }

    final ma = reUsingAlias.firstMatch(line);
    if (ma != null) {
      usingNs.add(ma.group(1)!);
      continue;
    }

    final mu = reUsingSimple.firstMatch(line);
    if (mu != null) {
      usingNs.add(mu.group(1)!);
      continue;
    }

    if (!hasMain && reMain.hasMatch(line)) hasMain = true;
  }

  // trim trailing .* if user wrote `using A.B.*;` (rare but legal in older docs; not typical C# — normalize)
  final cleanedNs = usingNs.map((s) => s.replaceAll(RegExp(r'\.\*$'), '')).toSet().toList();

  return _CsFacts(
    fileAbs,
    _rel(fileAbs, cwd),
    ns,
    cleanedNs,
    usingStatic,
    hasMain,
  );
}

// ---- resolution helpers
String? _resolveTypeToFile(String cwd, String fqType) {
  // fqType: A.B.C -> try cwd/**/A/B/C.cs under common roots
  final tryRoots = <String>[
    _join(cwd, 'src'),
    _join(cwd, 'Source'),
    cwd,
  ];
  final parts = fqType.split('.');
  if (parts.length < 2) return null;
  final typeName = parts.last;
  final nsDir = parts.sublist(0, parts.length - 1).join(_sep);

  for (final root in tryRoots) {
    final dir = _join(root, nsDir);
    final candidate = _join(dir, '$typeName.cs');
    if (File(candidate).existsSync()) return _normalize(candidate);
  }
  // also search by filename under repo if needed (fallback; could be expensive)
  return null;
}

String _externalForNamespace(String ns) {
  if (ns.startsWith('System')) return 'dotnet:System';
  final segs = ns.split('.');
  if (segs.length >= 2) return 'nuget:${segs[0]}.${segs[1]}';
  return 'nuget:${segs[0]}';
}

String _externalForType(String fqType) {
  final ns = fqType.contains('.') ? fqType.substring(0, fqType.lastIndexOf('.')) : fqType;
  return _externalForNamespace(ns);
}

// ---- entries
List<String> _discoverEntries(String cwd, List<_CsFacts> facts) {
  final entries = <String>{};

  // (a) static Main
  for (final f in facts) {
    if (f.hasMain) entries.add(f.relId);
  }

  // (b) Program.cs (C# 9+ top-level statements)
  for (final f in facts) {
    if (_base(f.absPath).toLowerCase() == 'program.cs') entries.add(f.relId);
  }

  // (c) Any .csproj that looks like an executable, link to Program.cs if present
  final proj = _findCsproj(cwd);
  if (proj != null) {
    final s = File(proj).readAsStringSync();
    final isExe = RegExp(r'<\s*OutputType\s*>\s*Exe\s*<\s*/\s*OutputType\s*>').hasMatch(s);
    if (isExe) {
      final p1 = _join(cwd, 'Program.cs');
      final p2 = _join(cwd, 'src${_sep}Program.cs');
      if (File(p1).existsSync()) entries.add(_rel(p1, cwd));
      if (File(p2).existsSync()) entries.add(_rel(p2, cwd));
      // otherwise rely on (a) or (b)
    }
  }

  if (entries.isEmpty && facts.isNotEmpty) {
    // fallback: the lexicographically first file (keeps the graph from being all "unused" in odd repos)
    entries.add(facts.first.relId);
  }
  return entries.toList();
}

String? _findCsproj(String cwd) {
  try {
    final dir = Directory(cwd);
    final files = dir.listSync().whereType<File>().toList();
    for (final f in files) {
      if (_ext(f.path).toLowerCase() == '.csproj') return _normalize(f.path);
    }
  } catch (_) {}
  return null;
}

// ---- graph utils
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

// ---- misc
Future<int> _estimateLOC(String file) async {
  try {
    final s = await File(file).readAsString();
    return s.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

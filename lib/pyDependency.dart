// pyDependency.dart — V0 Python dependency crawler (no external packages)
// Produces: pyDependencies.json in the current working directory.
//
// What it does:
// - Recursively scans for *.py (skips common build/venv/cache dirs).
// - Extracts absolute and relative imports (import x, from x import y, from . import z).
// - Discovers entry points via:
//     1) if __name__ == "__main__" in files
//     2) pyproject.toml [project.scripts] / [tool.poetry.scripts]
//     3) setup.cfg [options.entry_points] console_scripts
// - Resolves relative imports and simple absolute imports to repo files using package roots
//   (directories with __init__.py). Otherwise marks as external pip:<top_module>.
// - Computes in/out degree and reachability from entries → marks nodes used/unused.
// - No external packages required.
//
// Limitations (V0):
// - Resolution is heuristic; complex sys.path manipulations / runtime path changes aren’t handled.
// - Star imports (`from x import *`) create an edge to module x, not individual names.
// - Namespace packages (PEP 420) without __init__.py are treated as plain folders (best effort).
// - No “side-effect-only” state in Python (imports always execute module top-level).

import 'dart:convert';
import 'dart:io';

// -------- path helpers (no package:path) --------
final _sep = Platform.pathSeparator;

String _abs(String p) => File(p).absolute.path;
String _normalize(String p) {
  var x = p;
  // If we get a bare drive like "C:", make it "C:\"
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
class _PyExport {
  final String name;      // exported symbol name
  final String kind;      // function | class | variable
  final int line;
  _PyExport(this.name, this.kind, this.line);
  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind,
        'line': line,
      };
}

class _PyReexport {
  final String fromModule; // module specifier (relative dots allowed)
  final String name;       // local binding name
  final int line;
  _PyReexport(this.fromModule, this.name, this.line);
  Map<String, dynamic> toJson() => {
        'from': fromModule,
        'name': name,
        'line': line,
      };
}

class _Node {
  String id;            // repo-relative path for files; external id for externals
  String type;          // file | external
  String state;         // used | unused
  String lang = 'python';
  int? sizeLOC;
  String? module;       // e.g., pkg.sub.mod (best-effort)
  int inDeg = 0;
  int outDeg = 0;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.module,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (module != null) 'module': module,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source;   // file id (relative path)
  final String target;   // file id (relative path) OR external id (pip:foo)
  final String kind;     // 'import' | 'from' | 'from_relative' | 'import_star'
  final String certainty; // 'static' | 'heuristic'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _SecurityFinding {
  final String id;
  final String message;
  final String severity;
  final int line;
  final String code;

  _SecurityFinding(this.id, this.message, this.severity, this.line, this.code);

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'severity': severity,
        'line': line,
        'code': code,
      };
}

class _PyImport {
  final String module;     // as-written module path (may be '', meaning relative-only "from . import x")
  final String? name;      // imported name (for from ... import name), null for plain `import`
  final String? asName;    // alias if "as" was used
  final int relDots;       // leading dots for relative imports (0 = absolute)
  final bool star;         // from x import *
  final String kind;       // 'import' | 'from'
  final int line;          // 1-based line number in file (best effort)
  _PyImport(this.module, this.name, this.asName, this.relDots, this.star, this.kind, this.line);
}

class _FileFacts {
  final String absPath;
  final String relId;
  final String? module;       // best-effort module path (pkg.sub.mod)
  final List<_PyImport> imports;
  final bool isMainGuard;     // contains if __name__ == "__main__"
  List<_PyExport> exports = const [];
  List<_PyReexport> reexports = const [];
  List<String> starImports = const [];
  bool hasDunderAll = false;
  List<String>? dunderAll;
  bool uncertainExports = false;
  List<_SecurityFinding> securityFindings = const [];

  _FileFacts(this.absPath, this.relId, this.module, this.imports, this.isMainGuard);
}

// ---------------- main ----------------
void main(List<String> args) async {
  final targetDir = args.isNotEmpty ? args.first : '.';
  final rootDir = Directory(targetDir);
  if (!await rootDir.exists()) {
    stderr.writeln('[error] Directory not found: $targetDir');
    exitCode = 2;
    return;
  }

  final cwd = _normalize(_abs(targetDir));

  // 1) Collect python files
  final files = await _collectPyFiles(cwd);

  // 2) Discover package roots (dirs with __init__.py up the tree)
  final packageRoots = _discoverPackageRoots(files);

  // 3) Parse facts
  final facts = <_FileFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractFacts(cwd, f, text, packageRoots));
  }

  // 4) Build module->file map (for absolute resolution)
  final modToFile = <String, String>{};
  for (final ff in facts) {
    if (ff.module != null) {
      modToFile[ff.module!] = ff.relId;
    }
  }

  // 5) Build edges and externals
  final edges = <_Edge>[];
  final externals = <String>{};

  for (final ff in facts) {
    for (final imp in ff.imports) {
      final resolved = _resolveImport(cwd, ff, imp, modToFile, packageRoots);
      if (resolved != null) {
        edges.add(_Edge(source: ff.relId, target: resolved, kind: _edgeKindFor(imp), certainty: 'static'));
      } else {
        final top = _topModuleFor(imp, ff.module);
        if (top != null && top.isNotEmpty) {
          final extId = 'pip:$top';
          externals.add(extId);
          edges.add(_Edge(source: ff.relId, target: extId, kind: _edgeKindFor(imp), certainty: 'heuristic'));
        }
      }
    }
  }

  // 6) Build nodes
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(ff.absPath),
      module: ff.module,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(
      id: ext,
      type: 'external',
      state: 'used',
      sizeLOC: null,
      module: null,
    ));
  }

  // 7) Degrees
  _computeDegrees(nodes, edges);

  // 8) Entries: main-guard + console_scripts
  final entryFiles = <String>{};
  // (a) main guards
  for (final ff in facts) {
    if (ff.isMainGuard) entryFiles.add(ff.relId);
  }
  // (b) pyproject.toml / setup.cfg console_scripts -> resolve to modules
  entryFiles.addAll(await _discoverConsoleScriptsEntries(cwd, modToFile));

  // 9) Reachability
  final usedSet = _reach(entryFiles.toList(), edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 10) Write output
  final outPath = _join(cwd, 'pyDependencies.json');
  final exportsByFile = <String, Map<String, dynamic>>{};
  for (final ff in facts) {
    final exportGroups = <String, dynamic>{};
    final exportedSymbols = ff.exports.map((e) => e.toJson()).toList();
    if (exportedSymbols.isNotEmpty) {
      exportGroups['exports'] = exportedSymbols;
    }
    final reexportedSymbols = ff.reexports.map((r) => r.toJson()).toList();
    if (reexportedSymbols.isNotEmpty) {
      exportGroups['reexports'] = reexportedSymbols;
    }
    if (ff.starImports.isNotEmpty) {
      exportGroups['starImports'] = List<String>.from(ff.starImports);
    }
    final meta = <String, dynamic>{};
    if (ff.hasDunderAll) {
      meta['hasDunderAll'] = true;
    }
    if (ff.dunderAll != null && ff.dunderAll!.isNotEmpty) {
      meta['dunderAll'] = List<String>.from(ff.dunderAll!);
    }
    if (ff.uncertainExports) {
      meta['uncertain'] = true;
    }
    if (meta.isNotEmpty) {
      exportGroups['meta'] = meta;
    }
    if (exportGroups.isNotEmpty) {
      exportsByFile[ff.relId] = exportGroups;
    }
  }

  final securityFindings = <String, List<Map<String, dynamic>>>{};
  for (final ff in facts) {
    if (ff.securityFindings.isEmpty) continue;
    final findingsJson =
        ff.securityFindings.map((finding) => finding.toJson()).toList();
    securityFindings[ff.relId] =
        findingsJson.map((item) => Map<String, dynamic>.from(item)).toList();
    final absKey = _normalize(ff.absPath);
    if (absKey.isNotEmpty && absKey != ff.relId) {
      securityFindings[absKey] =
          findingsJson.map((item) => Map<String, dynamic>.from(item)).toList();
    }
  }

  final out = {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
    if (exportsByFile.isNotEmpty) 'exports': exportsByFile,
    if (securityFindings.isNotEmpty) 'securityFindings': securityFindings,
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
Future<List<String>> _collectPyFiles(String root) async {
  final ignoreDirs = <String>{
    'node_modules','dist','build','target','out','.git','.idea',
    '.venv','venv','__pycache__','.mypy_cache','.pytest_cache',
    '.ruff_cache','.tox'
  };

  String _relSafe(String abs, String base) {
    // Robust relative path even if base lacks trailing separator or case differs.
    final a = _normalize(abs);
    final b = _normalize(base);
    if (a == b) return '.';
    // Ensure b ends with a separator for prefix strip
    final bWithSep = b.endsWith(_sep) ? b : '$b$_sep';
    return a.startsWith(bWithSep) ? a.substring(bWithSep.length) : a;
  }

  bool _skipRelPath(String relPath) {
    if (relPath.isEmpty || relPath == '.') return false;
    for (final segment in relPath.split(_sep)) {
      if (segment.isEmpty || segment == '.') continue;
      if (ignoreDirs.contains(segment)) return true;
    }
    return false;
  }

  final result = <String>[];
  final stack = <String>[_normalize(root)];
  final seen = <String>{};

  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    final curNorm = _normalize(current);
    if (!seen.add(curNorm)) continue;

    final dir = Directory(curNorm);
    if (!await dir.exists()) continue;

    // List directory entries (don’t crash entire walk on one error)
    late final Stream<FileSystemEntity> listing;
    try {
      listing = dir.list(followLinks: false);
    } catch (e) {
      stderr.writeln('[warn] Unable to list: $curNorm ($e)');
      continue;
    }

    await for (final ent in listing.handleError(
      (error) => stderr.writeln('[warn] Error under $curNorm: $error'),
      test: (e) => e is FileSystemException,
    )) {
      final p = _normalize(ent.path);
      final rel = _relSafe(p, root);
      if (_skipRelPath(rel)) continue;

      final type = await FileSystemEntity.type(p, followLinks: false);
      switch (type) {
        case FileSystemEntityType.file:
          final ext = _ext(p).toLowerCase();
          if (ext == '.py' || ext == '.pyw' || ext == '.pyi') {
            result.add(p);
          }
          break;

        case FileSystemEntityType.directory:
          // Descend into real directories
          stack.add(p);
          break;

        case FileSystemEntityType.link:
          // Optional: follow dir symlinks (disabled by default)
          // If you know your repo uses symlinked python dirs (monorepos), set this to true.
          const followDirSymlinks = false;
          if (followDirSymlinks) {
            try {
              final targetType = await FileSystemEntity.type(p, followLinks: true);
              if (targetType == FileSystemEntityType.directory) {
                stack.add(p);
              }
            } catch (e) {
              stderr.writeln('[warn] Broken symlink or inaccessible: $p ($e)');
            }
          }
          break;

        default:
          // do nothing (sockets/pipes/unknown)
          break;
      }
    }
  }

  // De-dupe, stable sort
  result.sort();
  return result.toSet().toList();
}


// ---------------- package roots ----------------
// Return set of directories that are python packages (contain __init__.py).
Set<String> _discoverPackageRoots(List<String> filesAbs) {
  final dirs = <String>{};
  for (final f in filesAbs) {
    var d = _dir(f);
    while (true) {
      final init = _join(d, '__init__.py');
      if (File(init).existsSync()) dirs.add(_normalize(d));
      final parent = _dir(d);
      if (parent == d) break;
      d = parent;
    }
  }
  return dirs;
}

// ---------------- parsing facts ----------------
_FileFacts _extractFacts(String cwd, String fileAbs, String text, Set<String> packageRoots) {
  final relId = _rel(fileAbs, cwd);

  // Detect main guard (simple forms)
  final isMain = RegExp('__name__\\s*==\\s*[\'\\"]__main__[\'\\"]').hasMatch(text);



  // Determine module path best-effort by walking up with __init__.py
  final module = _modulePathFor(fileAbs, packageRoots);

  // Strip block strings? Python triple-quoted can hold import-like text; keep it simple:
  // We'll ignore lines inside simple triple-quoted blocks as a heuristic.
  final stripped = _stripTripleQuoted(text);

  final imports = <_PyImport>[];
  final lines = stripped.split('\n');

  // Patterns:
  // import pkg[, pkg2 as x]...
  final reImport = RegExp(r'^\s*import\s+([a-zA-Z0-9_\.]+(?:\s+as\s+\w+)?(?:\s*,\s*[a-zA-Z0-9_\.]+(?:\s+as\s+\w+)?)*)\s*$');
  // from ...module import name[, name2] | from . import name
  final reFrom = RegExp(r'^\s*from\s+([\.]*[a-zA-Z0-9_\.]*)\s+import\s+(\*|[a-zA-Z0-9_\.]+(?:\s+as\s+\w+)?(?:\s*,\s*[a-zA-Z0-9_\.]+(?:\s+as\s+\w+)?)*)\s*$');

  for (var idx = 0; idx < lines.length; idx++) {
    final raw = lines[idx];
    final lineNo = idx + 1;
    final line = raw.replaceFirst(RegExp(r'#.*$'), '');

    final m1 = reImport.firstMatch(line);
    if (m1 != null) {
      final list = m1.group(1)!;
      for (final part in list.split(',')) {
        final seg = part.trim();
        if (seg.isEmpty) continue;
        final split = seg.split(RegExp(r'\s+as\s+'));
        final modName = split[0].trim();
        if (modName.isEmpty) continue;
        final alias = split.length > 1 ? split[1].trim() : null;
        imports.add(_PyImport(modName, null, alias, 0, false, 'import', lineNo));
      }
      continue;
    }

    final m2 = reFrom.firstMatch(line);
    if (m2 != null) {
      final modRaw = m2.group(1) ?? '';
      final names = m2.group(2) ?? '';
      final star = names.trim() == '*';
      final dots = RegExp(r'^\.+').firstMatch(modRaw)?.group(0)?.length ?? 0;
      final mod = modRaw.replaceFirst(RegExp(r'^\.+'), ''); // remove leading dots
      if (star) {
        imports.add(_PyImport(mod, null, null, dots, true, 'from', lineNo));
      } else {
        for (final part in names.split(',')) {
          final seg = part.trim();
          if (seg.isEmpty) continue;
          final split = seg.split(RegExp(r'\s+as\s+'));
          final name = split[0].trim();
          if (name.isEmpty) continue;
          final alias = split.length > 1 ? split[1].trim() : null;
          imports.add(_PyImport(mod, name, alias, dots, false, 'from', lineNo));
        }
      }
    }
  }

  final facts = _FileFacts(fileAbs, relId, module, imports, isMain);
  try {
    _populatePythonExports(facts, stripped, text);
  } catch (e, st) {
    stderr.writeln('[warn] export parse failed for ${facts.relId}: $e');
  }
  facts.securityFindings = _collectSecurityFindings(text);
  return facts;

}

String _stripTripleQuoted(String s) {
  // Heuristic: remove """...""" and '''...''' blocks entirely to avoid false positives.
  // This will also remove docstrings, which is okay for dependency scanning.
  var out = s;
  out = out.replaceAll(RegExp(r'"""[\s\S]*?"""', multiLine: true), '\n');
  out = out.replaceAll(RegExp(r"'''[\s\S]*?'''", multiLine: true), '\n');
  return out;
}

void _populatePythonExports(_FileFacts f, String strippedForSyntax, String originalText) {
  final exports = <_PyExport>[];
  final reexports = <_PyReexport>[];
  final starImports = <String>[];

  final lines = strippedForSyntax.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final lineNo = i + 1;
    if (raw.trim().isEmpty) continue;
    final leading = raw.length - raw.replaceFirst(RegExp(r'^[ \t]+'), '').length;
    if (leading != 0) continue;

    final line = raw.replaceFirst(RegExp(r'#.*$'), '').trimRight();
    if (line.isEmpty) continue;

    final mDef = RegExp(r'^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(').firstMatch(line);
    if (mDef != null) {
      exports.add(_PyExport(mDef.group(1)!, 'function', lineNo));
      continue;
    }

    final mClass = RegExp(r'^class\s+([A-Za-z_]\w*)\s*[:(]').firstMatch(line);
    if (mClass != null) {
      exports.add(_PyExport(mClass.group(1)!, 'class', lineNo));
      continue;
    }

    final mAssign = RegExp(r'^([A-Za-z_]\w*)\s*(?::[^\n=]+)?\s*=').firstMatch(line);
    if (mAssign != null) {
      final name = mAssign.group(1)!;
      if (name != '__all__' && !name.startsWith('_')) {
        exports.add(_PyExport(name, 'variable', lineNo));
      }
    }
  }

  for (final imp in f.imports) {
    if (imp.kind == 'from' && imp.star) {
      final fromModule = ''.padLeft(imp.relDots, '.') + imp.module;
      starImports.add(fromModule);
      continue;
    }

    String? localName;
    if (imp.kind == 'import') {
      localName = imp.asName ?? (imp.module.contains('.') ? imp.module.split('.').first : imp.module);
    } else if (imp.name != null) {
      localName = imp.asName ?? imp.name;
    }
    if (localName == null || localName.startsWith('_')) continue;
    final fromModule = ''.padLeft(imp.relDots, '.') + imp.module;
    reexports.add(_PyReexport(fromModule, localName, imp.line));
  }

  final dunderAll = <String>{};
  var hasDunderAll = false;
  var uncertain = false;

  final assignRe = RegExp(
    r'^\s*__all__\s*=\s*([\[(])\s*([^\]\)]*)\s*[\]\)]',
    multiLine: true,
  );
  for (final match in assignRe.allMatches(originalText)) {
    hasDunderAll = true;
    final body = match.group(2) ?? '';
    final items = RegExp(r"""['"]([^'"]+)['"]""")
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    if (items.isNotEmpty) {
      dunderAll.addAll(items);
    } else {
      uncertain = true;
    }
  }

  final plusRe = RegExp(
    r'^\s*__all__\s*\+=\s*\[\s*([^\]]*)\s*\]',
    multiLine: true,
  );
for (final match in plusRe.allMatches(originalText)) {
    hasDunderAll = true;
    final body = match.group(1) ?? '';
    final items = RegExp(r"""['"]([^'"]+)['"]""")
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    if (items.isNotEmpty) {
      dunderAll.addAll(items);
    } else {
      uncertain = true;
    }
  }

  final appendMatches = RegExp(r"""__all__\s*\.\s*append\s*\(\s*['"]([^'"]+)['"]\s*\)""");
  for (final match in appendMatches.allMatches(originalText)) {
    hasDunderAll = true;
    dunderAll.add(match.group(1)!);
  }

  final extendMatches = RegExp(r'__all__\s*\.\s*extend\s*\(\s*\[\s*([^\]]+)\s*\]\s*\)');
  for (final match in extendMatches.allMatches(originalText)) {
    hasDunderAll = true;
    final body = match.group(1) ?? '';
    final items = RegExp(r"""['"]([^'"]+)['"]""").allMatches(body).map((m) => m.group(1)!).toList();
    if (items.isNotEmpty) {
      dunderAll.addAll(items);
    } else {
      uncertain = true;
    }
  }

  f.exports = exports.where((e) => !e.name.startsWith('_')).toList();
  f.reexports = reexports;
  f.starImports = starImports;
  f.hasDunderAll = hasDunderAll;
  f.dunderAll = hasDunderAll && dunderAll.isNotEmpty ? dunderAll.toList() : null;
  f.uncertainExports = (hasDunderAll && dunderAll.isEmpty) || uncertain || starImports.isNotEmpty;
}

String? _modulePathFor(String fileAbs, Set<String> packageRoots) {
  // Build module path from nearest package root down to file.
  // e.g., /repo/pkg/sub/mod.py with pkg and sub both having __init__.py -> pkg.sub.mod
  final parts = <String>[];
  var current = _dir(fileAbs);
  var lastRootIndex = -1;

  // Find the deepest directory on the path that is a package root
  final chain = <String>[];
  var d = _dir(fileAbs);
  while (true) {
    chain.add(_normalize(d));
    final parent = _dir(d);
    if (parent == d) break;
    d = parent;
  }
  // chain: [fileDir, ..., filesystemRoot]
  for (var i = 0; i < chain.length; i++) {
    if (packageRoots.contains(chain[i])) {
      lastRootIndex = i;
      // Keep walking so that we prefer the outermost package root when
      // multiple nested packages exist (pkg/sub/__init__.py, etc.).
    }
  }
  if (lastRootIndex == -1) {
    // Not inside a package; best-effort name is filename without .py
    final base = _base(fileAbs);
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  // Build module from that root to the file
  final rootDir = chain[lastRootIndex];
  final rel = _rel(fileAbs, rootDir).replaceAll('\\', '/');
  if (!rel.contains('/')) {
    // file directly in root package
    final stem = rel.endsWith('.py') ? rel.substring(0, rel.length - 3) : rel;
    return stem == '__init__' ? _base(rootDir) : '${_base(rootDir)}.$stem';
  }
  final comps = rel.split('/');
  // drop .py
  final last = comps.last;
  final stem = last.endsWith('.py') ? last.substring(0, last.length - 3) : last;
  // If file is __init__.py, module is the package path itself
  final chainNames = <String>[];
  // Collect package directory names from rootDir down to fileDir (include dirs)
  final fileDirRel = comps.sublist(0, comps.length - 1);
  for (final dName in fileDirRel) {
    chainNames.add(dName);
  }
  if (stem != '__init__') chainNames.add(stem);
  // Prepend root package directory name
  chainNames.insert(0, _base(rootDir));
  return chainNames.where((s) => s.isNotEmpty).join('.');
}

// ---------------- resolution ----------------
String? _resolveImport(String cwd, _FileFacts from, _PyImport imp, Map<String, String> modToFile, Set<String> packageRoots) {
  // Return repo-relative path if resolved; otherwise null (external)
  // Relative imports
  if (imp.relDots > 0) {
    final fromModule = from.module; // e.g., pkg.sub.mod
    if (fromModule == null) return null;
    final parts = fromModule.split('.');
    if (parts.isEmpty) return null;
    // Go up dots levels (dots==1 -> current package)
    final up = parts.length - imp.relDots;
    if (up < 1) return null;
    final basePkg = parts.sublist(0, up).join('.');
    final targetMod = (imp.module.isNotEmpty)
        ? (basePkg.isEmpty ? imp.module : '$basePkg.${imp.module}')
        : basePkg; // "from . import x" will use name below
    if (imp.star) {
      // from .pkg import *
      final hit = _resolveModuleToFile(cwd, targetMod, packageRoots);
      return hit;
    }
    if (imp.name != null) {
      // from .pkg import name  -> try module ".pkg.name"
      final cand = targetMod.isEmpty ? imp.name! : '$targetMod.${imp.name}';
      final hit = _resolveModuleToFile(cwd, cand, packageRoots) ??
          // try as attribute of module -> fall back to module file
          _resolveModuleToFile(cwd, targetMod, packageRoots);
      return hit;
    }
    return _resolveModuleToFile(cwd, targetMod, packageRoots);
  }

  // Absolute imports
  if (imp.kind == 'import') {
    // "import a.b.c" -> create edge to module 'a' (top-level), but we try to resolve full path if present
    // Try exact module mapping (full name)
    final exact = modToFile[imp.module];
    if (exact != null) return exact;
    // Try path resolve heuristically
    final resolved = _resolveModuleToFile(cwd, imp.module, packageRoots);
    if (resolved != null) return resolved;
    // Fallback: treat as external
    return null;
  } else {
    // "from a.b import c" or "from a import *"
    if (imp.star) {
      final hit = _resolveModuleToFile(cwd, imp.module, packageRoots);
      return hit; // may be null => external
    }
    if (imp.name != null) {
      // Prefer module a.b.c
      final full = imp.module.isEmpty ? imp.name! : '${imp.module}.${imp.name}';
      final hit = modToFile[full] ?? _resolveModuleToFile(cwd, full, packageRoots);
      if (hit != null) return hit;
      // Otherwise fall back to module a.b
      final modHit = _resolveModuleToFile(cwd, imp.module, packageRoots);
      return modHit;
    }
    return _resolveModuleToFile(cwd, imp.module, packageRoots);
  }
}

String? _resolveModuleToFile(String cwd, String module, Set<String> packageRoots) {
  if (module.isEmpty) return null;
  final parts = module.split('.');
  // Try each package root as a base; build path parts under it.
  for (final root in packageRoots) {
    var relativeParts = parts;
    final rootName = _base(root);
    if (relativeParts.isNotEmpty && relativeParts.first == rootName) {
      relativeParts = relativeParts.sublist(1);
    }

    if (relativeParts.isEmpty) {
      final init = _join(root, '__init__.py');
      if (File(init).existsSync()) return _rel(_normalize(init), cwd);
      continue;
    }

    final joined = relativeParts.join(_sep);
    final file1 = _join(root, '$joined.py');
    if (File(file1).existsSync()) return _rel(_normalize(file1), cwd);
    final pkgDir = _join(root, joined);
    final init = _join(pkgDir, '__init__.py');
    if (File(init).existsSync()) return _rel(_normalize(init), cwd);
  }
  // Also try from repo root as a fallback (src-less layout)
  final file2 = _join(cwd, module.replaceAll('.', _sep) + '.py');
  if (File(file2).existsSync()) return _rel(_normalize(file2), cwd);
  final dir2 = _join(cwd, module.replaceAll('.', _sep));
  final init2 = _join(dir2, '__init__.py');
  if (File(init2).existsSync()) return _rel(_normalize(init2), cwd);

  return null;
}

String _edgeKindFor(_PyImport imp) {
  if (imp.star && imp.relDots == 0) return 'import_star';
  if (imp.relDots > 0) return 'from_relative';
  return imp.kind; // 'import' | 'from'
}

String? _topModuleFor(_PyImport imp, String? fromModule) {
  if (imp.relDots > 0) {
    // relative import unresolved: treat as same top module as 'fromModule'
    if (fromModule == null) return null;
    final top = fromModule.split('.').first;
    return top;
  }
  final full = imp.kind == 'import'
      ? imp.module
      : (imp.module.isEmpty ? (imp.name ?? '') : imp.module);
  final top = full.split('.').first;
  return top;
}

// ---------------- entries from config ----------------
Future<Set<String>> _discoverConsoleScriptsEntries(String cwd, Map<String, String> modToFile) async {
  final entries = <String>{};

  // pyproject.toml
  final pyproject = File(_join(cwd, 'pyproject.toml'));
  if (await pyproject.exists()) {
    final s = await pyproject.readAsString();
    // [project.scripts] name = "module:func"
    final block1 = _extractTomlBlock(s, RegExp(r'^\s*\[project\.scripts\]\s*$', multiLine: true));
    for (final line in block1) {
      final m = RegExp(r'^\s*([A-Za-z0-9_\-]+)\s*=\s*\"([A-Za-z0-9_\.\-]+)\s*:\s*[A-Za-z0-9_\.\-]+\"')
          .firstMatch(line);
      if (m != null) {
        final mod = m.group(2)!;
        final hit = modToFile[mod];
        if (hit != null) entries.add(hit);
      }
    }
    // [tool.poetry.scripts]
    final block2 = _extractTomlBlock(s, RegExp(r'^\s*\[tool\.poetry\.scripts\]\s*$', multiLine: true));
    for (final line in block2) {
      final m = RegExp(r'^\s*([A-Za-z0-9_\-]+)\s*=\s*\"([A-Za-z0-9_\.\-]+)\s*:\s*[A-Za-z0-9_\.\-]+\"')
          .firstMatch(line);
      if (m != null) {
        final mod = m.group(2)!;
        final hit = modToFile[mod];
        if (hit != null) entries.add(hit);
      }
    }
  }

  // setup.cfg
  final setup = File(_join(cwd, 'setup.cfg'));
  if (await setup.exists()) {
    final s = await setup.readAsString();
    // [options.entry_points] console_scripts
    final block = _extractIniBlock(s, 'options.entry_points');
    final consoleLines = _extractIniOptionValues(block, 'console_scripts');
    for (final raw in consoleLines) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      // name = module:func
      final m = RegExp(r'^[A-Za-z0-9_\-]+\s*=\s*([A-Za-z0-9_\.\-]+)\s*:\s*[A-Za-z0-9_\.\-]+')
          .firstMatch(line);
      if (m != null) {
        final mod = m.group(1)!;
        final hit = modToFile[mod];
        if (hit != null) entries.add(hit);
      }
    }
  }

  return entries;
}

List<String> _extractTomlBlock(String s, RegExp header) {
  final lines = s.split('\n');
  final out = <String>[];
  var inBlock = false;
  for (final line in lines) {
    if (header.hasMatch(line)) {
      inBlock = true; continue;
    }
    if (inBlock && RegExp(r'^\s*\[').hasMatch(line)) {
      // next section starts
      break;
    }
    if (inBlock) out.add(line);
  }
  return out;
}

List<String> _extractIniBlock(String s, String headerName) {
  final lines = s.split('\n');
  final out = <String>[];
  var inBlock = false;
  final headerRe = RegExp('^\\s*\\[${RegExp.escape(headerName)}\\]\\s*\u0024');
  for (final line in lines) {
    if (headerRe.hasMatch(line)) {
      inBlock = true; continue;
    }
    if (inBlock && RegExp(r'^\s*\[').hasMatch(line)) break;
    if (inBlock) out.add(line);
  }
  return out;
}

List<String> _extractIniOptionValues(List<String> blockLines, String optionName) {
  final values = <String>[];
  final optionRe = RegExp('^\\s*${RegExp.escape(optionName)}\\s*=');
  var capturing = false;
  for (final line in blockLines) {
    if (!capturing) {
      if (optionRe.hasMatch(line)) {
        capturing = true;
        final eq = line.indexOf('=');
        if (eq >= 0) {
          final rest = line.substring(eq + 1).trim();
          if (rest.isNotEmpty) values.add(rest);
        }
      }
      continue;
    }

    final trimmed = line.trimRight();
    if (trimmed.isEmpty) break;
    if (!RegExp(r'^\s').hasMatch(line)) break;
    values.add(trimmed.trim());
  }
  return values;
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

// ---------------- security ----------------
List<_SecurityFinding> _collectSecurityFindings(String text) {
  if (text.trim().isEmpty) return const [];

  final sanitized = _sanitizeForSecurity(text);
  final lineStarts = _computeLineStarts(text);
  final lines = text.split('\n');
  final findings = <_SecurityFinding>[];
  final seen = <String>{};

  String snippetForLine(int line) => _lineAt(lines, line).trim();

  void addFinding(String id, String message, String severity, int offset) {
    final line = _lineNumberForOffset(lineStarts, offset);
    final snippet = snippetForLine(line);
    final key = '$id|$line|$snippet';
    if (seen.add(key)) {
      findings.add(_SecurityFinding(id, message, severity, line, snippet));
    }
  }

  for (final rule in _securityRules) {
    final id = rule['id'] as String;
    final severity = rule['severity'] as String;
    final message = rule['message'] as String;
    final re = rule['re'] as RegExp;
    for (final match in re.allMatches(sanitized)) {
      addFinding(id, message, severity, match.start);
    }
  }

  for (final rule in _securityRulesRaw) {
    final id = rule['id'] as String;
    final severity = rule['severity'] as String;
    final message = rule['message'] as String;
    final re = rule['re'] as RegExp;
    for (final match in re.allMatches(text)) {
      addFinding(id, message, severity, match.start);
    }
  }

  return findings;
}

String _sanitizeForSecurity(String text) {
  if (text.isEmpty) return text;
  final chars = text.split('');

  void blankOut(Match match) {
    for (var i = match.start; i < match.end && i < chars.length; i++) {
      final ch = chars[i];
      if (ch == '\n' || ch == '\r') continue;
      chars[i] = ' ';
    }
  }

  final tripleDouble = RegExp(r'[rRuUbBfF]*"""[\s\S]*?"""', multiLine: true);
  final tripleSingle = RegExp(r"[rRuUbBfF]*'''[\s\S]*?'''", multiLine: true);
  final doubleQuote = RegExp(r'[rRuUbBfF]*"(?:\\.|[^"\\\n])*"');
  final singleQuote = RegExp(r"[rRuUbBfF]*'(?:\\.|[^'\\\n])*'");
  final comments = RegExp(r'#.*$', multiLine: true);

  for (final match in tripleDouble.allMatches(text)) {
    blankOut(match);
  }
  for (final match in tripleSingle.allMatches(text)) {
    blankOut(match);
  }
  for (final match in doubleQuote.allMatches(text)) {
    blankOut(match);
  }
  for (final match in singleQuote.allMatches(text)) {
    blankOut(match);
  }
  for (final match in comments.allMatches(text)) {
    blankOut(match);
  }

  return chars.join();
}

List<int> _computeLineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) {
      starts.add(i + 1);
    }
  }
  return starts;
}

int _lineNumberForOffset(List<int> starts, int offset) {
  var low = 0;
  var high = starts.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final value = starts[mid];
    if (value <= offset) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  final result = high + 1;
  if (result < 1) return 1;
  if (result > starts.length) return starts.length;
  return result;
}

String _lineAt(List<String> lines, int lineNumber) {
  if (lineNumber < 1 || lineNumber > lines.length) return '';
  return lines[lineNumber - 1];
}

// ---------------- Python security rule catalog ----------------
// CLEAN rules (run on source with strings/comments stripped)
final _securityRules = <Map<String, dynamic>>[
  {
    'id': 'py.eval.call',
    'severity': 'high',
    'message': 'Use of eval() can execute arbitrary code.',
    're': RegExp(r'\beval\s*\('),
  },
  {
    'id': 'py.exec.call',
    'severity': 'high',
    'message': 'Use of exec() can execute arbitrary code.',
    're': RegExp(r'\bexec\s*\('),
  },
  {
    'id': 'py.os.system',
    'severity': 'high',
    'message': 'os.system executes a shell command.',
    're': RegExp(r'\bos\.system\s*\('),
  },
  {
    'id': 'py.subprocess.shell',
    'severity': 'high',
    'message': 'subprocess invocation with shell=True can execute shell commands.',
    're': RegExp(r'\bsubprocess\.(?:Popen|run|call|check_output)\s*\([^)]*shell\s*=\s*True',
        caseSensitive: false),
  },
  {
    'id': 'py.subprocess.cmd_str',
    'severity': 'med',
    'message': 'subprocess called with a string command (consider list args).',
    're': RegExp(r'''\bsubprocess\.(?:Popen|run|call|check_output)\s*\(\s*(?:[rRuUbBfF]*["\'])'''),
  },
  {
    'id': 'py.pickle.load',
    'severity': 'high',
    'message': 'pickle.load/loads can deserialize untrusted data.',
    're': RegExp(r'\bpickle\.(?:load|loads)\s*\('),
  },
  {
    'id': 'py.yaml.unsafe_load',
    'severity': 'high',
    'message': 'yaml.load without a SafeLoader can be unsafe.',
    're': RegExp(r'\byaml\.load\s*\('),
  },
  {
    'id': 'py.jsonpickle.decode',
    'severity': 'high',
    'message': 'jsonpickle decoding can reinstantiate arbitrary objects.',
    're': RegExp(r'\bjsonpickle\.(?:decode|Unpickler)\s*\('),
  },
  {
    'id': 'py.marshal.loads',
    'severity': 'high',
    'message': 'marshal.loads can load arbitrary code objects.',
    're': RegExp(r'\bmarshal\.(?:load|loads)\s*\('),
  },
  {
    'id': 'py.requests.verify_false',
    'severity': 'med',
    'message': 'requests called with verify=False disables TLS verification.',
    're': RegExp(r'\brequests\.\w+\s*\([^)]*verify\s*=\s*False', caseSensitive: false),
  },
  {
    'id': 'py.ssl.unverified_context',
    'severity': 'med',
    'message': 'Unverified SSL context disables certificate validation.',
    're': RegExp(r'\bssl\._create_unverified_context\s*\('),
  },
  {
    'id': 'py.regex.dynamic',
    'severity': 'med',
    'message': 'Regular expression compiled from a variable (review for ReDoS).',
    're': RegExp(r'\bre\.compile\s*\(\s*[A-Za-z_]\w*'),
  },
  {
    'id': 'py.crypto.weak_hash',
    'severity': 'med',
    'message': 'Weak hash algorithm (md5/sha1) detected.',
    're': RegExp(r'\bhashlib\.(?:md5|sha1)\s*\('),
  },
  {
    'id': 'py.random.for_tokens',
    'severity': 'med',
    'message': 'random.* is not suitable for secrets/tokens.',
    're': RegExp(r'\brandom\.(?:random|randrange|randint|choice)\s*\('),
  },
  {
    'id': 'py.jwt.decode.unsafe',
    'severity': 'med',
    'message': 'jwt.decode called without algorithm/issuer/audience validation.',
    're': RegExp(r'\bjwt\.decode\s*\('),
  },
  {
    'id': 'py.zip.extraction',
    'severity': 'high',
    'message': 'Archive extraction (extractall) can allow Zip-Slip without path validation.',
    're': RegExp(r'\b(?:zipfile|tarfile)\.[A-Za-z_]\w*extractall\s*\('),
  },
  {
    'id': 'py.tempfile.insecure',
    'severity': 'med',
    'message': 'tempfile.mktemp() is insecure; use NamedTemporaryFile.',
    're': RegExp(r'\btempfile\.mktemp\s*\('),
  },
  {
    'id': 'py.fs.world_perms',
    'severity': 'med',
    'message': 'World-writable permissions (0o777) or umask(0).',
    're': RegExp(r'\bos\.(?:chmod\s*\([^,]+,\s*0o?777\b|umask\s*\(\s*0\s*\))'),
  },
  {
    'id': 'py.ssrf.dynamic_url',
    'severity': 'high',
    'message': 'HTTP request built from a non-literal URL (possible SSRF).',
    're': RegExp(r'''\brequests\.(?:get|post|put|delete|patch|head|options)\s*\(\s*(?![rRuUbBfF]?["\'])'''),
  },
  {
    'id': 'py.open_redirect',
    'severity': 'high',
    'message': 'Redirect target appears non-literal (potential open redirect).',
    're': RegExp(r'''\bredirect\s*\(\s*(?![rRuUbBfF]?["\'])'''),
  },
  {
    'id': 'py.sql.concat',
    'severity': 'high',
    'message': 'SQL built by string concatenation or f-strings.',
    're': RegExp(r'\b(?:execute|executemany)\s*\(\s*[^)]*(?:[+{])', caseSensitive: false),
  },
  {
    'id': 'py.cookie.insecure',
    'severity': 'med',
    'message': 'Cookie set without security flags (review HttpOnly/Secure/SameSite).',
    're': RegExp(r'\.set_cookie\s*\('),
  },
  {
    'id': 'py.importlib.dynamic',
    'severity': 'med',
    'message': 'Dynamic import via importlib.import_module.',
    're': RegExp(r'\bimportlib\.import_module\s*[(]'),
  },
];

// RAW rules (run on original text; needed for content inside string literals / settings)
final _securityRulesRaw = <Map<String, dynamic>>[
  {
    'id': 'py.django.debug_true',
    'severity': 'low',
    'message': 'Django DEBUG = True.',
    're': RegExp(r'^\\s*DEBUG\\s*=\\s*True\\b', multiLine: true),
  },
  {
    'id': 'py.django.allowed_hosts_any',
    'severity': 'med',
    'message': 'Django ALLOWED_HOSTS allows any host.',
    're': RegExp(r'''^\\s*ALLOWED_HOSTS\\s*=\\s*\\[\\s*["\']\\*\\s*["\']\\s*\\]''', multiLine: true),
  },
  {
    'id': 'py.cors.wildcard',
    'severity': 'med',
    'message': 'CORS wildcard origin header.',
    're': RegExp(r'''Access-Control-Allow-Origin\\s*[:=]\\s*["\']\\*["\']'''),
  },
  {
    'id': 'py.cors.credentialsWildcard',
    'severity': 'high',
    'message': 'CORS allows credentials with wildcard origin.',
    're': RegExp(r'''Access-Control-Allow-Credentials\\s*[:=]\\s*["\']true["\']''', caseSensitive: false),
  },
  {
    'id': 'py.urllib3.disable_warnings',
    'severity': 'low',
    'message': 'urllib3.disable_warnings() hides TLS warnings.',
    're': RegExp(r'\\burllib3\\.disable_warnings\\s*\\('),
  },
  {
    'id': 'py.secret.literal',
    'severity': 'high',
    'message': 'Possible hard-coded secret (API key/token/password).',
    're': RegExp(r'''(API[_-]?KEY|SECRET[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\\s*[:=]\\s*["\'][A-Za-z0-9_\\-\\.=+/]{12,}["\']'''),
  },
  {
    'id': 'py.env.access',
    'severity': 'low',
    'message': 'Access to environment variables (review for secrets).',
    're': RegExp(r'''\\bos\\.environ\\[\\s*["\'][A-Za-z_]\\w*["\']\\s*\\]'''),
  },
  {
    'id': 'py.logging.secrets',
    'severity': 'low',
    'message': 'Logging may include sensitive keywords.',
    're': RegExp(r'\\b(?:print|logging\\.\\w+)\\s*\\([^)]*(password|secret|token|api[_-]?key|auth|credential)[^)]*\\)',
        caseSensitive: false),
  },
  {
    'id': 'py.fs.dotdot',
    'severity': 'high',
    'message': 'Path traversal sequence (“..” path) appears in path.',
    're': RegExp(r'(\\.\\./|\\.\\.\\\\)'),
  },
  {
    'id': 'py.jwt.none_alg',
    'severity': 'high',
    'message': 'JWT algorithms allowlist includes "none".',
    're': RegExp(r'algorithms\\s*=\\s*\\[[^\\]]*\\bnone\\b[^\\]]*\\]', caseSensitive: false),
  },
  {
    'id': 'py.http.cleartext',
    'severity': 'med',
    'message': 'Cleartext HTTP URL (non-localhost).',
    're': RegExp(r'http://(?!localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)'),
  },
];

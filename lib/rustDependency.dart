// rustDependency.dart — V0 Rust dependency crawler (no external packages)
// Produces: rustDependencies.json in the current working directory.
//
// Features:
// - Recursively scans for *.rs (skips target, git, build, etc.)
// - Parses: `mod name;`, `use path::...;`, `extern crate name;`
// - Detects entries: files with `fn main(...)` and paths from Cargo.toml [[bin]] sections
// - Reads Cargo.toml to learn dependency names (externals) and bin targets
// - Resolves `mod name;` to <dir>/name.rs or <dir>/name/mod.rs
// - Resolves common `use` patterns:
//     * use crate::a::b::...  -> resolve from crate src root
//     * use self::a::...      -> resolve from the current file directory
//     * use super::a::...     -> resolve from parent dir
//     * use foo::bar::...     -> if `foo` is a dependency -> external `crate:foo`
//                                else try resolve from crate root as internal module
// - Computes degrees and reachability from entry files -> marks nodes used/unused
//
// Limitations (V0):
// - Does not parse macros or generated modules; ignores `include!`.
// - `use` resolution is heuristic; complex re-exports and pub(crate) chains are not followed.
// - Workspaces / multiple crates: this scans the current crate (cwd). You can extend to find nested Cargo.toml later.

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
  String lang = 'rust';
  int? sizeLOC;
  String? pkg;          // crate name (from Cargo.toml [package].name), if known
  int inDeg = 0;
  int outDeg = 0;

  _Node({required this.id, required this.type, required this.state, this.sizeLOC, this.pkg});

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'state': state,
        'lang': lang,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (pkg != null) 'crate': pkg,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class _Edge {
  final String source;   // file id (relative path)
  final String target;   // file id (relative path) OR external id (crate:...)
  final String kind;     // 'mod' | 'use' | 'extern'
  final String certainty; // 'static' | 'heuristic'
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'kind': kind,
        'certainty': certainty,
      };
}

class _RustFacts {
  final String absPath;
  final String relId;
  final String pkgName;         // package name (crate name) if known (filled later), else ''
  final List<String> mods;      // module declarations: ["foo","bar"]
  final List<String> externs;   // extern crate names
  final List<String> usePaths;  // raw use paths (e.g., "crate::foo::bar", "serde::de", "self::x", "super::y")
  final bool hasMainFn;
  _RustFacts(this.absPath, this.relId, this.pkgName, this.mods, this.externs, this.usePaths, this.hasMainFn);
}

// ---------------- main ----------------
void main(List<String> args) async {
  final cwd = _normalize(_abs('.'));

  // 1) Read Cargo.toml (dependencies, package name, bin targets)
  final cargo = await _readCargoToml(cwd);
  final crateName = cargo.packageName;
  final depNames = cargo.dependencies; // set of crate names
  final binPaths = cargo.binPaths;     // [[bin]] path => treat as entry files (relative to cwd)

  // 2) Collect rust files
  final files = await _collectRustFiles(cwd);

  // 3) Parse facts
  final facts = <_RustFacts>[];
  for (final f in files) {
    final text = await File(f).readAsString();
    facts.add(_extractFacts(cwd, f, text, crateName ?? ''));
  }

  // Precompute directory -> files map
  final dirToFiles = <String, List<String>>{};
  for (final f in files) {
    final d = _dir(f);
    (dirToFiles[d] ??= <String>[]).add(f);
  }

  // Find crate src roots for resolution: prefer ./src
  final crateSrcRoots = <String>[];
  final srcDir = _join(cwd, 'src');
  if (Directory(srcDir).existsSync()) crateSrcRoots.add(_normalize(srcDir));
  // fallback: crate root itself
  crateSrcRoots.add(cwd);

  // 4) Build edges and externals
  final edges = <_Edge>[];
  final externals = <String>{};

  for (final ff in facts) {
    final src = ff.relId;

    // (a) mod edges
    for (final m in ff.mods) {
      final tgtAbs = _resolveModToFile(ff.absPath, m);
      if (tgtAbs != null && File(tgtAbs).existsSync()) {
        edges.add(_Edge(source: src, target: _rel(tgtAbs, cwd), kind: 'mod', certainty: 'static'));
      }
    }

    // (b) extern crate edges
    for (final ex in ff.externs) {
      final id = 'crate:$ex';
      externals.add(id);
      edges.add(_Edge(source: src, target: id, kind: 'extern', certainty: 'static'));
    }

    // (c) use edges (heuristic resolution)
    for (final path in ff.usePaths) {
      final resolved = _resolveUsePath(cwd, ff.absPath, path, depNames, crateSrcRoots);
      if (resolved != null) {
        edges.add(_Edge(source: src, target: _rel(resolved, cwd), kind: 'use', certainty: 'heuristic'));
      } else {
        final maybeExt = _maybeExternalFromUse(path, depNames);
        if (maybeExt != null) {
          final id = 'crate:$maybeExt';
          externals.add(id);
          edges.add(_Edge(source: src, target: id, kind: 'use', certainty: 'heuristic'));
        }
      }
    }
  }

  // 5) Build nodes (files + externals)
  final nodes = <_Node>[];
  for (final ff in facts) {
    nodes.add(_Node(
      id: ff.relId,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(ff.absPath),
      pkg: crateName,
    ));
  }
  for (final ext in externals) {
    nodes.add(_Node(id: ext, type: 'external', state: 'used', sizeLOC: null, pkg: null));
  }

  // 6) Degrees
  _computeDegrees(nodes, edges);

  // 7) Entries: union of (a) files with fn main(), (b) [[bin]] paths
  final entryFiles = <String>{};
  for (final ff in facts) {
    if (ff.hasMainFn) entryFiles.add(ff.relId);
  }
  for (final relPath in binPaths) {
    final abs = _normalize(_join(cwd, relPath));
    if (File(abs).existsSync()) entryFiles.add(_rel(abs, cwd));
  }
  // Also common default: src/main.rs
  final defaultMain = _join(cwd, 'src${_sep}main.rs');
  if (File(defaultMain).existsSync()) entryFiles.add(_rel(defaultMain, cwd));

  // 8) Reachability
  final usedSet = _reach(entryFiles.toList(), edges);
  for (final n in nodes) {
    if (n.type == 'external') { n.state = 'used'; continue; }
    n.state = usedSet.contains(n.id) ? 'used' : 'unused';
  }

  // 9) Write output
  final outPath = _join(cwd, 'rustDependencies.json');
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
Future<List<String>> _collectRustFiles(String root) async {
  final ignoreDirs = <String>{
    'target','node_modules','dist','build','out','.git','.idea','.vscode','.cache'
  };
  final result = <String>[];
  await for (final ent in Directory(root).list(recursive: true, followLinks: false)) {
    if (ent is! File) continue;
    final sp = ent.path;
    final rel = _rel(sp, root);
    final parts = rel.split(_sep);
    if (parts.any((seg) => ignoreDirs.contains(seg))) continue;
    if (_ext(sp) == '.rs') result.add(_normalize(sp));
  }
  return result;
}

// ---------------- parse `.rs` ----------------
_RustFacts _extractFacts(String cwd, String fileAbs, String text, String pkgName) {
  // Strip block comments /* */; strip line comments // for tokens
  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = noBlock.split('\n');

  final mods = <String>[];
  final externs = <String>[];
  final usePaths = <String>[];
  bool hasMain = false;

  final reMod = RegExp(r'^\s*mod\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$');
  final reExtern = RegExp(r'^\s*extern\s+crate\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$');
  // use foo::bar::{a,b}; -> capture `foo::bar` and also flat paths `crate::a::b`, `self::x`, `super::y`
  final reUse = RegExp(r'^\s*use\s+([^;]+)\s*;\s*$');
  final reMain = RegExp(r'^\s*fn\s+main\s*\(');

  for (var raw in lines) {
    var line = raw.replaceFirst(RegExp(r'//.*$'), '');

    final m1 = reMod.firstMatch(line);
    if (m1 != null) {
      mods.add(m1.group(1)!);
      continue;
    }
    final m2 = reExtern.firstMatch(line);
    if (m2 != null) {
      externs.add(m2.group(1)!);
      continue;
    }
    final m3 = reUse.firstMatch(line);
    if (m3 != null) {
      final clause = m3.group(1)!.trim();
      // Split multiple `use` with commas at top-level (ignore braces inside)
      for (final upath in _splitUseClause(clause)) {
        final cleaned = _flattenUseBraces(upath);
        if (cleaned.isNotEmpty) usePaths.add(cleaned);
      }
      continue;
    }
    if (!hasMain && reMain.hasMatch(line)) {
      hasMain = true;
    }
  }

  return _RustFacts(
    fileAbs,
    _rel(fileAbs, cwd),
    pkgName,
    mods,
    externs,
    usePaths,
    hasMain,
  );
}

// Split a `use` clause containing commas not inside braces. e.g. "foo::bar, baz::{x,y}"
List<String> _splitUseClause(String clause) {
  final out = <String>[];
  final buf = StringBuffer();
  int depth = 0;
  for (int i = 0; i < clause.length; i++) {
    final ch = clause[i];
    if (ch == '{') depth++;
    if (ch == '}') depth--;
    if (ch == ',' && depth == 0) {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  final tail = buf.toString().trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

// Flatten braces: "foo::{bar,baz}" -> ["foo::bar","foo::baz"] (returned as comma-joined; we handle as separate paths)
String _flattenUseBraces(String s) {
  // Simple case: no braces
  if (!s.contains('{')) return s.trim();
  // foo::{a,b} -> placeholder split; turn into "foo::a" and "foo::b" by returning comma-joined string
  final head = s.split('{').first.trim().replaceAll(RegExp(r'::\s*$'), '');
  final inner = s.substring(s.indexOf('{') + 1, s.lastIndexOf('}'));
  final parts = inner.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
  // We return first one; caller uses _splitUseClause to separate. Better: expand inline here:
  // For simplicity return head::first; but to keep more edges, join with commas and let caller handle—already done above.
  // Here, expand fully:
  final expanded = parts.map((p) => '$head::$p').join(', ');
  return expanded;
}

// ---------------- Cargo.toml ----------------
class _CargoInfo {
  final String? packageName;
  final Set<String> dependencies; // crate names
  final List<String> binPaths;    // relative paths from cwd
  _CargoInfo(this.packageName, this.dependencies, this.binPaths);
}

Future<_CargoInfo> _readCargoToml(String cwd) async {
  final f = File(_join(cwd, 'Cargo.toml'));
  if (!await f.exists()) return _CargoInfo(null, <String>{}, <String>[]);
  try {
    final s = await f.readAsString();
    String? pkg;
    final deps = <String>{};
    final bins = <String>[];

    // package.name
    final p = RegExp(r'^\s*name\s*=\s*\"([^\"]+)\"\s*$', multiLine: true);
    // [package] section only: naive, but works if first "name" belongs to package
    final pkgSec = _extractTomlSection(s, 'package');
    final pm = p.firstMatch(pkgSec);
    if (pm != null) pkg = pm.group(1);

    // [dependencies] and [dev-dependencies]
    final depSec = _extractTomlSection(s, 'dependencies');
    deps.addAll(_parseTomlDeps(depSec));
    final devDepSec = _extractTomlSection(s, 'dev-dependencies');
    deps.addAll(_parseTomlDeps(devDepSec));

    // [[bin]] sections -> path = "src/bin/foo.rs"
    final binRe = RegExp(r'^\s*\[\[bin\]\]\s*$', multiLine: true);
    final lines = s.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (binRe.hasMatch(lines[i])) {
        // scan following lines until next [section]
        for (int j = i + 1; j < lines.length; j++) {
          final line = lines[j];
          if (RegExp(r'^\s*\[').hasMatch(line)) break;
          final m = RegExp(r'^\s*path\s*=\s*\"([^\"]+)\"').firstMatch(line);
          if (m != null) {
            bins.add(m.group(1)!);
          }
        }
      }
    }

    return _CargoInfo(pkg, deps, bins);
  } catch (_) {
    return _CargoInfo(null, <String>{}, <String>[]);
  }
}

String _extractTomlSection(String s, String name) {
  final start = RegExp('^\\s*\\[$name\\]\\s*\$', multiLine: true);
  final lines = s.split('\n');
  final out = <String>[];
  var inSec = false;
  for (final line in lines) {
    if (start.hasMatch(line)) { inSec = true; continue; }
    if (inSec && RegExp(r'^\s*\[').hasMatch(line)) break;
    if (inSec) out.add(line);
  }
  return out.join('\n');
}

Set<String> _parseTomlDeps(String sec) {
  final out = <String>{};
  // name = "version"  OR  name = { .. }  OR  name = { path = "..."} etc.
  final re = RegExp(r'^\s*([A-Za-z0-9_\-]+)\s*=\s*');
  for (final line in sec.split('\n')) {
    final m = re.firstMatch(line);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

// ---------------- resolution ----------------
String? _resolveModToFile(String fromFileAbs, String modName) {
  final baseDir = _dir(fromFileAbs);
  final a = _join(baseDir, '$modName.rs');
  if (File(a).existsSync()) return _normalize(a);
  final b = _join(baseDir, _join(modName, 'mod.rs'));
  if (File(b).existsSync()) return _normalize(b);
  return null;
}

String? _resolveUsePath(String cwd, String fromFileAbs, String path, Set<String> depNames, List<String> crateSrcRoots) {
  // Expand any commas (from flattened braces): "foo::a, foo::b"
  for (final p in path.split(',')) {
    final s = p.trim();
    if (s.isEmpty) continue;
    final hit = _resolveSingleUse(cwd, fromFileAbs, s, depNames, crateSrcRoots);
    if (hit != null) return hit;
  }
  return null;
}

String? _resolveSingleUse(String cwd, String fromFileAbs, String path, Set<String> depNames, List<String> crateSrcRoots) {
  // Identify leading qualifier
  if (path.startsWith('crate::')) {
    final modPath = path.substring('crate::'.length);
    return _resolveFromRoots(crateSrcRoots, modPath);
  }
  if (path.startsWith('self::')) {
    final modPath = path.substring('self::'.length);
    return _resolveFromDir(_dir(fromFileAbs), modPath);
  }
  if (path.startsWith('super::')) {
    final modPath = path.substring('super::'.length);
    final parent = _dir(_dir(fromFileAbs));
    return _resolveFromDir(parent, modPath);
  }

  // External crate?
  final firstSeg = path.split('::').first;
  if (depNames.contains(firstSeg)) {
    return null; // treat as external (handled by caller)
  }

  // Otherwise try as internal from crate root
  return _resolveFromRoots(crateSrcRoots, path);
}

String? _resolveFromRoots(List<String> roots, String modPath) {
  for (final root in roots) {
    final hit = _resolveFromDir(root, modPath);
    if (hit != null) return hit;
  }
  return null;
}

String? _resolveFromDir(String dirAbs, String modPath) {
  // Try to map "a::b::c" -> dir/a/b/c.rs or dir/a/b/c/mod.rs
  final relPath = modPath.replaceAll('::', _sep);
  final a = _join(dirAbs, '$relPath.rs');
  if (File(a).existsSync()) return _normalize(a);
  final b = _join(dirAbs, _join(relPath, 'mod.rs'));
  if (File(b).existsSync()) return _normalize(b);
  // Try only first segment: "a" (common re-export targets)
  final first = modPath.split('::').first;
  final c = _join(dirAbs, '$first.rs');
  if (File(c).existsSync()) return _normalize(c);
  final d = _join(dirAbs, _join(first, 'mod.rs'));
  if (File(d).existsSync()) return _normalize(d);
  return null;
}

String? _maybeExternalFromUse(String path, Set<String> depNames) {
  final first = path.split('::').first.trim();
  if (depNames.contains(first)) return first;
  return null;
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

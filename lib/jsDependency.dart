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
  final files = await _collectSourceFiles(cwd);

  final pkg = await _readPackageJson(cwd);
  final entriesAbsSet = <String>{};
  for (final arg in args) {
    final absArg = _normalize(_abs(arg));
    if (File(absArg).existsSync()) entriesAbsSet.add(absArg);
  }
  entriesAbsSet.addAll(_discoverEntries(cwd, pkg, files));
  final entriesAbs = entriesAbsSet.toList();
  var entryIds = entriesAbs.map(_normalize).toList();

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
    final normalized = _normalize(f);
    nodes.add(_Node(
      id: normalized,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(f),
      packageName: null,
      hasSideEffects: factsByPath[f]?.hasSideEffectImport ?? false,
      absPath: normalized,
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

  // Normalize edges
  final normalizedEdges = edges.map((e) {
    final src = e.source.startsWith(cwd) ? _normalize(e.source) : e.source;
    final tgt = e.target.startsWith(cwd) ? _normalize(e.target) : e.target;
    return _Edge(source: src, target: tgt, kind: e.kind, certainty: e.certainty);
  }).toList();

  if (entryIds.isEmpty) {
    final inCounts = <String, int>{};
    for (final e in normalizedEdges) {
      inCounts[e.target] = (inCounts[e.target] ?? 0) + 1;
    }
    entryIds = nodes
        .where((n) => n.type == 'file' && (inCounts[n.id] ?? 0) == 0)
        .map((n) => n.id)
        .toList();
  }
  if (entryIds.isEmpty) {
    entryIds = nodes.where((n) => n.type == 'file').map((n) => n.id).toList();
  }

  // Degrees
  _computeDegrees(nodes, normalizedEdges);

  // Reachability
  final usedSet = _reach(entryIds, normalizedEdges);
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
  final normalizedExports = <String, Map<String, List<String>>>{};
  factsByPath.forEach((path, facts) {
    if (facts.exports.isEmpty) return;
    normalizedExports[_normalize(path)] = {
      for (final entry in facts.exports.entries)
        entry.key: List<String>.from(entry.value),
    };
  });

  final outPath = _join(cwd, 'jsDependencies.json');
  final out = <String, dynamic>{
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': normalizedEdges.map((e) => e.toJson()).toList(),
  };
  if (normalizedExports.isNotEmpty) {
    out['exports'] = normalizedExports;
  }
  final normalizedImports = <String, List<Map<String, dynamic>>>{};
  factsByPath.forEach((path, facts) {
    if (facts.imports.isEmpty) return;
    normalizedImports[_normalize(path)] = facts.imports.map((imp) => {
          'kind': imp.kind,
          'spec': imp.specifier,
          if (imp.defaultName != null) 'default': imp.defaultName,
          if (imp.namespaceName != null) 'namespace': imp.namespaceName,
          if (imp.named.isNotEmpty) 'named': imp.named,
          if (imp.namedOriginal.isNotEmpty) 'namedOriginal': imp.namedOriginal,
          if (imp.typeOnly.isNotEmpty) 'typeOnly': imp.typeOnly,
          if (imp.isTypeOnlyImport) 'typeOnlyImport': true,
        }).toList();
  });
  if (normalizedImports.isNotEmpty) {
    out['imports'] = normalizedImports;
  }
  await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(out));

  // Stats (mirrors javaDependency.dart)
  final total = nodes.length;
  final used = nodes.where((n) => n.state == 'used' || n.state == 'side_effect_only').length;
  final unused = nodes.where((n) => n.state == 'unused').length;
  final externCount = nodes.where((n) => n.type == 'external').length;
  final maxDeg = nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[info] Wrote: ${_normalize(outPath)}');
  stderr.writeln('[stats] nodes=$total edges=${normalizedEdges.length} used=$used unused=$unused externals=$externCount maxDeg=$maxDeg');

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
  String lang = 'js';

  _Node({required this.id, required this.type, required this.state, this.sizeLOC, this.packageName, this.hasSideEffects, required this.absPath});
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'state': state,
    'lang': lang,
    if (sizeLOC != null) 'sizeLOC': sizeLOC,
    if (packageName != null) 'package': packageName,
    if (hasSideEffects != null) 'hasSideEffects': hasSideEffects,
    'inDeg': inDeg,
    'outDeg': outDeg,
    if (absPath != null) 'absPath': absPath,
  };
}

class _Edge {
  final String source, target, kind, certainty;
  _Edge({required this.source, required this.target, required this.kind, required this.certainty});
  Map<String, dynamic> toJson() => {'source': source, 'target': target, 'kind': kind, 'certainty': certainty};
}

class _ImportFact {
  final String specifier; // 'react', './x.js', etc.
  final String kind; // import | reexport | require | dynamic | side_effect
  final String? defaultName;
  final String? namespaceName;
  final List<String> named;
  final List<String> namedOriginal;
  final List<String> typeOnly;
  final bool isTypeOnlyImport;

  _ImportFact(
    this.specifier,
    this.kind, {
    this.defaultName,
    this.namespaceName,
    List<String>? named,
    List<String>? namedOriginal,
    List<String>? typeOnly,
    this.isTypeOnlyImport = false,
  })  : named = named ?? const [],
        namedOriginal = namedOriginal ?? const [],
        typeOnly = typeOnly ?? const [];
}

class _FileFacts {
  final String path;
  final List<_ImportFact> imports;
  final bool hasSideEffectImport;
  final Map<String, List<String>> exports;
  _FileFacts(this.path, this.imports, this.hasSideEffectImport, this.exports);
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
  void addImport(String spec, String kind) {
    for (final existing in imports) {
      if (existing.specifier == spec && existing.kind == kind) {
        return;
      }
    }
    imports.add(_ImportFact(spec, kind));
  }
  void addImportFact(_ImportFact fact) {
    for (final existing in imports) {
      final same =
          existing.specifier == fact.specifier &&
          existing.kind == fact.kind &&
          existing.defaultName == fact.defaultName &&
          existing.namespaceName == fact.namespaceName &&
          _listEq(existing.namedOriginal, fact.namedOriginal) &&
          existing.isTypeOnlyImport == fact.isTypeOnlyImport;
      if (same) {
        return;
      }
    }
    imports.add(fact);
  }
  bool sideEffectOnly = false;
  final exportSets = <String, Set<String>>{};

  void addExport(String kind, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    exportSets.putIfAbsent(kind, () => <String>{}).add(trimmed);
  }

  void addExports(String kind, Iterable<String> names) {
    for (final n in names) {
      addExport(kind, n);
    }
  }

  List<String> extractNamesFromDeclaration(String decl) {
    const keywords = {
      'const',
      'let',
      'var',
      'enum',
      'type',
      'interface',
      'default',
      'function',
      'class',
      'async',
      'abstract',
      'declare',
      'readonly',
      'public',
      'private',
      'protected',
      'static',
      'get',
      'set',
    };
    final results = <String>[];
    final identPattern = RegExp(r'[A-Za-z_][\w\$]*');
    for (final part in decl.split(',')) {
      final cleaned = part.trim();
      if (cleaned.isEmpty) continue;
      final matches = identPattern.allMatches(cleaned);
      for (final match in matches) {
        final candidate = match.group(0)!;
        if (!keywords.contains(candidate)) {
          results.add(candidate);
          break;
        }
      }
    }
    return results;
  }

  final noBlock = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final sanitized = noBlock
      .replaceFirst('\ufeff', '')
      .split('\n')
      .map((line) {
        var cleaned = line;
        if (cleaned.startsWith('\ufeff')) {
          cleaned = cleaned.substring(1);
        }
        return cleaned.replaceFirst(RegExp(r'//.*$'), '');
      })
      .join('\n');
  final lines = sanitized.split('\n');

  bool hasDefaultExport() {
    final existing = exportSets['default'];
    return existing != null && existing.isNotEmpty;
  }

  final reImportSide =
      RegExp(r'''^\s*import\s+['"]([^'"]+)['"]\s*;?\s*$''');
  final reImportFull =
      RegExp(r'''^\s*import\s+(.+?)\s+from\s+['"]([^'"]+)['"]\s*;?\s*$''');
  final reExportNamedFrom = RegExp(
      r'''^\s*export\s+(?:type\s+)?\{\s*([^}]*)\s*\}\s*from\s*['"]([^'"]+)['"]\s*;?\s*$''');
  final reExportFrom = RegExp(r'''^\s*export\s+[^;]*\s+from\s+['"]([^'"]+)['"]''');
  final reRequire = RegExp(r'''require\s*\(\s*['"]([^'"]+)['"]\s*\)''');
  final reDynImport = RegExp(r'''import\s*\(\s*['"]([^'"]+)['"]\s*\)''');
  final reDefaultFunc = RegExp(r'''^\s*export\s+default\s+(?:async\s+)?function(?:\s+([A-Za-z0-9_\$]+))?''');
  final reFunc = RegExp(r'''^\s*export\s+(?:async\s+)?function\s+([A-Za-z0-9_\$]+)''');
  final reDefaultClass = RegExp(r'''^\s*export\s+default\s+(?:abstract\s+)?class(?:\s+([A-Za-z0-9_\$]+))?''');
  final reClass = RegExp(r'''^\s*export\s+(?:abstract\s+)?class\s+([A-Za-z0-9_\$]+)''');
  final reVar = RegExp(r'''^\s*export\s+(?:const|let|var)\s+(.+)''');
  final reType = RegExp(r'''^\s*export\s+type\s+([A-Za-z0-9_\$]+)''');
  final reInterface = RegExp(r'''^\s*export\s+interface\s+([A-Za-z0-9_\$]+)''');
  final reEnum = RegExp(r'''^\s*export\s+enum\s+([A-Za-z0-9_\$]+)''');
  final reDefaultIdentifier = RegExp(r'''^\s*export\s+default\s+([A-Za-z0-9_\$]+)''');
  final reDefaultFallback = RegExp(r'''^\s*export\s+default\b(.*)$''');
  final reCommonJsProp = RegExp(r'''^(?:module\.)?exports\.([A-Za-z0-9_\$]+)''');
  final reCommonJsBracket =
      RegExp(r'''^(?:module\.)?exports\[['"]([^'"]+)['"]\]''');

  for (var raw in lines) {
    final line = raw;
    var trimmed = line.trim();
    if (trimmed.startsWith('\ufeff')) {
      trimmed = trimmed.substring(1);
    }

    final mSide = reImportSide.firstMatch(line);
    if (mSide != null) {
      final spec = mSide.group(1)!;
      addImportFact(_ImportFact(spec, 'side_effect'));
      sideEffectOnly = true;
      continue;
    }

    final mFull = reImportFull.firstMatch(line);
    if (mFull != null) {
      final clause = mFull.group(1)!.trim();
      final spec = mFull.group(2)!;
      final parsed = _parseImportClause(clause);
      addImportFact(_ImportFact(
        spec,
        'import',
        defaultName: parsed.defaultName,
        namespaceName: parsed.namespaceName,
        named: parsed.named,
        namedOriginal: parsed.namedOriginal,
        typeOnly: parsed.typeOnly,
        isTypeOnlyImport: parsed.isTypeOnlyImport,
      ));
      continue;
    }

    final mENF = reExportNamedFrom.firstMatch(line);
    if (mENF != null) {
      final list = mENF.group(1)!;
      final spec = mENF.group(2)!;
      final parsed = _parseImportClause('{ $list }');
      final isTypeExport = trimmed.startsWith('export type');
      addImportFact(_ImportFact(
        spec,
        'reexport',
        named: parsed.named,
        namedOriginal: parsed.namedOriginal,
      ));
      for (var i = 0; i < parsed.named.length; i++) {
        final alias = parsed.named[i];
        final orig = i < parsed.namedOriginal.length ? parsed.namedOriginal[i] : alias;
        final isType = isTypeExport || parsed.typeOnly.contains(alias);
        if (alias == 'default') {
          addExport('default', orig);
          if (isType) {
            addExport('types', orig);
          }
        } else if (isType) {
          addExport('types', alias);
        } else {
          addExport('named', alias);
        }
      }
      continue;
    }

    final m2 = reExportFrom.firstMatch(line);
    if (m2 != null) {
      addImport(m2.group(1)!, 'reexport');
      final starAs = RegExp(r'^\s*export\s+\*\s+as\s+([A-Za-z0-9_\$]+)').firstMatch(trimmed);
      if (starAs != null) {
        addExport('named', starAs.group(1)!);
      }
      continue;
    }

    for (final m in reRequire.allMatches(line)) {
      addImport(m.group(1)!, 'require');
    }
    for (final m in reDynImport.allMatches(line)) {
      addImport(m.group(1)!, 'dynamic');
    }

    final commonJsProp = reCommonJsProp.firstMatch(trimmed);
    if (commonJsProp != null) {
      addExport('named', commonJsProp.group(1)!);
    }
    final commonJsBracket = reCommonJsBracket.firstMatch(trimmed);
    if (commonJsBracket != null) {
      addExport('named', commonJsBracket.group(1)!);
    }

    if (trimmed.startsWith('export')) {
      final defaultFunc = reDefaultFunc.firstMatch(trimmed);
      if (defaultFunc != null) {
        final name = defaultFunc.group(1);
        if (name != null && name.isNotEmpty) {
          addExport('functions', name);
          addExport('default', 'function ' + name);
        } else {
          addExport('default', 'function');
        }
        continue;
      }

      final func = reFunc.firstMatch(trimmed);
      if (func != null) {
        final name = func.group(1)!;
        addExport('functions', name);
        addExport('named', name);
        continue;
      }

      final defaultClass = reDefaultClass.firstMatch(trimmed);
      if (defaultClass != null) {
        final name = defaultClass.group(1);
        if (name != null && name.isNotEmpty) {
          addExport('classes', name);
          addExport('default', 'class ' + name);
        } else {
          addExport('default', 'class');
        }
        continue;
      }

      final classMatch = reClass.firstMatch(trimmed);
      if (classMatch != null) {
        final name = classMatch.group(1)!;
        addExport('classes', name);
        addExport('named', name);
        continue;
      }

      final typeMatch = reType.firstMatch(trimmed);
      if (typeMatch != null) {
        addExport('types', typeMatch.group(1)!);
        continue;
      }

      final interfaceMatch = reInterface.firstMatch(trimmed);
      if (interfaceMatch != null) {
        addExport('interfaces', interfaceMatch.group(1)!);
        continue;
      }

      final enumMatch = reEnum.firstMatch(trimmed);
      if (enumMatch != null) {
        addExport('enums', enumMatch.group(1)!);
        continue;
      }

      final defaultIdent = reDefaultIdentifier.firstMatch(trimmed);
      if (defaultIdent != null) {
        addExport('default', defaultIdent.group(1)!);
        continue;
      }

      final varMatch = reVar.firstMatch(trimmed);
      if (varMatch != null) {
        final decl = varMatch.group(1) ?? '';
        final names = extractNamesFromDeclaration(decl);
        addExports('variables', names);
        addExports('named', names);
        continue;
      }

      final defaultFallback = reDefaultFallback.firstMatch(trimmed);
      if (defaultFallback != null) {
        final summary = _summarizeDefaultExport(defaultFallback.group(1) ?? '');
        addExport('default', summary);
        continue;
      }
    }
  }

  if (!hasDefaultExport()) {
    final reDefaultFuncMulti =
        RegExp(r'export\s+default\s+(?:async\s+)?function(?:\s+([A-Za-z0-9_\$]+))?', multiLine: true);
    for (final match in reDefaultFuncMulti.allMatches(sanitized)) {
      final name = match.group(1);
      if (name != null && name.isNotEmpty) {
        addExport('functions', name);
        addExport('default', 'function ' + name);
      } else {
        addExport('default', 'function');
      }
    }
  }

  if (!hasDefaultExport()) {
    final reDefaultClassMulti =
        RegExp(r'export\s+default\s+(?:abstract\s+)?class(?:\s+([A-Za-z0-9_\$]+))?', multiLine: true);
    for (final match in reDefaultClassMulti.allMatches(sanitized)) {
      final name = match.group(1);
      if (name != null && name.isNotEmpty) {
        addExport('classes', name);
        addExport('default', 'class ' + name);
      } else {
        addExport('default', 'class');
      }
    }
  }

  if (!hasDefaultExport()) {
    final reDefaultIdentMulti =
        RegExp(r'export\s+default\s+([A-Za-z0-9_\$]+)', multiLine: true);
    for (final match in reDefaultIdentMulti.allMatches(sanitized)) {
      final ident = match.group(1);
      if (ident == null || ident.isEmpty) continue;
      if (ident == 'function' || ident == 'class') continue;
      addExport('default', ident);
    }
  }

  if (!hasDefaultExport()) {
    final reDefaultExpr =
        RegExp(r'export\s+default\s+([\s\S]+?)(?:;|\n{2,})', multiLine: true);
    for (final match in reDefaultExpr.allMatches(sanitized)) {
      final snippet = match.group(1) ?? '';
      if (snippet.trim().isEmpty) continue;
      addExport('default', _summarizeDefaultExport(snippet));
    }
  }

  final reNamedBlock = RegExp(r'export\s*{\s*([^}]*)\s*}', multiLine: true);
  for (final match in reNamedBlock.allMatches(sanitized)) {
    final rawList = match.group(1)!;
    final symbols = rawList
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map((part) {
      final asMatch =
          RegExp(r'\bas\s+([A-Za-z0-9_$]+)', caseSensitive: false).firstMatch(part);
      if (asMatch != null) {
        return asMatch.group(1)!;
      }
      final ident = RegExp(r'[A-Za-z0-9_$]+').firstMatch(part);
      return ident?.group(0) ?? '';
    }).where((symbol) => symbol.isNotEmpty);
    addExports('named', symbols);
  }

  final reVarMulti = RegExp(r'export\s+(?:const|let|var)\s+([^;]+)', multiLine: true);
  for (final match in reVarMulti.allMatches(sanitized)) {
    final decl = match.group(1) ?? '';
    final names = extractNamesFromDeclaration(decl);
    addExports('variables', names);
    addExports('named', names);
  }

  final reFuncMulti =
      RegExp(r'export\s+(?:async\s+)?function\s+([A-Za-z_][\w\$]*)', multiLine: true);
  for (final match in reFuncMulti.allMatches(sanitized)) {
    final name = match.group(1);
    if (name == null || name.isEmpty) continue;
    addExport('functions', name);
    addExport('named', name);
  }

  final reClassMulti =
      RegExp(r'export\s+(?:abstract\s+)?class\s+([A-Za-z_][\w\$]*)', multiLine: true);
  for (final match in reClassMulti.allMatches(sanitized)) {
    final name = match.group(1);
    if (name == null || name.isEmpty) continue;
    addExport('classes', name);
    addExport('named', name);
  }

  final reMultiReexport =
      RegExp(r'''export\s+[^;{]*\{[^}]*\}\s*from\s*['"]([^'"]+)['"]''', multiLine: true);
  for (final match in reMultiReexport.allMatches(sanitized)) {
    addImport(match.group(1)!, 'reexport');
  }
  final reStarReexport =
      RegExp(r'''export\s+\*\s+from\s*['"]([^'"]+)['"]''', multiLine: true);
  for (final match in reStarReexport.allMatches(sanitized)) {
    addImport(match.group(1)!, 'reexport');
  }
  final reModuleObject =
      RegExp(r'module\.exports\s*=\s*{([\s\S]*?)}', multiLine: true, dotAll: true);
  for (final match in reModuleObject.allMatches(sanitized)) {
    final raw = match.group(1) ?? '';
    final parts = raw
        .split(RegExp(r'[;,]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map((part) {
      final colon = part.indexOf(':');
      var key = colon >= 0 ? part.substring(0, colon).trim() : part;
      if ((key.startsWith("'") && key.endsWith("'")) ||
          (key.startsWith('"') && key.endsWith('"'))) {
        if (key.length > 1) {
          key = key.substring(1, key.length - 1);
        }
      }
      final ident = RegExp(r'[A-Za-z0-9_\$]+').firstMatch(key);
      return ident?.group(0) ?? '';
    }).where((name) => name.isNotEmpty);
    addExports('named', parts);
  }

  final reModuleDefaultFunc =
      RegExp(r'module\.exports\s*=\s*(?:async\s+)?function(?:\s+([A-Za-z0-9_\$]+))?', multiLine: true);
  final reModuleDefaultClass =
      RegExp(r'module\.exports\s*=\s*(?:abstract\s+)?class(?:\s+([A-Za-z0-9_\$]+))?', multiLine: true);
  final reModuleDefaultIdent =
      RegExp(r'module\.exports\s*=\s*([A-Za-z0-9_\$]+)', multiLine: true);

  final moduleDefaultFunc = reModuleDefaultFunc.firstMatch(sanitized);
  if (moduleDefaultFunc != null) {
    final name = moduleDefaultFunc.group(1);
    if (name != null && name.isNotEmpty) {
      addExport('functions', name);
      addExport('default', 'function ' + name);
    } else {
      addExport('default', 'function');
    }
  }
  final moduleDefaultClass = reModuleDefaultClass.firstMatch(sanitized);
  if (moduleDefaultClass != null) {
    final name = moduleDefaultClass.group(1);
    if (name != null && name.isNotEmpty) {
      addExport('classes', name);
      addExport('default', 'class ' + name);
    } else {
      addExport('default', 'class');
    }
  }
  if (moduleDefaultFunc == null && moduleDefaultClass == null) {
    final moduleDefaultIdent = reModuleDefaultIdent.firstMatch(sanitized);
    if (moduleDefaultIdent != null) {
      addExport('default', moduleDefaultIdent.group(1)!);
    } else if (RegExp(r'module\.exports\s*=', multiLine: true).hasMatch(sanitized)) {
      addExport('default', 'module.exports');
    }
  }

  final exports = {
    for (final entry in exportSets.entries)
      entry.key: entry.value.toList()..sort((a, b) => a.compareTo(b))
  };
  return _FileFacts(filePath, imports, sideEffectOnly, exports);
}

bool _listEq(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _ParsedImportClause {
  String? defaultName;
  String? namespaceName;
  final List<String> named = [];
  final List<String> namedOriginal = [];
  final List<String> typeOnly = [];
  bool isTypeOnlyImport = false;
}

List<String> _splitNamedList(String raw) {
  return raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

_ParsedImportClause _parseImportClause(String clause) {
  final res = _ParsedImportClause();
  var c = clause.trim();

  if (c.startsWith('type ')) {
    res.isTypeOnlyImport = true;
    c = c.substring(5).trim();
  }

  final ns = RegExp(r'^\*\s+as\s+([A-Za-z_\$][\w\$]*)$').firstMatch(c);
  if (ns != null) {
    res.namespaceName = ns.group(1);
    return res;
  }

  final defPlusNamed =
      RegExp(r'^([A-Za-z_\$][\w\$]*)\s*,\s*\{\s*([^}]*)\s*\}$').firstMatch(c);
  if (defPlusNamed != null) {
    res.defaultName = defPlusNamed.group(1);
    final namedRaw = defPlusNamed.group(2) ?? '';
    for (final item in _splitNamedList(namedRaw)) {
      final mAs = RegExp(
              r'^(?:type\s+)?([A-Za-z_\$][\w\$]*)(?:\s+as\s+([A-Za-z_\$][\w\$]*))?$')
          .firstMatch(item);
      if (mAs != null) {
        final isType = item.trim().startsWith('type ');
        final orig = mAs.group(1)!;
        final alias = mAs.group(2) ?? orig;
        res.namedOriginal.add(orig);
        res.named.add(alias);
        if (isType) res.typeOnly.add(alias);
      }
    }
    return res;
  }

  final namedOnly = RegExp(r'^\{\s*([^}]*)\s*\}$').firstMatch(c);
  if (namedOnly != null) {
    final namedRaw = namedOnly.group(1) ?? '';
    for (final item in _splitNamedList(namedRaw)) {
      final mAs = RegExp(
              r'^(?:type\s+)?([A-Za-z_\$][\w\$]*)(?:\s+as\s+([A-Za-z_\$][\w\$]*))?$')
          .firstMatch(item);
      if (mAs != null) {
        final isType = item.trim().startsWith('type ');
        final orig = mAs.group(1)!;
        final alias = mAs.group(2) ?? orig;
        res.namedOriginal.add(orig);
        res.named.add(alias);
        if (isType) res.typeOnly.add(alias);
      }
    }
    return res;
  }

  final defOnly = RegExp(r'^([A-Za-z_\$][\w\$]*)$').firstMatch(c);
  if (defOnly != null) {
    res.defaultName = defOnly.group(1);
    return res;
  }

  return res;
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
  return seen;
}

Set<String> _sideEffectOnlyTargets(Map<String, _FileFacts> facts, String cwd) {
  final targets = <String>{};
  facts.forEach((path, ff) {
    for (final imp in ff.imports) {
      if (imp.kind == 'side_effect') {
        final resolved = _resolveSpecifier(cwd, path, imp.specifier);
        if (resolved != null) {
          targets.add(_normalize(resolved));
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

String _summarizeDefaultExport(String raw) {
  var expr = raw.trim();
  if (expr.isEmpty) return 'expression';
  if (expr.endsWith(';')) {
    expr = expr.substring(0, expr.length - 1).trim();
    if (expr.isEmpty) return 'expression';
  }
  if (expr.startsWith('{')) return '{...}';
  if (expr.startsWith('[')) return '[...]';
  if (expr.startsWith('(')) return '(...)';
  if (expr.startsWith('function')) return 'function';
  if (expr.startsWith('class')) return 'class';
  final ident = RegExp(r'[A-Za-z0-9_\$]+').firstMatch(expr)?.group(0);
  return ident ?? 'expression';
}

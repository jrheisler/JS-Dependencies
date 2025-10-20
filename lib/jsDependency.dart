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
    final facts = _extractFacts(f, text);
    factsByPath[f] = facts;
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
    final facts = factsByPath[f];
    Map<String, List<String>>? nodeExports;
    if (facts != null && facts.exports.isNotEmpty) {
      nodeExports = {
        for (final entry in facts.exports.entries)
          entry.key: List<String>.from(entry.value),
      };
    }
    nodes.add(_Node(
      id: normalized,
      type: 'file',
      state: 'unused',
      sizeLOC: await _estimateLOC(f),
      packageName: null,
      hasSideEffects: facts?.hasSideEffectImport ?? false,
      absPath: normalized,
      exports: nodeExports,
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
  final security = <String, List<Map<String, dynamic>>>{};
  factsByPath.forEach((path, facts) {
    if (facts.findings.isEmpty) return;
    security[_normalize(path)] =
        facts.findings.map((finding) => finding.toJson()).toList();
  });
  if (security.isNotEmpty) {
    out['securityFindings'] = security;
  }
  final pkgRisks = _computePackageRisks(pkg);
  if (pkgRisks != null && pkgRisks.isNotEmpty) {
    out['packageRisks'] = pkgRisks;
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
  final Map<String, List<String>>? exports;

  _Node({
    required this.id,
    required this.type,
    required this.state,
    this.sizeLOC,
    this.packageName,
    this.hasSideEffects,
    required this.absPath,
    this.exports,
  });
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
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
    if (exports != null && exports!.isNotEmpty) {
      map['exports'] = {
        for (final entry in exports!.entries)
          entry.key: List<String>.from(entry.value),
      };
    }
    return map;
  }
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
  final List<SecurityFinding> findings;
  _FileFacts(
    this.path,
    this.imports,
    this.hasSideEffectImport,
    this.exports,
    this.findings,
  );
}

class SecurityFinding {
  final String id;
  final String message;
  final String severity;
  final int line;
  final String code;

  SecurityFinding(this.id, this.message, this.severity, this.line, this.code);

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'severity': severity,
        'line': line,
        'code': code,
      };
}

class _SecurityRule {
  final String id;
  final String severity;
  final String message;
  final RegExp re;

  const _SecurityRule(this.id, this.severity, this.message, this.re);
}

final _secRules = <_SecurityRule>[
  _SecurityRule('eval.call', 'high', 'Use of eval() can execute arbitrary code.', RegExp(r'\beval\s*\(')),
  _SecurityRule('function.constructor', 'high', 'new Function() dynamically executes code.',
      RegExp(r'new\s+Function\s*\(')),
  _SecurityRule('timeout.string', 'high', 'setTimeout/setInterval with a string executes code.',
      RegExp(r'''set(?:Timeout|Interval)\s*\(\s*["\']''')),
  _SecurityRule('vm.module', 'high', 'Use of Node vm module can escape sandboxes.', RegExp(r'\bvm\.[A-Za-z_][\w]*\s*\(')),
  _SecurityRule('child_process.exec', 'high', 'child_process execution can run arbitrary commands.',
      RegExp(r'''(?:\brequire\s*\(\s*["\']child_process["\']\s*\)|\bchild_process)\s*\.\s*(?:exec|execSync|spawn|spawnSync)\s*\(''')),
  _SecurityRule('child_process.shell', 'high', 'Shell execution enabled via {shell:true}.',
      RegExp(r'shell\s*:\s*true')),
  _SecurityRule('child_process.spawnShell', 'high',
      'child_process spawn/execFile with shell:true runs commands through a shell; avoid shell:true or sanitize inputs.',
      RegExp(r'''(?:\bchild_process\s*\.\s*)?(?:spawn|execFile)(?:Sync)?\s*\([^;{}]*\{[^}]*shell\s*:\s*true''',
          multiLine: true)),
  _SecurityRule('dynamic.require', 'high', 'Dynamic require with non-literal path.',
      RegExp(r'''require\s*\(\s*[^\'"\s][^\)]*\)''')),
  _SecurityRule('dynamic.import', 'high', 'Dynamic import() with non-literal path.',
      RegExp(r'''import\s*\(\s*[^\'"\s][^\)]*\)''')),
  _SecurityRule('import.template', 'high', 'Import from template literal allows arbitrary modules.',
      RegExp(r'''from\s*`''')),
  _SecurityRule('node.builtin', 'med', 'Importing sensitive Node built-ins (fs/net/etc).',
      RegExp(r'''\b(?:require|import)\s*\(\s*["\'](?:fs|net|tls|http|https|dgram|cluster|os)\b''')),
  _SecurityRule('process.env', 'med', 'Access to process.env exposes environment secrets.',
      RegExp(r'process\.env')),
  _SecurityRule('fs.access', 'med', 'File system access can expose sensitive data.',
      RegExp(r'''(?:\brequire\s*\(\s*["\']fs["\']\s*\)|\bfs)\s*\.\s*(?:readFile|readFileSync|writeFile|writeFileSync|readdir|readdirSync|createWriteStream|createReadStream)\s*\(''')),
  _SecurityRule('http.cleartext', 'med',
      'HTTP over cleartext detected; use HTTPS (localhost is allow-listed) or document an explicit exception.',
      RegExp(r'http://(?!localhost|127\.0\.0\.1|0\.0\.0\.0|\[?::1\]?)')),
  _SecurityRule('dom.innerHTML', 'high', 'Writing to innerHTML can enable XSS.', RegExp(r'\.\s*innerHTML\s*=')),
  _SecurityRule('dom.outerHTML', 'high', 'Writing to outerHTML can enable XSS.', RegExp(r'\.\s*outerHTML\s*=')),
  _SecurityRule('document.write', 'high', 'document.write can introduce XSS.', RegExp(r'document\.write\s*\(')),
  _SecurityRule('dom.insertAdjacentHTML', 'high',
      'insertAdjacentHTML can introduce XSS; prefer insertAdjacentText for plain text content.',
      RegExp(r'insertAdjacentHTML\s*\(')),
  _SecurityRule('dom.javascriptHref', 'high', 'Assigning javascript: URLs to links executes script; avoid javascript: hrefs.',
      RegExp(r'\.href\s*=\s*["\']javascript:', caseSensitive: false)),
  _SecurityRule('dom.javascriptLocation', 'high', 'Navigating to javascript: URLs executes script; avoid javascript: locations.',
      RegExp(r'\blocation(?:\.href)?\s*=\s*["\']javascript:', caseSensitive: false)),
  _SecurityRule('dom.range', 'high', 'Range.createContextualFragment can introduce XSS.',
      RegExp(r'createContextualFragment\s*\(')),
  _SecurityRule('react.dangerousHTML', 'high', 'dangerouslySetInnerHTML used; review sanitization.',
      RegExp(r'dangerouslySetInnerHTML\s*:')),
  _SecurityRule('iframe.srcdoc', 'high', 'Setting srcdoc can enable injection.', RegExp(r'\bsrcdoc\s*=')),
  _SecurityRule('template.interpolation', 'low', 'Template literal interpolation detected; ensure sanitization.',
      RegExp(r'''`[^`]*\$\{[^}]+\}[^`]*`''')),
  _SecurityRule('postmessage.wildcard', 'med', 'window.postMessage uses wildcard origin.',
      RegExp(r'''postMessage\s*\([^,]+,\s*["\']\*["\']\)''')),
  _SecurityRule('secret.literal', 'high', 'Possible hard-coded secret detected.',
      RegExp(r'''(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\s*[:=]\s*["\'][A-Za-z0-9_\-\.=+/]{12,}["\']''')),
  _SecurityRule('math.random', 'low', 'Math.random used for tokens; use crypto.randomBytes instead.',
      RegExp(r'Math\.random\s*\(')),
  _SecurityRule('storage.token', 'med',
      'Token persisted in web storage/IndexedDB; prefer short-lived, HttpOnly cookies instead.',
      RegExp(
          r'''(?:localStorage|sessionStorage|indexedDB)[^\n;]{0,200}(?:setItem|put|add|=)[^\n;]{0,200}(?:token|auth|jwt|session)''',
          caseSensitive: false)),
  _SecurityRule('crypto.weakHash', 'med', 'Weak hash algorithm (md5/sha1) detected.',
      RegExp(r'''crypto\.createHash\(\s*["\'](?:md5|sha1)["\']''')),
  _SecurityRule('crypto.createCipher', 'med', 'Deprecated crypto.createCipher detected.',
      RegExp(r'crypto\.create(?:Cipher|Decipher)\s*\(')),
  _SecurityRule('jwt.verify', 'med', 'jwt.verify called without options; ensure audience/issuer validated.',
      RegExp(r'''(?:\brequire\s*\(\s*["\']jsonwebtoken["\']\s*\)|\bjwt|\bjsonwebtoken)\s*\.\s*verify\s*\(\s*[^,]+,\s*[^,]+?\)''', multiLine: true)),
  _SecurityRule('cors.wildcard', 'med', 'Access-Control-Allow-Origin set to wildcard.',
      RegExp(r'''Access-Control-Allow-Origin["\']?\s*[:=]\s*["\']\*["\']''')),
  _SecurityRule('cors.middleware', 'med', 'app.use(cors()) with no options; ensure restrictions applied.',
      RegExp(r'app\.use\s*\(\s*cors\s*\(\s*\)')),
  _SecurityRule('cookie.literal', 'low', 'Cookie configuration literal detected; verify security flags.',
      RegExp(r'''(?:document\.cookie\s*=\s*["\'][^"\']*["\']|cookie\s*:\s*["\'][^"\']*["\'])''')),
  _SecurityRule('console.secret', 'low', 'console logging sensitive data.',
      RegExp(r'''console\.(?:log|dir)\s*\([^)]*(password|secret|token)[^)]*\)''')),
  _SecurityRule('import.meta.env', 'low', 'Direct access to import.meta.env; ensure safe exposure.',
      RegExp(r'''import\.meta\.env\.[A-Za-z_][\w]*''')),
  _SecurityRule('ssrf.metadataHost', 'high', 'HTTP request targets metadata or private network IP; validate hosts.',
      RegExp(
          r'(?:https?:\/\/)?(?:169\.254\.169\.254|10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[0-1])\.(?:[0-9]{1,3})\.(?:[0-9]{1,3})|192\.168\.(?:[0-9]{1,3})\.(?:[0-9]{1,3}))')),
  _SecurityRule('injection.mongoOperator', 'high', 'MongoDB \$where/\$regex operators can execute user-controlled code.',
      RegExp(r'\$(?:where|regex)\s*:')),
  _SecurityRule('regex.dynamic', 'med', 'RegExp constructed from dynamic input; ensure it is sanitized.',
      RegExp(r'''(?:new\s+)?RegExp\s*\(\s*(?!["\'`/])''')),
  _SecurityRule('regex.catastrophic', 'high', 'Nested quantifiers in RegExp can cause catastrophic backtracking (ReDoS).',
      RegExp(r'/(?:[^/\\]|\\.)*\([^)]*\+[^)]*\)(?:[^/\\]|\\.)*\+(?:[^/\\]|\\.)*/')),
  _SecurityRule('cors.credentialsWildcard', 'high',
      'CORS allows credentials with a wildcard origin; restrict allowed origins.',
      RegExp(r'Access-Control-Allow-Origin[^\n;]*\*[\s\S]{0,200}?Access-Control-Allow-Credentials[^\n;]*true',
          caseSensitive: false, multiLine: true)),
  _SecurityRule('tls.disabledEnv', 'high',
      'NODE_TLS_REJECT_UNAUTHORIZED=0 disables TLS verification and should not be set in production.',
      RegExp(r'NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*0')),
  _SecurityRule('tls.agentInsecure', 'high',
      'https.Agent configured with rejectUnauthorized:false disables TLS verification.',
      RegExp(r'https?\.Agent\s*\(\s*\{[^}]*rejectUnauthorized\s*:\s*false', multiLine: true)),
  _SecurityRule('template.tripleStache', 'med', 'Triple-stache rendering ({{{ }}}) disables escaping; ensure inputs are trusted.',
      RegExp(r'\{\{\{[^}]+\}\}\}')),
  _SecurityRule('template.escapeDisabled', 'med', 'Template rendering with escape disabled; ensure inputs are sanitized.',
      RegExp(r'escape\s*:\s*false', caseSensitive: false)),
  _SecurityRule('prototype.proto', 'high', 'Assigning to __proto__ or constructor.prototype can lead to prototype pollution.',
      RegExp(r'(?:__proto__|constructor\.prototype)\s*='))
];

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
        return _stripLineCommentPreservingStrings(cleaned);
      })
      .join('\n');
  final lines = sanitized.split('\n');
  final lineStarts = _computeLineStarts(sanitized);
  final findings = <SecurityFinding>[];
  final seenFindings = <String>{};

  final userInputPattern =
      RegExp(r'\b(?:req|request|ctx|context|event|body|params|query|user|input|data|form|payload|options|config|argv|env|headers|url|href|path|file|filename|dir|search|hash)\b',
          caseSensitive: false);
  final pathInputPattern =
      RegExp(r'\b(?:req|request|body|params|query|user|input|data|file|filename|filepath|dir|directory|path|paths|entry|archive)\b',
          caseSensitive: false);
  final fetchPattern = RegExp(r'\bfetch\s*\(');
  final axiosPattern = RegExp(r'\baxios(?:\.[A-Za-z_][\w]*)?\s*\(');
  final httpRequestPattern = RegExp(r'\bhttps?\.request\s*\(');
  final sqlTemplatePattern = RegExp(r'\.query\s*\(\s*`[^`]*\$\{');
  final sqlConcatPattern =
      RegExp("\\.query\\s*\\([^)]*['\"`][^)]*\\+\\s*[A-Za-z_]");
  final lodashMergePattern = RegExp(r'\b_\.merge\s*\(');
  final objectAssignPattern = RegExp(r'\bObject\.assign\s*\(');
  final pathJoinPattern = RegExp(r'\bpath\.join\s*\(');
  final extractPattern = RegExp(r'\.extract\s*\(');
  final entryPathPattern = RegExp(r'entry\.path');
  final spawnExecPattern =
      RegExp(r'(?:child_process\s*\.\s*)?(?:spawn|execFile)(?:Sync)?\s*\(');
  final storageApiPattern =
      RegExp(r'\b(?:localStorage|sessionStorage|indexedDB)\b', caseSensitive: false);
  final storageTokenPattern =
      RegExp(r'(token|auth|jwt|session)', caseSensitive: false);

  bool containsUserInput(String line) => userInputPattern.hasMatch(line);
  bool containsPathInput(String line) => pathInputPattern.hasMatch(line);

  void addFinding(SecurityFinding finding) {
    final key = '${finding.id}|${finding.line}|${finding.code}';
    if (seenFindings.add(key)) {
      findings.add(finding);
    }
  }

  for (final rule in _secRules) {
    for (final match in rule.re.allMatches(sanitized)) {
      final lineNumber = _lineNumberForOffset(lineStarts, match.start, sanitized.length);
      final snippet = _lineAt(lines, lineNumber).trim();
      addFinding(SecurityFinding(rule.id, rule.message, rule.severity, lineNumber, snippet));
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final trimmed = raw.trim();
    final hasUserInput = containsUserInput(trimmed);
    final hasPathInput = containsPathInput(trimmed);

    if (fetchPattern.hasMatch(trimmed) && hasUserInput) {
      addFinding(SecurityFinding('ssrf.dynamicFetch',
          'fetch() invoked with potential user-controlled input; validate URL to prevent SSRF.', 'high', i + 1, trimmed));
    }
    if (axiosPattern.hasMatch(trimmed) && hasUserInput) {
      addFinding(SecurityFinding('ssrf.dynamicAxios',
          'axios call built from user input; validate host/URL to prevent SSRF.', 'high', i + 1, trimmed));
    }
    if (httpRequestPattern.hasMatch(trimmed) && hasUserInput) {
      addFinding(SecurityFinding('ssrf.dynamicRequest',
          'http(s).request invoked with user data; ensure host is vetted to avoid SSRF.', 'high', i + 1, trimmed));
    }
    if (sqlTemplatePattern.hasMatch(trimmed)) {
      addFinding(SecurityFinding('injection.sqlTemplate',
          'SQL query built via template literal with interpolation; use parameterized queries.', 'high', i + 1, trimmed));
    }
    if (sqlConcatPattern.hasMatch(trimmed) && hasUserInput) {
      addFinding(SecurityFinding('injection.sqlConcat',
          'SQL query concatenates user-controlled data; use bound parameters to avoid injection.', 'high', i + 1, trimmed));
    }
    if (lodashMergePattern.hasMatch(trimmed) && hasUserInput) {
      addFinding(SecurityFinding('prototype.mergeUserInput',
          '_.merge merges user data into an object; guard against prototype pollution.', 'high', i + 1, trimmed));
    }
    if (objectAssignPattern.hasMatch(trimmed) && trimmed.contains('{') && hasUserInput) {
      addFinding(SecurityFinding('prototype.assignUserInput',
          'Object.assign merges user data into a plain object; guard against prototype pollution.', 'high', i + 1, trimmed));
    }
    if (pathJoinPattern.hasMatch(trimmed) && (trimmed.contains('..') || hasPathInput)) {
      addFinding(SecurityFinding('path.join.userInput',
          'path.join combines user-controlled paths; ensure traversal is prevented.', 'high', i + 1, trimmed));
    }
    if (extractPattern.hasMatch(trimmed) && trimmed.contains('..')) {
      addFinding(SecurityFinding('zipSlip.entryPath',
          'Archive extraction may write paths containing ".." (Zip Slip).', 'high', i + 1, trimmed));
    }
    if (entryPathPattern.hasMatch(trimmed) && trimmed.contains('..')) {
      addFinding(SecurityFinding('zipSlip.entryPath',
          'Archive entry path contains ".." allowing traversal outside target.', 'high', i + 1, trimmed));
    }
    if (spawnExecPattern.hasMatch(trimmed) && hasUserInput &&
        (trimmed.contains('+') || trimmed.contains(r'${'))) {
      addFinding(SecurityFinding('child_process.userArgs',
          'child_process spawn/execFile combines user-controlled data into command arguments; avoid concatenation and prefer sanitized argument arrays.',
          'high', i + 1, trimmed));
    }
    if (storageApiPattern.hasMatch(trimmed) && storageTokenPattern.hasMatch(trimmed) &&
        trimmed.contains('=')) {
      addFinding(SecurityFinding('storage.token.assignment',
          'Token data written to web storage/IndexedDB; store tokens in short-lived, HttpOnly cookies instead.',
          'med', i + 1, trimmed));
    }
    if (raw.contains('fs.') && raw.contains('..')) {
      addFinding(SecurityFinding('fs.dotdot', 'Possible path traversal ("..")', 'med', i + 1, raw.trim()));
    }
  }

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
      addExport('reexports', spec);
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
      final spec = m2.group(1)!;
      addImport(spec, 'reexport');
      addExport('reexports', spec);
      final starAs = RegExp(r'^\s*export\s+\*\s+as\s+([A-Za-z0-9_\$]+)').firstMatch(trimmed);
      if (starAs != null) {
        addExport('named', starAs.group(1)!);
      }
      if (RegExp(r'^\s*export\s+\*\s+').hasMatch(trimmed)) {
        addExport('starReexports', spec);
      }
      if (RegExp(r'^\s*export\s+default\b').hasMatch(trimmed)) {
        addExport('default', 'from ' + spec);
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
    final spec = match.group(1)!;
    addImport(spec, 'reexport');
    addExport('reexports', spec);
  }
  final reStarReexport =
      RegExp(r'''export\s+\*\s+from\s*['"]([^'"]+)['"]''', multiLine: true);
  for (final match in reStarReexport.allMatches(sanitized)) {
    final spec = match.group(1)!;
    addImport(spec, 'reexport');
    addExport('reexports', spec);
    addExport('starReexports', spec);
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
  return _FileFacts(filePath, imports, sideEffectOnly, exports, findings);
}

String _stripLineCommentPreservingStrings(String line) {
  var inSingle = false;
  var inDouble = false;
  var inBacktick = false;
  final buffer = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '\\') {
      if (inSingle || inDouble || inBacktick) {
        if (i + 1 < line.length) {
          buffer.write(ch);
          buffer.write(line[i + 1]);
          i++;
          continue;
        }
      }
    }
    if (!inDouble && !inBacktick && ch == "'") {
      inSingle = !inSingle;
      buffer.write(ch);
      continue;
    }
    if (!inSingle && !inBacktick && ch == '"') {
      inDouble = !inDouble;
      buffer.write(ch);
      continue;
    }
    if (!inSingle && !inDouble && ch == '`') {
      inBacktick = !inBacktick;
      buffer.write(ch);
      continue;
    }
    if (!inSingle && !inDouble && !inBacktick && ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
      break;
    }
    buffer.write(ch);
  }
  return buffer.toString();
}

List<int> _computeLineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      starts.add(i + 1);
    }
  }
  return starts;
}

int _lineNumberForOffset(List<int> starts, int offset, int totalLength) {
  if (starts.isEmpty) {
    return 1;
  }
  var low = 0;
  var high = starts.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final start = starts[mid];
    final nextStart = mid + 1 < starts.length ? starts[mid + 1] : totalLength + 1;
    if (offset < start) {
      high = mid - 1;
    } else if (offset >= nextStart) {
      low = mid + 1;
    } else {
      return mid + 1;
    }
  }
  return starts.length;
}

String _lineAt(List<String> lines, int lineNumber) {
  if (lineNumber < 1 || lineNumber > lines.length) {
    return '';
  }
  return lines[lineNumber - 1];
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

Map<String, dynamic>? _computePackageRisks(Map<String, dynamic>? pkg) {
  if (pkg == null) return null;
  final risks = <String, dynamic>{};
  final looseVersionPattern = RegExp(r'[\^\~\*x]|latest|github\.com|git\+');

  final depFields = ['dependencies', 'devDependencies', 'optionalDependencies'];
  final loose = <String, Map<String, String>>{};
  for (final field in depFields) {
    final deps = pkg[field];
    if (deps is Map) {
      final items = <String, String>{};
      deps.forEach((key, value) {
        if (value is String && looseVersionPattern.hasMatch(value)) {
          items[key] = value;
        }
      });
      if (items.isNotEmpty) {
        loose[field] = items;
      }
    }
  }
  if (loose.isNotEmpty) {
    risks['looseVersions'] = loose;
  }

  final scripts = pkg['scripts'];
  if (scripts is Map) {
    final bad = <String, String>{};
    scripts.forEach((key, value) {
      if (value is String && RegExp(r'(curl|wget|bash|powershell|Invoke-Expression)').hasMatch(value)) {
        bad[key] = value;
      }
    });
    if (bad.isNotEmpty) {
      risks['riskyScripts'] = bad;
    }
  }

  return risks.isEmpty ? null : risks;
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

List<SecurityFinding> collectSecurityFindingsForTest(String path, String text) {
  return _extractFacts(path, text).findings;
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

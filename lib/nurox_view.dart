// nurox_view.dart — minimal controller for Nurox Nexus
// - Serves your existing nuros_nexus.html on localhost (still supports legacy nexus.html)
// - Orchestrates language crawlers (executables) by spawning them in the selected root
// - Merges multiple *Dependencies.json files into one in-memory graph
// - Simple REST API + bearer token security
//
// Build:   dart compile exe nurox_view.dart -o nurox-view
// Run:     ./nurox-view
//
// Default endpoints:
//   GET  /                 -> nuros_nexus.html (token injected as <meta>)
//   GET  /api/languages    -> which crawlers are available
//   POST /api/crawl        -> { root, languages: ["js","py", ...] }  (spawns crawlers)
//   GET  /api/graph        -> { nodes, edges }  (merged)
//
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ----------------------------
// Types
// ----------------------------
const _edgeSourceKeys = [
  'source',
  'sourceId',
  'src',
  'srcId',
  'from',
  'fromId',
  'origin',
  'start',
  'u',
];

const _edgeTargetKeys = [
  'target',
  'targetId',
  'to',
  'toId',
  'dst',
  'dstId',
  'dest',
  'destination',
  'end',
  'v',
];

const _edgeKindKeys = ['kind', 'type', 'label', 'edgeType'];
const _edgeCertaintyKeys = ['certainty', 'confidence'];

const _nodeIdCandidateKeys = [
  'id',
  'nodeId',
  'node',
  'path',
  'file',
  'module',
  'source',
  'sourceId',
  'src',
  'srcId',
  'target',
  'targetId',
  'dst',
  'dstId',
  'from',
  'fromId',
  'to',
  'toId',
  'absPath',
  'realPath',
  'canonicalPath',
  'uri',
  'ref',
  'name',
  'value',
];

const _edgePassthroughKeys = {
  'dynamic',
  'reflection',
  'mode',
  'phase',
  'stage',
  'scope',
  'context',
  'profiles',
  'profile',
  'when',
  'flags',
  'test',
  'build',
  'id',
  'weight',
  'strength',
  'evidence',
  'notes',
  'metadata',
  'tags',
};

dynamic _firstNonNullEdgeValue(Map<dynamic, dynamic> edge, List<String> keys) {
  for (final key in keys) {
    if (!edge.containsKey(key)) continue;
    final value = edge[key];
    if (value != null) return value;
  }
  return null;
}

String? _extractGraphNodeId(dynamic raw, [Set<Object?>? visited]) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is num) {
    if (raw is double && !raw.isFinite) return null;
    return raw.toString();
  }
  visited ??= <Object?>{};
  if (raw is Map) {
    if (!visited.add(raw)) return null;
    for (final key in _nodeIdCandidateKeys) {
      if (!raw.containsKey(key)) continue;
      final candidate = _extractGraphNodeId(raw[key], visited);
      if (candidate != null) return candidate;
    }
    for (final value in raw.values) {
      final candidate = _extractGraphNodeId(value, visited);
      if (candidate != null) return candidate;
    }
    return null;
  }
  if (raw is Iterable) {
    for (final item in raw) {
      final candidate = _extractGraphNodeId(item, visited);
      if (candidate != null) return candidate;
    }
    return null;
  }
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

String _edgeString(dynamic value) {
  if (value == null) return '';
  final text = value.toString().trim();
  return text;
}

dynamic _normalizeEdgeCertainty(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num) {
    if (value is double && !value.isFinite) return null;
    return value;
  }
  if (value is bool) return value;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

Map<String, dynamic> _normalizeEdgeRecord(Map<dynamic, dynamic> raw) {
  final sourceValue = _firstNonNullEdgeValue(raw, _edgeSourceKeys);
  final targetValue = _firstNonNullEdgeValue(raw, _edgeTargetKeys);
  final sourceId = _extractGraphNodeId(sourceValue);
  final targetId = _extractGraphNodeId(targetValue);
  if (sourceId == null || targetId == null) {
    return const <String, dynamic>{};
  }

  final kindValue = _firstNonNullEdgeValue(raw, _edgeKindKeys);
  final certaintyValue = _firstNonNullEdgeValue(raw, _edgeCertaintyKeys);

  final normalized = <String, dynamic>{
    'source': sourceId,
    'target': targetId,
  };

  final kind = _edgeString(kindValue);
  if (kind.isNotEmpty) {
    normalized['kind'] = kind;
  }

  final certainty = _normalizeEdgeCertainty(certaintyValue);
  if (certainty != null) {
    normalized['certainty'] = certainty;
  }

  for (final key in _edgePassthroughKeys) {
    if (!raw.containsKey(key)) continue;
    final value = raw[key];
    if (value == null) continue;
    normalized[key] = _cloneJsonLike(value);
  }

  return normalized;
}

class Graph {
  final Map<String, Map<String, dynamic>> nodes = {};
  final Set<String> edgeKeys = {};
  final List<Map<String, dynamic>> edges = [];
  final Map<String, List<Map<String, dynamic>>> securityFindings = {};
  final Map<String, Map<String, dynamic>> exports = {};
  final Set<String> entrypoints = <String>{};

  void addGraph(Map<String, dynamic> g) {
    final ns = (g['nodes'] as List?) ?? const [];
    final es = (g['edges'] as List?) ?? (g['links'] as List?) ?? const [];
    for (final n in ns) {
      final id = (n['id'] ?? '').toString();
      if (id.isEmpty) continue;
      if (!nodes.containsKey(id)) {
        nodes[id] = Map<String, dynamic>.from(n);
      } else {
        // merge: prefer non-null, upgrade state to "used" if any used, keep larger sizeLOC
        final dst = nodes[id]!;
        for (final k in n.keys) {
          final v = n[k];
          if (k == 'state') {
            final a = (dst[k] ?? '').toString();
            final b = (v ?? '').toString();
            if (a != 'used' && (b == 'used' || b == 'side_effect_only')) dst[k] = b;
          } else if (k == 'sizeLOC') {
            final ai = (dst[k] is int) ? dst[k] as int : 0;
            final bi = (v is int) ? v : 0;
            if (bi > ai) dst[k] = bi;
          } else if (dst[k] == null && v != null) {
            dst[k] = v;
          }
        }
      }
    }
    for (final rawEdge in es) {
      if (rawEdge is! Map) continue;
      final normalized = _normalizeEdgeRecord(rawEdge);
      if (normalized.isEmpty) continue;
      final src = normalized['source']?.toString() ?? '';
      final tgt = normalized['target']?.toString() ?? '';
      final kind = normalized['kind']?.toString() ?? '';
      final key = '$src=>$tgt:$kind';
      if (!edgeKeys.add(key)) continue;
      edges.add(normalized);
    }

    _mergeSecurityFindings(this, g);
    _mergeExports(this, g);
    _mergeEntrypoints(this, g);
  }

  Map<String, dynamic> toJson() => {
        'nodes': nodes.values.toList(),
        'edges': edges,
        if (entrypoints.isNotEmpty) 'entrypoints': entrypoints.toList(),
        if (securityFindings.isNotEmpty)
          'securityFindings': securityFindings.map(
            (key, value) => MapEntry(
              key,
              value.map((finding) => Map<String, dynamic>.from(finding)).toList(),
            ),
          ),
        if (exports.isNotEmpty)
          'exports': exports.map(
            (key, value) => MapEntry(key, _cloneJsonLike(value)),
          ),
      };
}

void _mergeEntrypoints(Graph graph, Map<String, dynamic> source) {
  void addEntrypoint(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return;
    graph.entrypoints.add(value);
  }

  void ingest(dynamic data) {
    if (data == null) return;
    if (data is Iterable) {
      for (final item in data) {
        ingest(item);
      }
      return;
    }
    if (data is Map) {
      if (data['id'] != null) addEntrypoint(data['id'].toString());
      if (data['path'] != null) addEntrypoint(data['path'].toString());
      final list = data['list'];
      if (list is Iterable) {
        ingest(list);
      }
      return;
    }
    addEntrypoint(data.toString());
  }

  const candidateKeys = [
    'entrypoints',
    'entryPoints',
    'entry_points',
    'entries',
    'entrances',
  ];

  for (final key in candidateKeys) {
    ingest(source[key]);
  }
}

void _mergeSecurityFindings(Graph graph, Map<String, dynamic> source) {
  final security = source['securityFindings'];
  if (security is Map) {
    security.forEach((rawKey, rawValue) {
      if (rawKey == null) return;
      final findings = _normalizeSecurityFindingList(rawValue);
      _registerSecurityFindings(graph, rawKey.toString(), findings);
    });
  }

  final securityBlock = source['security'];
  if (securityBlock is Map) {
    final nested = securityBlock['findings'];
    if (nested is Map) {
      nested.forEach((rawKey, rawValue) {
        if (rawKey == null) return;
        final findings = _normalizeSecurityFindingList(rawValue);
        _registerSecurityFindings(graph, rawKey.toString(), findings);
      });
    }
  }

  final nodes = source['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final directFindings = <Map<String, dynamic>>[];
      directFindings.addAll(_normalizeSecurityFindingList(node['securityFindings']));
      final securityInfo = node['security'];
      if (securityInfo is Map && securityInfo['findings'] != null) {
        directFindings.addAll(_normalizeSecurityFindingList(securityInfo['findings']));
      }
      if (directFindings.isEmpty) continue;
      final candidates = _collectSecurityCandidates(node);
      if (candidates.isEmpty) {
        final id = node['id'];
        if (id is String && id.trim().isNotEmpty) {
          _registerSecurityFindings(graph, id, directFindings);
        }
        continue;
      }
      for (final candidate in candidates) {
        _registerSecurityFindings(graph, candidate, directFindings);
      }
    }
  }
}

void _registerSecurityFindings(
  Graph graph,
  String rawKey,
  List<Map<String, dynamic>> findings,
) {
  final trimmed = rawKey.trim();
  if (trimmed.isEmpty || findings.isEmpty) return;
  final canonical = _canonicalizeSecurityKey(trimmed);
  final key = canonical.isNotEmpty ? canonical : trimmed;

  final bucket = graph.securityFindings.putIfAbsent(key, () => []);
  final seen = bucket.map(_securityFindingKey).toSet();

  for (final finding in findings) {
    final normalized = _normalizeSecurityFindingRecord(finding);
    if (normalized == null) continue;
    final id = _securityFindingKey(normalized);
    if (seen.add(id)) {
      bucket.add(normalized);
    }
  }
}

List<Map<String, dynamic>> _normalizeSecurityFindingList(dynamic raw) {
  final result = <Map<String, dynamic>>[];
  if (raw is List) {
    for (final entry in raw) {
      if (entry is Map) {
        final normalized = _normalizeSecurityFindingRecord(entry);
        if (normalized != null) result.add(normalized);
      }
    }
  } else if (raw is Map) {
    final normalized = _normalizeSecurityFindingRecord(raw);
    if (normalized != null) result.add(normalized);
  }
  return result;
}

Map<String, dynamic>? _normalizeSecurityFindingRecord(Map raw) {
  final message = raw['message'];
  final id = raw['id'];
  final severity = raw['severity'];
  final severityNorm = raw['severityNormalized'];
  final line = raw['line'];
  final code = raw['code'];

  if (message == null && id == null && severity == null && code == null) {
    return null;
  }

  final record = <String, dynamic>{};
  if (id != null) record['id'] = id.toString();
  if (message != null) record['message'] = message.toString();
  if (severity != null) record['severity'] = severity.toString();
  if (severityNorm != null) {
    record['severityNormalized'] = severityNorm.toString();
  }
  if (line is num) record['line'] = line is int ? line : line.toInt();
  if (code != null) record['code'] = code.toString();
  return record;
}

String _securityFindingKey(Map<String, dynamic> finding) {
  final sevNorm = finding['severityNormalized']?.toString() ?? '';
  final sev = finding['severity']?.toString() ?? '';
  final id = finding['id']?.toString() ?? '';
  final line = finding['line']?.toString() ?? '';
  final message = finding['message']?.toString() ?? '';
  final code = finding['code']?.toString() ?? '';
  return '$sevNorm|$sev|$id|$line|$message|$code';
}

void _mergeExports(Graph graph, Map<String, dynamic> source) {
  final container = source['exports'];
  if (container is! Map) return;
  container.forEach((rawId, rawGroups) {
    if (rawId == null) return;
    final id = rawId.toString().trim();
    if (id.isEmpty) return;
    final canonical = _canonicalizeSecurityKey(id);
    final key = canonical.isNotEmpty ? canonical : id;
    final groups = _normalizeExportGroups(rawGroups);
    if (groups == null || groups.isEmpty) return;
    graph.exports.update(
      key,
      (existing) {
        final merged = <String, dynamic>{};
        existing.forEach((k, v) {
          merged[k] = _cloneJsonLike(v);
        });
        for (final entry in groups.entries) {
          merged[entry.key] = _cloneJsonLike(entry.value);
        }
        return merged;
      },
      ifAbsent: () {
        final initial = <String, dynamic>{};
        for (final entry in groups.entries) {
          initial[entry.key] = _cloneJsonLike(entry.value);
        }
        return initial;
      },
    );
  });
}

Map<String, dynamic>? _normalizeExportGroups(dynamic raw) {
  if (raw is! Map) return null;
  final normalized = <String, dynamic>{};
  raw.forEach((rawKey, rawValue) {
    if (rawKey == null) return;
    final key = rawKey.toString().trim();
    if (key.isEmpty) return;
    normalized[key] = _cloneJsonLike(rawValue);
  });
  return normalized;
}

dynamic _cloneJsonLike(dynamic value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((k, v) {
      if (k == null) return;
      result[k.toString()] = _cloneJsonLike(v);
    });
    return result;
  }
  if (value is List) {
    return value.map(_cloneJsonLike).toList();
  }
  return value;
}

String _canonicalizeSecurityKey(String raw) {
  if (raw.isEmpty) return raw;
  var value = raw;
  const windowsExtendedPrefix = '\\?\\';
  if (value.startsWith(windowsExtendedPrefix)) {
    value = value.substring(windowsExtendedPrefix.length);
  }
  final hadUncPrefix =
      value.startsWith('\\\\') || value.startsWith('\\/') || value.startsWith('//');
  value = value.replaceAll('\\', '/');
  if (hadUncPrefix && !value.startsWith('//')) {
    value = '//' + value.replaceFirst(RegExp(r'^/+'), '');
  }
  if (value.startsWith('//')) {
    final body = value.substring(2).replaceAll(RegExp(r'/+'), '/');
    value = '//' + body;
  } else {
    value = value.replaceAll(RegExp(r'/+'), '/');
  }
  final drive = RegExp(r'^([a-zA-Z]):/').firstMatch(value);
  if (drive != null) {
    value = '${drive.group(1)!.toUpperCase()}${value.substring(1)}';
  }
  return value;
}

Set<String> _collectSecurityCandidates(Map<String, dynamic> node) {
  const candidateKeys = [
    'id',
    'absPath',
    'path',
    'file',
    'module',
    'source',
    'resolvedPath',
    'realPath',
    'canonicalPath',
    'uri',
  ];

  final values = <String>{};

  void gather(dynamic value) {
    if (value == null) return;
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) values.add(trimmed);
      return;
    }
    if (value is Iterable) {
      for (final item in value) {
        gather(item);
      }
      return;
    }
    if (value is Map) {
      for (final key in candidateKeys) {
        if (value.containsKey(key)) {
          gather(value[key]);
        }
      }
    }
  }

  for (final key in candidateKeys) {
    if (node.containsKey(key)) {
      gather(node[key]);
    }
  }

  final meta = node['meta'];
  if (meta is Map<String, dynamic>) {
    gather(meta);
  }

  return values;
}

// ----------------------------
// Initial graph bootstrapping
// ----------------------------
Future<Graph> _loadInitialGraph() async {
  final graph = Graph();
  final data = await _loadBundledGraph();
  if (data != null) {
    graph.addGraph(data);
    _log('Loaded bundled sample graph with ${graph.nodes.length} nodes / ${graph.edges.length} edges');
  } else {
    _log('No bundled sample graph found; starting empty.');
  }
  return graph;
}

Future<Map<String, dynamic>?> _loadBundledGraph() async {
  const candidates = [
    'jsDependencies.json',
    'samples/jsDependencies.json',
  ];

  final locations = <String>{};
  locations.add(Directory.current.path);
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    locations.add(scriptDir);
    locations.add(_join(scriptDir, 'public'));
    locations.add(_join(scriptDir, 'samples'));
    final scriptParent = Directory(scriptDir).parent.path;
    locations.add(scriptParent);
    locations.add(_join(scriptParent, 'public'));
    locations.add(_join(scriptParent, 'samples'));
  } catch (_) {}
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  locations.add(exeDir);
  locations.add(_join(exeDir, 'public'));
  locations.add(_join(exeDir, 'samples'));
  final exeParent = Directory(exeDir).parent.path;
  locations.add(exeParent);
  locations.add(_join(exeParent, 'public'));
  locations.add(_join(exeParent, 'samples'));

  final visited = <String>{};

  Future<Map<String, dynamic>?> tryPath(String path) async {
    final normalized = File(path).absolute.path;
    if (!visited.add(normalized)) return null;
    final file = File(normalized);
    if (!await file.exists()) return null;
    try {
      final jsonText = await file.readAsString();
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) {
        _log('Loaded bundled graph from ${file.path}');
        return decoded;
      }
      _warn('Bundled graph ${file.path} did not contain a JSON object');
    } catch (e) {
      _warn('Failed to read bundled graph ${file.path}: $e');
    }
    return null;
  }

  for (final candidate in candidates) {
    final direct = await tryPath(candidate);
    if (direct != null) return direct;
    for (final base in locations) {
      if (base.isEmpty) continue;
      final hit = await tryPath(_join(base, candidate));
      if (hit != null) return hit;
    }
  }

  return null;
}

// ----------------------------
// Config: known crawler exe names
// (edit or extend as you add languages)
// ----------------------------
final Map<String, List<String>> _crawlerCandidates = {
  'js':      ['jsDependency', 'jsDependency.exe', 'lib/jsDependency.dart'],
  'py':      ['pyDependency', 'pyDependency.exe', 'lib/pyDependency.dart'],
  'go':      ['goDependency', 'goDependency.exe', 'lib/goDependency.dart'],
  'rust':    ['rustDependency', 'rustDependency.exe', 'lib/rustDependency.dart'],
  'java':    ['javaDependency', 'javaDependency.exe', 'lib/javaDependency.dart'],
  'kotlin':  ['kotlinDependency', 'kotlinDependency.exe', 'lib/kotlinDependency.dart'],
  'csharp':  ['csharpDependency', 'csharpDependency.exe', 'lib/csharpDependency.dart'],
  'dart':    ['dartDependency', 'dartDependency.exe', 'lib/dartDependency.dart'],
};

// Optional: which output file each crawler writes by default
final Map<String, String> _defaultOutput = {
  'js': 'jsDependencies.json',
  'py': 'pyDependencies.json',
  'go': 'goDependencies.json',
  'rust': 'rustDependencies.json',
  'java': 'javaDependencies.json',
  'kotlin': 'kotlinDependencies.json',
  'csharp': 'csharpDependencies.json',
  'dart': 'dartDependencies.json',
};

final Map<String, List<String>> _additionalOutputs = {
  'dart': ['dartSecurity.json'],
};

// ----------------------------
// Globals
// ----------------------------
final _rand = Random.secure();
String _token = '';
Graph _lastGraph = Graph();

// ----------------------------
// Main
// ----------------------------
Future<void> main(List<String> args) async {
  final port = await _findFreePort(start: 5217, tries: 20);
  _token = _makeToken();

  _lastGraph = await _loadInitialGraph();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  _log('Nurox Viewer running at http://127.0.0.1:$port');
  _log('Security token: $_token');

  _openBrowser('http://127.0.0.1:$port/?token=$_token');

  await for (final req in server) {
    try {
      await _route(req, port);
    } catch (e, st) {
      _warn('Error: $e\n$st');
      _sendJson(req, 500, {'error': 'internal_error'});
    }
  }
}

// ----------------------------
// Router
// ----------------------------
Future<void> _route(HttpRequest req, int port) async {
  final path = req.uri.path;
  final method = req.method.toUpperCase();
  _debugRequest(req);

  // static: "/" -> nuros_nexus.html (with token injected)
  if (method == 'GET' &&
      (path == '/' ||
          path == '/index.html' ||
          path == '/nuros_nexus.html' ||
          path == '/nexus.html')) {
    final html = await _loadViewerHtml();
    final injected = _injectTokenIntoHtml(html, _token);
    req.response.headers.contentType = ContentType.html;
    req.response.write(injected);
    await req.response.close();
    return;
  }

  if (method == 'GET' && path == '/favicon.ico') {
    final icon = await _locateResource('favicon.ico');
    if (icon != null) {
      req.response.headers.contentType = ContentType('image', 'x-icon');
      req.response.headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=86400');
      req.response.add(await icon.readAsBytes());
      await req.response.close();
    } else {
      _warn('Favicon not found while serving /favicon.ico');
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    }
    return;
  }

  // small probe
  if (method == 'GET' && path == '/healthz') {
    _sendText(req, 200, 'ok');
    return;
  }

  // API guard
  final isApi = path.startsWith('/api/');
  if (isApi && !_authorized(req)) {
    _sendJson(req, 401, {'error': 'unauthorized'});
    return;
  }

  // Static assets (e.g. /js/graph-preprocessing.js, /samples/foo.json)
  if (!isApi && method == 'GET') {
    final relative = path.startsWith('/') ? path.substring(1) : path;
    if (relative.isNotEmpty && _isSafeStaticPath(relative)) {
      final resource = await _locateResource(relative);
      if (resource != null && await resource.exists()) {
        await _sendStaticFile(req, resource, relative);
        return;
      }
    }
  }

  // GET /api/languages -> which crawlers are available
  if (method == 'GET' && path == '/api/languages') {
    final langs = <String, Map<String, dynamic>>{};
    for (final entry in _crawlerCandidates.entries) {
      final resolved = await _findExecutable(entry.value);
      langs[entry.key] = {
        'available': resolved != null,
        if (resolved != null) 'path': resolved,
      };
    }
    _sendJson(req, 200, {'languages': langs});
    return;
  }

  // POST /api/crawl  { root, languages: ["js","py"], clear?: true }
  if (method == 'POST' && path == '/api/crawl') {
    final body = await utf8.decoder.bind(req).join();
    if (body.isEmpty) {
      _log('  body: <empty>');
    } else {
      _log('  body (${body.length} bytes): $body');
    }
    final cfg = (body.isNotEmpty ? jsonDecode(body) : {}) as Map<String, dynamic>;
    final rawRoot = (cfg['root'] ?? '').toString();
    final root = _resolveRootPath(rawRoot);
    final langs = ((cfg['languages'] ?? const []) as List).map((e) => e.toString()).toList();
    final clear = cfg['clear'] == true;

    if (root.isEmpty || langs.isEmpty) {
      _sendJson(req, 400, {'error': 'missing root or languages'});
      return;
    }
    final dir = Directory(root);
    if (!await dir.exists()) {
      _sendJson(req, 400, {'error': 'root_not_found'});
      return;
    }

    if (clear) _lastGraph = Graph();

    // Run crawlers sequentially (simpler). You can parallelize later.
    final collected = <Map<String, dynamic>>[];
    for (final lang in langs) {
      final exe = await _resolveCrawler(lang);
      if (exe == null) {
        _warn('No crawler available for "$lang"');
        continue;
      }
      final code = await _runCrawler(exe, root);
      if (code != 0) {
        _warn('$exe exited with code $code');
      }
      // read the default output (if present)
      final defaultName = _defaultOutput[lang] ?? '${lang}Dependencies.json';
      final outFile = File(_join(root, defaultName));
      if (await outFile.exists()) {
        final baseGraph = await _readJsonFileIfExists(outFile);
        if (baseGraph != null) {
          collected.add(baseGraph);
        }
      } else {
        _warn('Expected output not found for "$lang": ${outFile.path}');
      }

      final extras = _additionalOutputs[lang] ?? const <String>[];
      for (final extra in extras) {
        final extraFile = File(_join(root, extra));
        if (!await extraFile.exists()) {
          continue;
        }
        final rawExtra = await _readJsonFileIfExists(extraFile);
        if (rawExtra == null) {
          continue;
        }
        final fragment = _graphFromAdditionalOutput(lang, extra, rawExtra);
        if (fragment != null) {
          collected.add(fragment);
        } else {
          _warn('Unsupported additional output for "$lang": ${extraFile.path}');
        }
      }
    }

    // Merge and stash
    for (final g in collected) {
      _lastGraph.addGraph(g);
    }
    _log('  merged graph now has ${_lastGraph.nodes.length} nodes / ${_lastGraph.edges.length} edges');
    _sendJson(req, 200, {'ok': true, 'nodes': _lastGraph.nodes.length, 'edges': _lastGraph.edges.length});
    return;
  }

  // GET /api/graph -> merged graph (or empty)
  if (method == 'GET' && path == '/api/graph') {
    _log('  serving merged graph with ${_lastGraph.nodes.length} nodes / ${_lastGraph.edges.length} edges');
    _sendJson(req, 200, _lastGraph.toJson());
    return;
  }

  _sendJson(req, 404, {'error': 'not_found'});
}

// ----------------------------
// Helpers: security / html
// ----------------------------
bool _authorized(HttpRequest req) {
  final hdr = req.headers.value('authorization') ?? '';
  if (!hdr.startsWith('Bearer ')) return false;
  final tok = hdr.substring(7);
  return tok == _token;
}

Future<String> _loadViewerHtml() async {
  const candidates = ['nuros_nexus.html', 'nexus.html'];

  for (final name in candidates) {
    final local = File(name);
    if (await local.exists()) return await local.readAsString();
  }

  try {
    final exe = File(Platform.resolvedExecutable);
    final exeDir = exe.parent.path;
    for (final name in candidates) {
      final sibling = File(_join(exeDir, name));
      if (await sibling.exists()) return await sibling.readAsString();
    }
  } catch (_) {}

  // Fallback: minimal inline page that asks user to load data or crawl
  return _fallbackHtml;
}

Future<File?> _locateResource(String relativePath) async {
  final visited = <String>{};

  Future<File?> probe(String path) async {
    if (path.isEmpty) return null;
    final file = File(path);
    final normalized = file.absolute.path;
    if (!visited.add(normalized)) return null;
    if (await file.exists()) return file;
    return null;
  }

  String sanitize(String input) {
    var value = input;
    if (value.startsWith('/')) value = value.substring(1);
    return value;
  }

  final initial = sanitize(relativePath);
  final variants = <String>{initial};
  if (initial.startsWith('public/')) {
    variants.add(initial.substring('public/'.length));
  }

  final bases = <String>{};
  bases.add(Directory.current.path);
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    bases.add(scriptDir);
    bases.add(_join(scriptDir, 'public'));
    final scriptParent = Directory(scriptDir).parent.path;
    bases.add(scriptParent);
    bases.add(_join(scriptParent, 'public'));
  } catch (_) {}
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    bases.add(exeDir);
    bases.add(_join(exeDir, 'public'));
    final exeParent = Directory(exeDir).parent.path;
    bases.add(exeParent);
    bases.add(_join(exeParent, 'public'));
  } catch (_) {}

  Future<File?> searchVariants(Iterable<String> candidates) async {
    for (final candidate in candidates) {
      final direct = await probe(candidate);
      if (direct != null) return direct;

      final publicDirect = await probe(_join('public', candidate));
      if (publicDirect != null) return publicDirect;

      for (final base in bases) {
        if (base.isEmpty) continue;
        final fromBase = await probe(_join(base, candidate));
        if (fromBase != null) return fromBase;

        final fromBasePublic = await probe(_join(_join(base, 'public'), candidate));
        if (fromBasePublic != null) return fromBasePublic;
      }
    }
    return null;
  }

  return await searchVariants(variants);
}

Future<Map<String, dynamic>?> _readJsonFileIfExists(File file) async {
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, dynamic>) return decoded;
    _warn('Expected JSON object in ${file.path} but found ${decoded.runtimeType}');
  } catch (e) {
    _warn('Failed to read ${file.path}: $e');
  }
  return null;
}

Map<String, dynamic>? _graphFromAdditionalOutput(
  String lang,
  String fileName,
  Map<String, dynamic> data,
) {
  if (lang == 'dart' && fileName.toLowerCase().contains('security')) {
    return _securityGraphFragment(data);
  }
  return null;
}

Map<String, dynamic>? _securityGraphFragment(Map<String, dynamic> data) {
  final findingsByFile = <String, List<Map<String, dynamic>>>{};
  final findings = data['findings'];
  if (findings is List) {
    for (final entry in findings) {
      if (entry is! Map) continue;
      final file = entry['file'];
      if (file == null) continue;
      final key = file.toString().trim();
      if (key.isEmpty) continue;
      final cloned = _cloneJsonLike(entry);
      if (cloned is Map<String, dynamic>) {
        findingsByFile.putIfAbsent(key, () => []).add(cloned);
      }
    }
  }

  if (findingsByFile.isEmpty && (findings is! List || findings.isEmpty)) {
    // If there are no findings, still return the security summary so the UI can show totals.
    return {'security': _cloneJsonLike(data)};
  }

  return {
    'security': _cloneJsonLike(data),
    if (findingsByFile.isNotEmpty) 'securityFindings': findingsByFile,
  };
}

bool _isSafeStaticPath(String relative) {
  if (relative.contains('..')) return false;
  if (relative.contains('\\')) return false;
  return true;
}

Future<void> _sendStaticFile(
    HttpRequest req, File file, String relativePath) async {
  final type = _contentTypeFor(relativePath);
  if (type != null) {
    req.response.headers.contentType = type;
  } else {
    req.response.headers.contentType = ContentType.binary;
  }
  if (type != null && _treatAsText(type)) {
    req.response.write(await file.readAsString());
  } else {
    req.response.add(await file.readAsBytes());
  }
  await req.response.close();
}

ContentType? _contentTypeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.js')) {
    return ContentType('application', 'javascript', charset: 'utf-8');
  }
  if (lower.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (lower.endsWith('.html')) {
    return ContentType.html;
  }
  if (lower.endsWith('.json')) {
    return ContentType('application', 'json', charset: 'utf-8');
  }
  if (lower.endsWith('.svg')) {
    return ContentType('image', 'svg+xml');
  }
  if (lower.endsWith('.png')) {
    return ContentType('image', 'png');
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  if (lower.endsWith('.ico')) {
    return ContentType('image', 'x-icon');
  }
  if (lower.endsWith('.txt')) {
    return ContentType('text', 'plain', charset: 'utf-8');
  }
  if (lower.endsWith('.wasm')) {
    return ContentType('application', 'wasm');
  }
  if (lower.endsWith('.map')) {
    return ContentType('application', 'json', charset: 'utf-8');
  }
  if (lower.endsWith('.woff2')) {
    return ContentType('font', 'woff2');
  }
  return null;
}

bool _treatAsText(ContentType type) {
  if (type.primaryType == 'text') return true;
  if (type.primaryType == 'application') {
    return type.subType == 'json' || type.subType == 'javascript';
  }
  return false;
}

String _injectTokenIntoHtml(String html, String token) {
  const marker = '</head>';
  final meta = '<meta name="nurox-token" content="$token">';
  if (html.contains(marker)) {
    // Insert the meta tag just before </head>
    return html.replaceFirst(marker, '$meta\n$marker');
  }
  // If there’s no </head>, just append the meta at the end
  return '$html\n$meta';
}

// ----------------------------
// Helpers: process / paths
// ----------------------------
Future<String?> _resolveCrawler(String lang) async {
  final candidates = _crawlerCandidates[lang] ?? const <String>[];
  return _findExecutable(candidates);
}

Future<String?> _findExecutable(List<String> names) async {
  final visited = <String>{};

  Future<String?> probeDir(String dir) async {
    if (dir.isEmpty) return null;
    final normalized = Directory(dir).absolute.path;
    if (!visited.add(normalized)) return null;
    for (final n in names) {
      final candidate = File(_join(normalized, n));
      if (await candidate.exists()) return candidate.path;
    }
    return null;
  }

  // 1) current directory
  final currentDir = Directory.current.path;
  final directHit = await probeDir(currentDir);
  if (directHit != null) return directHit;

  // 2) alongside the Dart entry-point (useful when running `dart run`)
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    final scriptHit = await probeDir(scriptDir);
    if (scriptHit != null) return scriptHit;
    final publicHit = await probeDir(_join(scriptDir, 'public'));
    if (publicHit != null) return publicHit;
    final scriptParent = Directory(scriptDir).parent.path;
    final parentHit = await probeDir(scriptParent);
    if (parentHit != null) return parentHit;
    final parentPublicHit = await probeDir(_join(scriptParent, 'public'));
    if (parentPublicHit != null) return parentPublicHit;
  } catch (_) {}

  // 3) alongside the compiled executable (when packaged)
  final binDir = File(Platform.resolvedExecutable).parent.path;
  final binHit = await probeDir(binDir);
  if (binHit != null) return binHit;
  final binPublicHit = await probeDir(_join(binDir, 'public'));
  if (binPublicHit != null) return binPublicHit;
  final binParent = Directory(binDir).parent.path;
  final binParentHit = await probeDir(binParent);
  if (binParentHit != null) return binParentHit;
  final binParentPublicHit = await probeDir(_join(binParent, 'public'));
  if (binParentPublicHit != null) return binParentPublicHit;

  // 4) PATH
  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    final hit = await probeDir(dir.trim());
    if (hit != null) return hit;
  }

  return null;
}

Future<int> _runCrawler(String exe, String root) async {
  final isDartScript = exe.toLowerCase().endsWith('.dart');
  final command = isDartScript ? 'dart' : exe;
  final args = isDartScript ? ['run', exe] : const <String>[];
  final display = isDartScript ? '$command ${args.join(' ')}' : exe;

  _log('Running: $display  (cwd: $root)');
  final p = await Process.start(command, args, // crawlers scan CWD; no flags needed
      workingDirectory: root, runInShell: true);

  // Stream to our stderr to show progress (optional)
  p.stdout.transform(utf8.decoder).listen((s) => stdout.write(s));
  p.stderr.transform(utf8.decoder).listen((s) => stderr.write(s));
  final code = await p.exitCode;
  _log('Exit [$exe]: $code');
  return code;
}

String _resolveRootPath(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;

  if (value == '~') {
    final home = _homeDirectory();
    if (home != null && home.isNotEmpty) return home;
    return value;
  }

  if (value.startsWith('~/') || value.startsWith('~\\')) {
    final home = _homeDirectory();
    if (home != null && home.isNotEmpty) {
      final remainder = value.substring(2);
      return _join(home, remainder);
    }
    return value;
  }

  try {
    final absolute = Directory(value).absolute.path;
    if (absolute.isNotEmpty) value = absolute;
  } catch (_) {}

  return value;
}

String? _homeDirectory() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
    final drive = env['HOMEDRIVE'];
    final path = env['HOMEPATH'];
    if (drive != null && path != null) {
      return '$drive$path';
    }
    return null;
  }
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) return home;
  return null;
}

String _join(String a, String b) {
  final sep = Platform.pathSeparator;
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final left = a.endsWith(sep) ? a.substring(0, a.length - 1) : a;
  final right = b.startsWith(sep) ? b.substring(1) : b;
  return '$left$sep$right';
}

// ----------------------------
// Helpers: net / token / open
// ----------------------------
Future<int> _findFreePort({int start = 5217, int tries = 20}) async {
  for (var i = 0; i < tries; i++) {
    final p = start + i;
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
      await s.close();
      return p;
    } catch (_) {}
  }
  // OS pick
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

String _makeToken() {
  final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

void _openBrowser(String url) {
  try {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [url]);
    }
  } catch (_) {}
}

// ----------------------------
// HTTP responders
// ----------------------------
Future<void> _sendJson(HttpRequest req, int code, Object body) async {
  req.response.statusCode = code;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

Future<void> _sendText(HttpRequest req, int code, String text) async {
  req.response.statusCode = code;
  req.response.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
  req.response.write(text);
  await req.response.close();
}

// ----------------------------
// Logging
// ----------------------------
void _log(String s) => stderr.writeln('[info] $s');
void _warn(String s) => stderr.writeln('[warn] $s');

void _debugRequest(HttpRequest req) {
  final method = req.method.toUpperCase();
  final uri = req.uri;
  final query = uri.query.isEmpty ? '' : '?${uri.query}';
  final remote = req.connectionInfo?.remoteAddress.address ?? 'unknown';
  _log('HTTP $method ${uri.path}$query from $remote');

  final referer = req.headers.value('referer') ?? 'n/a';
  final contentType = req.headers.contentType?.value ?? 'n/a';
  final contentLength = req.headers.contentLength;
  final auth = req.headers.value('authorization');
  final authHint = () {
    if (auth == null) return 'none';
    if (auth.startsWith('Bearer ') && auth.length > 10) {
      return 'Bearer …${auth.substring(auth.length - 4)}';
    }
    return auth;
  }();

  _log('  headers: referer=$referer, content-type=$contentType, length=${contentLength < 0 ? 'n/a' : contentLength}, authorization=$authHint');
}

// ----------------------------
// Minimal fallback HTML (only used if nuros_nexus.html/nexus.html not found)
// ----------------------------
const String _fallbackHtml = r'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<link rel="icon" type="image/x-icon" href="/favicon.ico"/>
<title>Nurox Viewer</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:2rem;background:#0b0d12;color:#e8ecf1}
button,input,select{font:inherit} .row{display:flex;gap:.5rem;align-items:center;margin:.5rem 0}
pre{background:#0f1320;border:1px solid rgba(255,255,255,.08);padding:1rem;border-radius:8px;max-height:40vh;overflow:auto}
</style>
</head><body>
<h1>Nurox Viewer</h1>
<p>This is a lightweight fallback page (couldn't find <code>nuros_nexus.html</code> or <code>nexus.html</code>). You can still crawl and view raw JSON:</p>
<div class="row">
  <label>Root: <input id="root" size="60" placeholder="C:\\repo or /home/me/repo"/></label>
  <label>Languages:
    <select id="langs" multiple size="6" style="min-width:14rem"></select>
  </label>
</div>
<div class="row">
  <button id="btnCrawl">Crawl</button>
  <button id="btnLoad">Load Merged Graph</button>
</div>
<pre id="out">(results appear here)</pre>
<script>
(async function(){
  const token = new URLSearchParams(location.search).get('token') ||
                document.querySelector('meta[name="nurox-token"]')?.content || '';
  const hdr = token ? {'Authorization': 'Bearer '+token} : {};
  const out = document.getElementById('out');
  const langsSel = document.getElementById('langs');
  const root = document.getElementById('root');

  async function loadLangs(){
    const r = await fetch('/api/languages', {headers: hdr});
    const j = await r.json();
    langsSel.innerHTML = '';
    Object.entries(j.languages).forEach(([k,v])=>{
      const o = document.createElement('option'); o.value=k; o.textContent = `${k} ${v.available?'✓':''}`;
      langsSel.appendChild(o);
    });
  }
  document.getElementById('btnCrawl').onclick = async ()=>{
    const sel = Array.from(langsSel.selectedOptions).map(o=>o.value);
    const r = await fetch('/api/crawl', {method:'POST', headers: {'Content-Type':'application/json', ...hdr},
      body: JSON.stringify({root: root.value.trim(), languages: sel, clear: true})});
    out.textContent = JSON.stringify(await r.json(), null, 2);
  };
  document.getElementById('btnLoad').onclick = async ()=>{
    const r = await fetch('/api/graph', {headers: hdr});
    out.textContent = JSON.stringify(await r.json(), null, 2);
  };
  await loadLangs();
})();
</script>
</body></html>''';

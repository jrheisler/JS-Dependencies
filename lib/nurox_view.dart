// nurox_view.dart — minimal controller for Nurox Nexus
// - Serves your existing nexus.html on localhost
// - Orchestrates language crawlers (executables) by spawning them in the selected root
// - Merges multiple *Dependencies.json files into one in-memory graph
// - Simple REST API + bearer token security
//
// Build:   dart compile exe nurox_view.dart -o nurox-view
// Run:     ./nurox-view
//
// Default endpoints:
//   GET  /                 -> nexus.html (token injected as <meta>)
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
class Graph {
  final Map<String, Map<String, dynamic>> nodes = {};
  final Set<String> edgeKeys = {};
  final List<Map<String, dynamic>> edges = [];

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
    for (final e in es) {
      final src = (e['source'] is Map) ? e['source']['id'] : e['source'];
      final tgt = (e['target'] is Map) ? e['target']['id'] : e['target'];
      final s = src?.toString() ?? '';
      final t = tgt?.toString() ?? '';
      final k = (e['kind'] ?? '').toString();
      final key = '$s=>$t:$k';
      if (s.isEmpty || t.isEmpty) continue;
      if (edgeKeys.add(key)) edges.add({
        'source': s,
        'target': t,
        if (k.isNotEmpty) 'kind': k,
        if (e['certainty'] != null) 'certainty': e['certainty'],
      });
    }
  }

  Map<String, dynamic> toJson() => {
        'nodes': nodes.values.toList(),
        'edges': edges,
      };
}

// ----------------------------
// Config: known crawler exe names
// (edit or extend as you add languages)
// ----------------------------
final Map<String, List<String>> _crawlerCandidates = {
  'js':      ['jsDependency', 'jsDependency.exe'],
  'py':      ['pyDependency', 'pyDependency.exe'],
  'go':      ['goDependency', 'goDependency.exe'],
  'rust':    ['rustDependency', 'rustDependency.exe'],
  'java':    ['javaDependency', 'javaDependency.exe'],
  'kotlin':  ['kotlinDependency', 'kotlinDependency.exe'],
  'csharp':  ['csharpDependency', 'csharpDependency.exe'],
  'dart':    ['dartDependency', 'dartDependency.exe'],
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

  // static: "/" -> nexus.html (with token injected)
  if (method == 'GET' && (path == '/' || path == '/index.html' || path == '/nexus.html')) {
    final html = await _loadViewerHtml();
    final injected = _injectTokenIntoHtml(html, _token);
    req.response.headers.contentType = ContentType.html;
    req.response.write(injected);
    await req.response.close();
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
      final outFile = File(_join(root, _defaultOutput[lang] ?? '${lang}Dependencies.json'));
      if (await outFile.exists()) {
        try {
          final data = jsonDecode(await outFile.readAsString()) as Map<String, dynamic>;
          collected.add(data);
        } catch (e) {
          _warn('Failed to parse ${outFile.path}: $e');
        }
      } else {
        _warn('Expected output not found for "$lang": ${outFile.path}');
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
  // Try ./nexus.html relative to working dir
  final local = File('nexus.html');
  if (await local.exists()) return await local.readAsString();

  // Try alongside the executable
  final exe = File(Platform.resolvedExecutable);
  final exeDir = exe.parent.path;
  final sibling = File(_join(exeDir, 'nexus.html'));
  if (await sibling.exists()) return await sibling.readAsString();

  // Fallback: minimal inline page that asks user to load data or crawl
  return _fallbackHtml;
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
  // 1) current directory
  for (final n in names) {
    final f = File(n);
    if (await f.exists()) return f.absolute.path;
  }
  // 2) alongside exe
  final binDir = File(Platform.resolvedExecutable).parent.path;
  for (final n in names) {
    final f = File(_join(binDir, n));
    if (await f.exists()) return f.path;
  }
  // 3) PATH
  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    if (dir.trim().isEmpty) continue;
    for (final n in names) {
      final p = _join(dir, n);
      if (await File(p).exists()) return p;
    }
  }
  return null;
}

Future<int> _runCrawler(String exe, String root) async {
  _log('Running: $exe  (cwd: $root)');
  final p = await Process.start(exe, const <String>[], // crawlers scan CWD; no flags needed
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
// Minimal fallback HTML (only used if nexus.html not found)
// ----------------------------
const String _fallbackHtml = r'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Nurox Viewer</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:2rem;background:#0b0d12;color:#e8ecf1}
button,input,select{font:inherit} .row{display:flex;gap:.5rem;align-items:center;margin:.5rem 0}
pre{background:#0f1320;border:1px solid rgba(255,255,255,.08);padding:1rem;border-radius:8px;max-height:40vh;overflow:auto}
</style>
</head><body>
<h1>Nurox Viewer</h1>
<p>This is a lightweight fallback page (couldn't find <code>nexus.html</code>). You can still crawl and view raw JSON:</p>
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

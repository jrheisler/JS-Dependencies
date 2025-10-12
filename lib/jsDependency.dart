// jsDependency.dart (no-args default; fixed output: jsDependencies.json)
//
// Run with no args:
//   dart run jsDependency.dart
// or compiled:
//   .\jsDependency.exe
//
// Behavior:
// - Looks for an input graph in the current directory, in this order:
//     1) graph.json
//     2) graph.source.json
//     3) deps.json
// - If found, normalizes & enriches it and writes jsDependencies.json
// - If none found, writes a tiny demo graph to jsDependencies.json
//
// Optional (still supported if you ever need it):
//   --in <file>    explicitly set input
//   --out <file>   explicitly set output (default: jsDependencies.json)
//   --strict       fail if edges reference missing nodes
//   --no-synth     do NOT synthesize missing node endpoints

import 'dart:convert';
import 'dart:io';

const defaultOutput = 'jsDependencies.json';
const candidateInputs = ['graph.json', 'graph.source.json', 'deps.json'];

void main(List<String> args) async {
  String? inPath;
  String outPath = defaultOutput;
  bool strict = false;
  bool synthesizeMissing = true;

  // Optional flags (won't be needed for your workflow, but handy to keep)
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--in' && i + 1 < args.length) {
      inPath = args[++i];
    } else if (a == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else if (a == '--strict') {
      strict = true;
    } else if (a == '--no-synth') {
      synthesizeMissing = false;
    } else {
      stderr.writeln('[warn] Unknown arg ignored: $a');
    }
  }

  // Discover input if not provided
  if (inPath == null) {
    inPath = await _findFirstExisting(candidateInputs);
    if (inPath != null) {
      stderr.writeln('[info] Using input: $inPath');
    } else {
      stderr.writeln('[warn] No input graph found; writing demo graph → $outPath');
      final demo = _demoGraph();
      await _writeGraph(demo, outPath);
      _printStats(demo);
      return;
    }
  }

  // Load + normalize
  final file = File(inPath!);
  if (!await file.exists()) {
    stderr.writeln('[error] Input not found: $inPath');
    exit(66); // EX_NOINPUT
  }

  late dynamic raw;
  try {
    raw = jsonDecode(await file.readAsString());
  } catch (e) {
    stderr.writeln('[error] Failed to parse JSON: $e');
    exit(65); // EX_DATAERR
  }

  final graph = _normalizeGraph(raw);

  if (synthesizeMissing) _synthesizeMissingNodes(graph);
  _computeDegrees(graph);

  final issues = _validateGraph(graph);
  if (issues.isNotEmpty) {
    if (strict) {
      stderr.writeln('[error] Validation failed (--strict):');
      for (final i in issues) { stderr.writeln('  - $i'); }
      exit(65);
    } else {
      stderr.writeln('[warn] Validation issues:');
      for (final i in issues) { stderr.writeln('  - $i'); }
    }
  }

  await _writeGraph(graph, outPath);
  stderr.writeln('[info] Wrote: $outPath');
  _printStats(graph);
}

// ---------- Model ----------
class Graph {
  final Map<String, Node> nodeById;
  final List<Edge> edges;
  Graph(this.nodeById, this.edges);
  List<Node> get nodes => nodeById.values.toList(growable: false);
}

class Node {
  String id;
  String? type;
  String? state;
  int? sizeLOC;
  String? packageName; // json key: "package"
  bool? hasSideEffects;
  int inDeg = 0;
  int outDeg = 0;

  Node({
    required this.id,
    this.type,
    this.state,
    this.sizeLOC,
    this.packageName,
    this.hasSideEffects,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        if (type != null) 'type': type,
        if (state != null) 'state': state,
        if (sizeLOC != null) 'sizeLOC': sizeLOC,
        if (packageName != null) 'package': packageName,
        if (hasSideEffects != null) 'hasSideEffects': hasSideEffects,
        'inDeg': inDeg,
        'outDeg': outDeg,
      };
}

class Edge {
  String source;
  String target;
  String? kind;
  String? certainty;
  String? id;

  Edge({required this.source, required this.target, this.kind, this.certainty, this.id});

  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        if (kind != null) 'kind': kind,
        if (certainty != null) 'certainty': certainty,
        if (id != null) 'id': id,
      };
}

// ---------- Core ----------
Graph _normalizeGraph(dynamic raw) {
  if (raw is! Map) {
    throw FormatException('Root JSON must be an object with nodes/edges');
  }
  final nodesRaw = raw['nodes'];
  final edgesRaw = raw['edges'] ?? raw['links'];
  if (nodesRaw is! List) throw FormatException('"nodes" must be an array');
  if (edgesRaw is! List) throw FormatException('"edges" (or "links") must be an array');

  final nodeById = <String, Node>{};
  for (final n in nodesRaw) {
    if (n is! Map) continue;
    final id = _asString(n['id']);
    if (id == null || id.trim().isEmpty) {
      stderr.writeln('[warn] Skipping node without valid "id": $n');
      continue;
    }
    nodeById[id] = Node(
      id: id,
      type: _asString(n['type']),
      state: _asString(n['state']),
      sizeLOC: _asInt(n['sizeLOC']),
      packageName: _asString(n['package']),
      hasSideEffects: _asBool(n['hasSideEffects']),
    );
  }

  final edges = <Edge>[];
  for (final e in edgesRaw) {
    if (e is! Map) continue;
    final src = _asString(e['source']);
    final tgt = _asString(e['target']);
    if (src == null || tgt == null) {
      stderr.writeln('[warn] Skipping edge without source/target: $e');
      continue;
    }
    edges.add(Edge(
      source: src,
      target: tgt,
      kind: _asString(e['kind']),
      certainty: _asString(e['certainty']),
      id: _asString(e['id']),
    ));
  }

  return Graph(nodeById, edges);
}

void _synthesizeMissingNodes(Graph g) {
  for (final e in g.edges) {
    if (!g.nodeById.containsKey(e.source)) {
      g.nodeById[e.source] = Node(
        id: e.source,
        type: e.source.contains('node_modules') ? 'external' : 'file',
        state: 'used',
      );
    }
    if (!g.nodeById.containsKey(e.target)) {
      g.nodeById[e.target] = Node(
        id: e.target,
        type: e.target.contains('node_modules') ? 'external' : 'file',
        state: 'used',
      );
    }
  }
}

void _computeDegrees(Graph g) {
  for (final n in g.nodes) {
    n.inDeg = 0; n.outDeg = 0;
  }
  for (final e in g.edges) {
    final s = g.nodeById[e.source];
    final t = g.nodeById[e.target];
    if (s != null) s.outDeg++;
    if (t != null) t.inDeg++;
  }
}

List<String> _validateGraph(Graph g) {
  final issues = <String>[];
  for (final e in g.edges) {
    if (!g.nodeById.containsKey(e.source)) issues.add('Edge source not found as node: ${e.source}');
    if (!g.nodeById.containsKey(e.target)) issues.add('Edge target not found as node: ${e.target}');
  }
  return issues;
}

Future<void> _writeGraph(Graph g, String outPath) async {
  final enriched = {
    'nodes': g.nodes.map((n) => n.toJson()).toList(),
    'edges': g.edges.map((e) => e.toJson()).toList(),
  };
  final outJson = const JsonEncoder.withIndent('  ').convert(enriched);
  await File(outPath).writeAsString(outJson);
}

Graph _demoGraph() {
  final g = Graph({}, [
    Edge(source: 'src/main.ts', target: 'src/util/math.ts', kind: 'import', certainty: 'static'),
    Edge(source: 'src/main.ts', target: 'src/components/Chart.tsx', kind: 'import', certainty: 'static'),
    Edge(source: 'src/components/Chart.tsx', target: 'node_modules/react/index.js', kind: 'import', certainty: 'static'),
  ]);
  g.nodeById['src/main.ts'] = Node(id: 'src/main.ts', type: 'file', state: 'used', sizeLOC: 120);
  g.nodeById['src/util/math.ts'] = Node(id: 'src/util/math.ts', type: 'file', state: 'used', sizeLOC: 60);
  g.nodeById['src/components/Chart.tsx'] = Node(id: 'src/components/Chart.tsx', type: 'file', state: 'used', sizeLOC: 200);
  g.nodeById['src/legacy/oldHelper.js'] = Node(id: 'src/legacy/oldHelper.js', type: 'file', state: 'unused', sizeLOC: 40);
  g.nodeById['node_modules/react/index.js'] = Node(id: 'node_modules/react/index.js', type: 'external', state: 'used');
  _computeDegrees(g);
  return g;
}

// ---------- utils ----------
Future<String?> _findFirstExisting(List<String> names) async {
  for (final n in names) {
    if (await File(n).exists()) return n;
  }
  return null;
}

String? _asString(dynamic v) => v == null ? null : (v is String ? v : v.toString());
int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
bool? _asBool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  final s = v.toString().toLowerCase();
  if (s == 'true') return true;
  if (s == 'false') return false;
  return null;
}

void _printStats(Graph g) {
  final total = g.nodes.length;
  final externals = g.nodes.where((n) => n.type == 'external' || (n.packageName ?? '').isNotEmpty).length;
  final unused = g.nodes.where((n) => (n.state == 'unused') || (n.inDeg + n.outDeg == 0)).length;
  final maxDeg = g.nodes.fold<int>(0, (m, n) => (n.inDeg + n.outDeg) > m ? (n.inDeg + n.outDeg) : m);
  stderr.writeln('[stats] nodes=$total edges=${g.edges.length} externals=$externals unused≈$unused maxDeg=$maxDeg');
  final hubs = g.nodes.toList()..sort((a,b)=> (b.inDeg+b.outDeg) - (a.inDeg+a.outDeg));
  stderr.writeln('[hubs]');
  for (final n in hubs.take(5)) {
    stderr.writeln('  - ${n.id} (deg=${n.inDeg + n.outDeg})');
  }
}

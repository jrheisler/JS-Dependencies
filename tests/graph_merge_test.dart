import '../lib/nurox_view.dart';

void main() {
  final graph = Graph();
  graph.addGraph({
    'nodes': [
      {
        'id': 'C:/repo/src/a.js',
        'type': 'file',
        'state': 'used',
        'absPath': 'C:/repo/src/a.js',
      }
    ],
    'edges': const [],
    'securityFindings': {
      'C:/repo/src/a.js': [
        {
          'id': 'rule.eval',
          'message': 'Use of eval()',
          'severity': 'high',
          'line': 12,
        }
      ]
    }
  });

  graph.addGraph({
    'nodes': [
      {
        'id': r'C:\\repo\\src\\a.js',
        'type': 'file',
        'state': 'used',
        'absPath': r'C:\\repo\\src\\a.js',
      }
    ],
    'edges': const [],
    'securityFindings': {
      r'C:\\repo\\src\\a.js': [
        {
          'id': 'rule.exec',
          'message': 'child_process exec',
          'severity': 'high',
          'line': 30,
        }
      ]
    }
  });

  final merged = graph.toJson();
  final security = merged['securityFindings'] as Map<String, dynamic>?;
  assert(security != null && security!.isNotEmpty, 'security findings should be preserved');

  final key = 'C:/repo/src/a.js';
  final findings = security![key] as List<dynamic>?;
  assert(findings != null && findings!.length == 2, 'both findings should merge on canonical path');

  final ids = findings!.map((item) => (item as Map<String, dynamic>)['id']).toSet();
  assert(ids.contains('rule.eval') && ids.contains('rule.exec'));
}

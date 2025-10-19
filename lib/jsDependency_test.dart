import 'jsDependency.dart';

void main() {
  const sample = '''
  const url = "http://attack.test";
  setTimeout("doBadThings()", 1000);
  ''';

  final findings = collectSecurityFindingsForTest('/tmp/insecure.js', sample);

  assert(findings.any((f) => f.id == 'http.cleartext'));
  assert(findings.any((f) => f.id == 'timeout.string'));

  print('Security finding test passed with ${findings.length} findings.');
}

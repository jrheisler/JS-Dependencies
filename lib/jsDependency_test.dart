import 'jsDependency.dart';

void main() {
  const sample = '''
  const url = "http://attack.test";
  setTimeout("doBadThings()", 1000);
  ''';

  final findings = collectSecurityFindingsForTest('/tmp/insecure.js', sample);

  assert(findings.any((f) => f.id == 'http.cleartext'));
  assert(findings.any((f) => f.id == 'timeout.string'));

  const complexSample = '''
  require("child_process").exec("ls");
  require("child_process").exec("echo hi", { shell: true });
  const key = process.env.SECRET_KEY;
  require("fs").readFileSync("/etc/hosts", "utf8");
  localStorage.setItem("authToken", "abc123");
  require("jsonwebtoken").verify("token", "secret");
  document.cookie = "sid=abc123; path=/";
  const API_KEY = "sk_live_1234567890abcdef";
  ''';

  final complexFindings = collectSecurityFindingsForTest('/tmp/complex.js', complexSample);

  bool has(String id) => complexFindings.any((f) => f.id == id);

  assert(has('child_process.exec'));
  assert(has('child_process.shell'));
  assert(has('process.env'));
  assert(has('fs.access'));
  assert(has('storage.token'));
  assert(has('jwt.verify'));
  assert(has('cookie.literal'));
  assert(has('secret.literal'));

  print('Security finding test passed with ${findings.length + complexFindings.length} findings.');
}

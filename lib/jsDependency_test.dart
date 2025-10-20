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
  jwt.verify(token, secret, { algorithms: ['HS256', 'none'] });
  jsonwebtoken.verify(token, secret, { audience: 'app' });
  document.cookie = "sid=abc123; SameSite=None";
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
  assert(has('jwt.verify.algorithms.none'));
  assert(has('jwt.verify.missingAud'));
  assert(has('jwt.verify.missingIss'));
  assert(has('jwt.verify.missingExp'));
  assert(has('jwt.verify.missingNbf'));
  assert(has('cookie.sameSiteNoneInsecure'));
  assert(has('cookie.session.noHttpOnly'));

  const securitySample = '''
  const target = req.query.url;
  fetch(target);
  axios.get(req.body.url);
  https.request({ host: req.params.host });
  window.location = req.query.redirect;
  res.redirect(req.body.next);
  fetch('/api/update', { method: 'POST', credentials: 'include' });
  axios.post('/api', data, { withCredentials: true });
  const xhr = new XMLHttpRequest();
  xhr.withCredentials = true;
  xhr.open('POST', '/submit');
  xhr.send('payload');
  res.set({ 'Strict-Transport-Security': 'max-age=63072000' });
  yaml.load(source);
  const parser = new xml2js.Parser({ resolveEntities: true });
  crypto.createCipheriv('aes-256-gcm', key, 'static-iv-value');
  crypto.createCipher('aes-128-ecb', key);
  client.query(`SELECT * FROM users WHERE id = ${userId}`);
  db.query('SELECT ' + req.body.filter);
  db.collection('users').find({ $where: req.body.whereClause });
  const pattern = new RegExp(inputPattern);
  const merged = _.merge({}, req.body);
  const assigned = Object.assign({}, req.query);
  const safePath = path.join(req.body.path, 'file.txt');
  entry.path = '../escape.sh';
  const dangerous = /^(a+)+$/;
  const template = Handlebars.compile('{{{unsafe}}}');
  const agent = new https.Agent({ rejectUnauthorized: false });
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = 0;
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Credentials', 'true');
  fetch('http://169.254.169.254/latest/meta-data/');
  ''';

  final securityFindings = collectSecurityFindingsForTest('/tmp/security.js', securitySample);

  bool secHas(String id) => securityFindings.any((f) => f.id == id);

  assert(secHas('ssrf.dynamicFetch'));
  assert(secHas('ssrf.dynamicAxios'));
  assert(secHas('ssrf.dynamicRequest'));
  assert(secHas('injection.sqlTemplate'));
  assert(secHas('injection.sqlConcat'));
  assert(secHas('injection.mongoOperator'));
  assert(secHas('regex.dynamic'));
  assert(secHas('regex.catastrophic'));
  assert(secHas('prototype.mergeUserInput'));
  assert(secHas('prototype.assignUserInput'));
  assert(secHas('path.join.userInput'));
  assert(secHas('zipSlip.entryPath'));
  assert(secHas('template.tripleStache'));
  assert(secHas('tls.agentInsecure'));
  assert(secHas('tls.disabledEnv'));
  assert(secHas('cors.credentialsWildcard'));
  assert(secHas('ssrf.metadataHost'));
  assert(secHas('open_redirect.clientLocation'));
  assert(secHas('open_redirect.serverRedirect'));
  assert(secHas('csrf.credentialsMissingToken'));
  assert(secHas('headers.securityBaseline'));
  assert(secHas('yaml.load.unsafe'));
  assert(secHas('xml.externalEntities'));
  assert(secHas('crypto.staticIv'));
  assert(secHas('crypto.aesEcb'));

  final totalFindings =
      findings.length + complexFindings.length + securityFindings.length;
  print('Security finding test passed with $totalFindings findings.');
}

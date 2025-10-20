# JavaScript security scans

The `jsDependency.dart` crawler includes a lightweight static security scan when it
parses JavaScript and TypeScript sources. The scanner performs a regular
expression sweep over each file (after stripping comments and string contents)
plus a small number of bespoke heuristics. Each match is emitted as a
`SecurityFinding` and exported under the `securityFindings` section of
`jsDependencies.json`.

## Rule reference

The table below lists every built-in rule. The **Pattern** column sketches the
string or regular expression that must be present (after sanitization) for the
finding to trigger.

| ID | Severity | Description | Pattern / trigger |
| --- | --- | --- | --- |
| `eval.call` | high | Use of `eval()` which can execute arbitrary code. | `\beval\s*\(` |
| `function.constructor` | high | Construction of dynamic functions via `new Function()`. | `new\s+Function\s*\(` |
| `timeout.string` | high | Passing a string to `setTimeout`/`setInterval`, which executes it as code. | `set(?:Timeout|Interval)\s*\(\s*["']` |
| `vm.module` | high | Calls into Node's `vm` module that can escape sandboxes. | `\bvm\.[A-Za-z_]\w*\s*\(` |
| `child_process.exec` | high | Running `child_process` exec/spawn helpers which launch shell commands. | `child_process\.(exec|execSync|spawn|spawnSync)` or requiring `child_process` followed by those calls |
| `child_process.shell` | high | Enabling shell mode via `{ shell: true }` on process spawns. | `shell\s*:\s*true` |
| `dynamic.require` | high | `require()` with a non-literal argument (dynamic module loading). | `require\s*\(\s*[^\'"\s][^\)]*\)` |
| `dynamic.import` | high | `import()` with a non-literal argument. | `import\s*\(\s*[^\'"\s][^\)]*\)` |
| `import.template` | high | Module specifier expressed as a template literal. | `from` followed by a backtick-delimited template literal |
| `node.builtin` | med | Sensitive Node built-ins imported (fs/net/tls/http/https/dgram/cluster/os). | `(?:require|import)\s*\(\s*["'](?:fs|net|tls|http|https|dgram|cluster|os)` |
| `process.env` | med | Access to `process.env`, potentially leaking secrets. | `process\.env` |
| `fs.access` | med | Reading or writing via Node's `fs` module. | `fs\.(readFile|writeFile|readdir|create(Read|Write)Stream)` or requiring `fs` then calling those APIs |
| `http.cleartext` | med | Cleartext HTTP requests to non-localhost targets. | `http://` (excluding localhost/127.0.0.1) |
| `dom.innerHTML` | high | Assignments to `innerHTML`. | `\.\s*innerHTML\s*=` |
| `dom.outerHTML` | high | Assignments to `outerHTML`. | `\.\s*outerHTML\s*=` |
| `document.write` | high | Calls to `document.write()`. | `document\.write\s*\(` |
| `dom.insertAdjacentHTML` | high | Calls to `insertAdjacentHTML()`. | `insertAdjacentHTML\s*\(` |
| `dom.range` | high | Calls to `Range.createContextualFragment()`. | `createContextualFragment\s*\(` |
| `react.dangerousHTML` | high | Usage of React's `dangerouslySetInnerHTML`. | `dangerouslySetInnerHTML\s*:` |
| `iframe.srcdoc` | high | Assigning to the `srcdoc` attribute. | `\bsrcdoc\s*=` |
| `template.interpolation` | low | Template literal interpolation that may need sanitization. | Any template string containing `${ ... }` |
| `postmessage.wildcard` | med | `window.postMessage` calls targeting the wildcard origin. | `postMessage\s*\([^,]+,\s*["']\*["']\)` |
| `secret.literal` | high | Potential hard-coded secrets (API keys, tokens, passwords). | `(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\s*[:=]\s*["'][A-Za-z0-9_\-\.=+/]{12,}["']` |
| `math.random` | low | Usage of `Math.random()` where cryptographic randomness may be required. | `Math\.random\s*\(` |
| `storage.token` | med | Writing tokens into `localStorage`/`sessionStorage`. | `localStorage.setItem(...)` or `sessionStorage.setItem(...)` with token/auth/jwt/session keys |
| `crypto.weakHash` | med | Hashing with MD5/SHA1. | `crypto\.createHash\(\s*["'](?:md5|sha1)["']` |
| `crypto.createCipher` | med | Deprecated `crypto.createCipher`/`createDecipher` usage. | `crypto\.create(?:Cipher|Decipher)\s*\(` |
| `jwt.verify` | med | `jwt.verify` invoked without explicit options. | `jsonwebtoken\s*\.\s*verify(` or `jwt.verify(` with only token & secret arguments |
| `cors.wildcard` | med | Wildcard `Access-Control-Allow-Origin` headers. | `Access-Control-Allow-Origin\s*[:=]\s*["']\*["']` |
| `cors.middleware` | med | Express `app.use(cors())` without configuration. | `app\.use\s*\(\s*cors\s*\(\s*\)` |
| `cookie.literal` | low | Cookie strings defined inline; security flags should be reviewed. | `document\.cookie\s*=\s*["'][^"']*["']` or `cookie\s*:\s*["'][^"']*["']` |
| `console.secret` | low | Logging values that look like secrets. | `console\.(log|dir)\([^)]*(password|secret|token)[^)]*\)` |
| `import.meta.env` | low | Direct reads from `import.meta.env`. | `import\.meta\.env\.[A-Za-z_]\w*` |
| `fs.dotdot` | med | References to `fs.` APIs combined with `..`, signaling possible directory traversal. | Any line containing both `fs.` and `..` |
| `ssrf.dynamicFetch` | high | `fetch()` invoked with user-controlled data (for example `req.query`). | `fetch(...)` with arguments referencing request/body/query data |
| `ssrf.dynamicAxios` | high | `axios` requests built from tainted input. | `axios.*(...)` where arguments include request/body/query data |
| `ssrf.dynamicRequest` | high | `http(s).request()` using user-controlled hosts. | `http.request(...)` / `https.request(...)` with request/body/query driven host values |
| `ssrf.metadataHost` | high | Requests to metadata or private-network IP ranges. | URLs targeting `169.254.169.254`, `10.x.x.x`, `172.16-31.x.x`, or `192.168.x.x` |
| `injection.sqlTemplate` | high | SQL queries composed with template literal interpolation. | `.query` template literal containing `${...}` |
| `injection.sqlConcat` | high | SQL queries built via string concatenation of tainted data. | `.query('...' + req.body.foo)` |
| `injection.mongoOperator` | high | Usage of MongoDB `$where`/`$regex` operators which may execute user input. | `$where:` or `$regex:` |
| `regex.dynamic` | med | `RegExp` constructed from dynamic (non-literal) input. | `new RegExp(variable)` or `RegExp(variable)` |
| `regex.catastrophic` | high | Regex literal with nested quantifiers that can trigger ReDoS. | Patterns such as `/(a+)+/` |
| `prototype.mergeUserInput` | high | `_.merge` merging user data into objects. | `_.merge({}, req.body)` |
| `prototype.assignUserInput` | high | `Object.assign` merging user data into plain objects. | `Object.assign({}, req.body)` |
| `prototype.proto` | high | Direct assignment to `__proto__` or `constructor.prototype`. | `object.__proto__ = ...` |
| `path.join.userInput` | high | `path.join` invoked with user-controlled path segments. | `path.join(req.body.path, ...)` |
| `zipSlip.entryPath` | high | Archive entry paths containing `..` (Zip-Slip). | `entry.path = '../...'` or similar |
| `cors.credentialsWildcard` | high | Wildcard CORS origin combined with credential support. | `Access-Control-Allow-Origin: *` plus `Access-Control-Allow-Credentials: true` |
| `tls.disabledEnv` | high | TLS verification disabled via environment variable. | `NODE_TLS_REJECT_UNAUTHORIZED=0` |
| `tls.agentInsecure` | high | TLS verification disabled on `https.Agent`. | `new https.Agent({ rejectUnauthorized: false })` |
| `template.tripleStache` | med | Unescaped Handlebars/Mustache triple-stache rendering. | `{{{...}}}` |
| `template.escapeDisabled` | med | Template rendering with escaping disabled. | `escape: false` |
| `jwt.verify.missingOptions` | high | `jwt.verify` missing a populated options object. | `jwt.verify(token, secret, null)` / `{}` |
| `jwt.verify.algorithms.missing` | high | Missing `algorithms` whitelist on JWT verification. | Options object without `algorithms:` |
| `jwt.verify.algorithms.none` | high | `algorithms` array includes `none`. | `algorithms: ['HS256', 'none']` |
| `jwt.verify.missingAud` | med | JWT verification lacking audience validation. | Options object without `audience`/`aud` |
| `jwt.verify.missingIss` | med | JWT verification lacking issuer validation. | Options object without `issuer`/`iss` |
| `jwt.verify.missingExp` | med | Expiration not enforced or `ignoreExpiration:true`. | Missing `maxAge`/`expiresIn` or `ignoreExpiration:true` |
| `jwt.verify.missingNbf` | med | Not-before claim left unchecked. | Missing `nbf`/`notBefore` or `ignoreNotBefore:true` |
| `cookie.sameSiteNoneInsecure` | high | `SameSite=None` cookie missing the `Secure` flag. | Cookie strings/options with `SameSite=None` but no `secure` |
| `cookie.session.noHttpOnly` | med | Session cookies lacking `HttpOnly`. | `session`/`sid` cookies without `httpOnly` |
| `crypto.aesEcb` | high | AES ECB mode selected. | `aes-128-ecb`, `AES_ECB` |
| `crypto.staticIv` | high | Static IV/nonce passed to encryption APIs. | `createCipheriv(..., 'static')`, `crypto.subtle` algorithm with literal `iv` |
| `open_redirect.clientLocation` | high | Client-side navigation built from user input. | `window.location = req.query...` |
| `open_redirect.serverRedirect` | high | Express `res.redirect` fed by user input. | `res.redirect(req.query.returnTo)` |
| `headers.securityBaseline` | med | Other security headers set without CSP/X-Frame-Options/Referrer-Policy. | `res.set({ 'Strict-Transport-Security': ... })` lacking CSP/frame/referrer |
| `yaml.load.unsafe` | high | `js-yaml` `load()` without a safe schema. | `yaml.load(src)` missing `schema: DEFAULT_SAFE_SCHEMA` |
| `xml.externalEntities` | high | XML parser enabling external entities. | `{ resolveEntities: true }`, `{ externalEntities: true }` |
| `csrf.credentialsMissingToken` | high | Credentialed requests lacking CSRF tokens. | `fetch(... { credentials: 'include', method: 'POST' })` without CSRF headers |

### Notes

* Sanitization removes comments and quoted strings before evaluating the regular
  expressions, helping reduce false positives from commented code or string
  literals. Some rules (such as `fs.dotdot`) run on the raw line to catch
  directory traversal attempts.
* Findings include the rule identifier, severity, message, source line, and a
  snippet of the triggering code so downstream tooling can present actionable
  context.
* The scanner is heuristic-driven and may produce false positives/negatives; it
  is intended for surfacing potential risks rather than enforcing strict policy.


import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const LIMIT = 65536;
const LIFE = 300000;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const INVENTORY = Object.freeze([
  'core/omp/model_modes.py', 'core/scripts/canonical_occupancy.py',
  'core/scripts/cross_harness_surface_diff.py', 'core/scripts/harness_compile.py',
  'core/scripts/launcher_runtime_snapshot.py', 'core/scripts/omp_canonical_update.ts',
  'core/scripts/omp_canonical_update_lock.py',
]);
const NATIVE = Object.freeze({ version: '18.11.3', source_revision: '96894a6147d8cc64b7e00ad3a7d7178fd93b9531', sha256: 'd518310d647d467a2c5c3f2d38e34489a761996d766395c03b37c61a2203d02b', bytes: 194982944 });
const fail = code => { throw new Error(code); };
const need = (value, code = 'source_admission_failed') => { if (!value) fail(code); };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
function keys(value, expected) {
  need(value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === [...expected].sort().join(','));
}
function text(value) { return typeof value === 'string' && value.length > 0 && value.length <= 4096 && !/[\p{Cc}\p{Cf}\p{Cs}]/u.test(value); }
function relative(value) { return text(value) && !path.isAbsolute(value) && value.split('/').every(p => p && p !== '.' && p !== '..'); }
function physical(value) { need(text(value) && path.isAbsolute(value) && path.normalize(value) === value && fs.realpathSync(value) === value); }
export function identity(info) {
  // Darwin ino_t is uint64; Bun can expose its high bit as a signed bigint.
  return Object.fromEntries(['dev', 'ino', 'uid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(k => [k, String(k === 'ino' ? BigInt.asUintN(64, info[k]) : info[k])]).concat([['mode', String(info.mode & 0o7777n)]]));
}
function identityRecord(value) {
  keys(value, ['dev', 'ino', 'uid', 'mode', 'nlink', 'size', 'mtime_ns', 'ctime_ns']);
  need(Object.values(value).every(v => typeof v === 'string' && /^(0|[1-9][0-9]*)$/.test(v)));
}
function ancestry(file, home) {
  physical(file);
  let current = file;
  for (;;) {
    const st = fs.lstatSync(current);
    need(!st.isSymbolicLink() && (st.uid === process.getuid() || st.uid === 0) && !(st.mode & 0o022));
    if (current === home) need(st.uid === process.getuid());
    if (current === '/') break;
    current = path.dirname(current);
  }
}

// Retained descriptors and sealed inventories are checked, not rehashed and adopted.
export function admitTree(root, entries, manifestBytes, home) {
  const retained = [];
  const directories = new Map();
  const expected = new Set([...Object.keys(entries), 'manifest.json']);
  const close = () => { for (const row of retained) fs.closeSync(row.fd); retained.length = 0; };
  try {
    ancestry(root, home);
    function walk(directory) {
      const st = fs.lstatSync(directory, { bigint: true });
      need(st.isDirectory() && st.uid === BigInt(process.getuid()) && (st.mode & 0o7777n) === 0o500n);
      const names = fs.readdirSync(directory).sort();
      directories.set(directory, names);
      const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      retained.push({ file: directory, fd, stamp: canonical(identity(st)) });
      for (const name of names) {
        const file = path.join(directory, name);
        const info = fs.lstatSync(file, { bigint: true });
        if (info.isDirectory()) {
          need([...Object.keys(entries)].some(p => p.startsWith(path.relative(root, file) + '/')));
          walk(file); continue;
        }
        const rel = path.relative(root, file);
        need(expected.delete(rel) && info.isFile() && info.uid === BigInt(process.getuid()) && info.nlink === 1n);
        const row = rel === 'manifest.json' ? { mode: 0o400, sha256: hash(manifestBytes), bytes: manifestBytes.length } : entries[rel];
        need((info.mode & 0o7777n) === BigInt(row.mode));
        const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        retained.push({ file, fd, stamp: canonical(identity(info)) });
        need(canonical(identity(fs.fstatSync(fd, { bigint: true }))) === canonical(identity(info)));
        const bytes = fs.readFileSync(fd);
        need(hash(bytes) === row.sha256 && (row.bytes === undefined || bytes.length === row.bytes));
      }
    }
    walk(root);
    need(expected.size === 0);
    const check = () => {
      for (const row of retained) {
        need(canonical(identity(fs.fstatSync(row.fd, { bigint: true }))) === row.stamp && canonical(identity(fs.lstatSync(row.file, { bigint: true }))) === row.stamp, 'source_changed');
      }
      for (const [directory, names] of directories) need(canonical(fs.readdirSync(directory).sort()) === canonical(names), 'source_changed');
    };
    check();
    return { check, close };
  } catch (error) { close(); throw error; }
}
function readJson(file, max = 131072) {
  const st = fs.lstatSync(file);
  need(st.isFile() && !st.isSymbolicLink() && st.size <= max);
  const bytes = fs.readFileSync(file);
  const value = JSON.parse(bytes.toString('utf8'));
  // Security records are canonical: duplicates and alternative encodings cannot survive.
  need(bytes.toString('utf8') === canonical(value) || bytes.toString('utf8') === canonical(value) + '\n');
  return { bytes, value };
}
export function validatePin(pin) {
  keys(pin, ['schema', 'revision', 'manifest_sha256', 'files', 'native']);
  need(pin.schema === 'launcher-canonical-bootstrap/v1' && HEX40.test(pin.revision) && HEX64.test(pin.manifest_sha256));
  need(canonical(pin.native) === canonical(NATIVE) && Array.isArray(pin.files) && pin.files.length === INVENTORY.length);
  for (let i = 0; i < INVENTORY.length; i++) {
    const row = pin.files[i];
    keys(row, ['path', 'git_mode', 'bytes', 'sha256']);
    need(row.path === INVENTORY[i] && row.git_mode === '100644' && Number.isSafeInteger(row.bytes) && row.bytes > 0 && row.bytes <= 8 * 1024 * 1024 && HEX64.test(row.sha256));
  }
  need(hash(canonical({ schema: 'canonical-bootstrap-source/v1', files: pin.files }) + '\n') === pin.manifest_sha256);
}
// Bun userInfo().homedir follows HOME; that fresh auth home is not account authority.
export function accountHome() {
  need(process.platform === 'darwin');
  let result;
  try {
    result = spawnSync('/usr/bin/python3', ['-I', '-S', '-B', '-c',
      'import json,os,pwd,sys; u=os.getuid(); sys.stdout.buffer.write(json.dumps({"home":pwd.getpwuid(u).pw_dir,"uid":u},ensure_ascii=False,sort_keys=True,separators=(",",":")).encode("utf-8"))'],
    { shell: false, cwd: '/', env: { PATH: '/usr/bin:/bin' }, stdio: ['ignore', 'pipe', 'ignore'], timeout: 15000, killSignal: 'SIGKILL', maxBuffer: 4096 });
  } catch { fail('source_admission_failed'); }
  need(result && !result.error && result.signal === null && result.status === 0
    && Buffer.isBuffer(result.stdout) && result.stdout.length > 0 && result.stdout.length <= 4096);
  let value;
  try { value = JSON.parse(result.stdout.toString('utf8')); } catch { fail('source_admission_failed'); }
  keys(value, ['home', 'uid']);
  need(text(value.home) && Number.isSafeInteger(value.uid) && value.uid === process.getuid()
    && Buffer.from(canonical(value), 'utf8').equals(result.stdout));
  ancestry(value.home, value.home);
  return value.home;
}
function admitOwnSource() {
  const home = accountHome();
  const own = fileURLToPath(import.meta.url);
  physical(own);
  const root = path.dirname(path.dirname(own));
  const base = path.join(home, '.local/state/kilhyeonjun-harness/launcher-runtimes');
  need(path.dirname(root) === base && HEX40.test(path.basename(root)));
  const release = readJson(path.join(root, 'manifest.json'));
  keys(release.value, ['version', 'revision', 'files']);
  need(release.value.revision === path.basename(root) && /^\d+\.\d+\.\d+$/.test(release.value.version));
  const entries = release.value.files;
  need(entries && typeof entries === 'object' && Object.keys(entries).length <= 512);
  for (const [name, row] of Object.entries(entries)) {
    keys(row, ['mode', 'sha256']);
    need(relative(name) && name !== 'manifest.json' && [0o400, 0o500].includes(row.mode) && HEX64.test(row.sha256));
  }
  for (const name of ['bin/omp_canonical_bootstrap.mjs', 'bin/harness_canonical_bootstrap.py', 'bin/canonical-bootstrap-source.json']) need(Object.hasOwn(entries, name));
  const admitted = [admitTree(root, entries, release.bytes, home)];
  try {
    const { value: pin } = readJson(path.join(root, 'bin/canonical-bootstrap-source.json'));
    validatePin(pin);
    const source = path.join(base, 'canonical-bootstrap', pin.revision, pin.manifest_sha256);
    const manifest = readJson(path.join(source, 'manifest.json'));
    need(hash(manifest.bytes) === pin.manifest_sha256 && canonical(manifest.value) === canonical({ schema: 'canonical-bootstrap-source/v1', files: pin.files }));
    admitted.push(admitTree(source, Object.fromEntries(pin.files.map(r => [r.path, { ...r, mode: 0o400 }])), manifest.bytes, home));
    return { home, root, source, pin, release: release.value, releaseDigest: hash(release.bytes), check() { for (const a of admitted) a.check(); }, close() { for (const a of admitted) a.close(); } };
  } catch (error) { for (const a of admitted) a.close(); throw error; }
}

export function openChannel(value) {
  need(typeof value === 'string' && /^(?:[3-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$/.test(value), 'control_fd_invalid');
  const fd = Number(value);
  need(fs.fstatSync(fd).isSocket(), 'control_fd_invalid');
  let seq = 0;
  const buffer = Buffer.allocUnsafe(LIMIT);
  let used = 0;
  let offset = 0;
  function read() {
    let end = offset;
    for (;;) {
      for (; end < used; end++) {
        if (buffer[end] !== 10) continue;
        const text = buffer.toString('utf8', offset, end);
        offset = end + 1;
        if (offset === used) offset = used = 0;
        return JSON.parse(text);
      }
      if (offset) { buffer.copy(buffer, 0, offset, used); used -= offset; end -= offset; offset = 0; }
      need(used < LIMIT, 'control_frame_budget');
      let count;
      try { count = fs.readSync(fd, buffer, used, LIMIT - used, null); } catch { fail('control_unavailable'); }
      need(count > 0, 'control_eof');
      used += count;
    }
  }
  return { read, rpc(type, session_id, extra = {}) {
    const current = ++seq;
    const bytes = Buffer.from(JSON.stringify({ type, seq: current, session_id, ...extra }) + '\n');
    need(bytes.length <= LIMIT, 'control_frame_budget');
    let offset = 0;
    try { while (offset < bytes.length) { const n = fs.writeSync(fd, bytes, offset, bytes.length - offset); need(n > 0, 'control_unavailable'); offset += n; } } catch { fail('control_unavailable'); }
    const reply = read();
    need(reply && reply.seq === current && reply.ok === true && Object.keys(reply).sort().join(',') === 'ok,seq', 'owner_check_failed');
  } };
}
function watchOwner(record, invalidate) {
  const raw = process.env.HARNESS_CANONICAL_BOOTSTRAP_ALIVE_FD;
  need(typeof raw === 'string' && /^(?:[3-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$/.test(raw), 'control_fd_invalid');
  const fd = Number(raw);
  keys(record.liveness, ['read_fd', 'identity']);
  need(record.liveness.read_fd === fd && raw !== process.env.HARNESS_CANONICAL_BOOTSTRAP_FD, 'control_fd_invalid');
  identityRecord(record.liveness.identity);
  const info = fs.fstatSync(fd, { bigint: true });
  need(info.isFIFO(), 'control_fd_invalid');
  const actual = identity(info);
  need(['dev', 'ino', 'uid', 'mode', 'nlink'].every(key => actual[key] === record.liveness.identity[key]), 'control_fd_invalid');
  // No bytes or commands travel here. EOF can only revoke the one operation;
  // the separate socket remains the sole sequenced metadata/reply channel.
  // Bun's net.Socket accepts this FIFO but does not deliver its EOF. A file
  // stream observes the actual inherited pipe, including revocation with no data.
  const owner = fs.createReadStream(null, { fd, autoClose: true, highWaterMark: 1 });
  owner.on('data', invalidate);
  owner.once('end', invalidate);
  owner.once('error', invalidate);
  return owner;
}
function validateFrame(frame, source) {
  keys(frame, ['schema', 'operation_id', 'nonce', 'record_sha256', 'record_identity', 'record']);
  need(frame.schema === 'launcher-canonical-bootstrap-control/v1' && /^[0-9a-f]{32}$/.test(frame.operation_id) && /^[0-9a-f]{32}$/.test(frame.nonce) && HEX64.test(frame.record_sha256));
  identityRecord(frame.record_identity);
  const r = frame.record;
  need(r && hash(canonical(r)) === frame.record_sha256);
  need(r.schema === frame.schema && r.purpose === 'canonical-update' && r.operation_id === frame.operation_id && r.nonce === frame.nonce);
  keys(r.request, ['profile', 'expected_base', 'revision']);
  need(text(r.request.profile) && HEX40.test(r.request.expected_base) && HEX40.test(r.request.revision) && r.request_sha256 === hash(canonical(r.request)));
  need(Number.isSafeInteger(r.expires_at) && r.expires_at > Date.now() && r.expires_at <= Date.now() + LIFE);
  need(r.account_home === source.home && r.runtime.path === source.root && r.runtime.revision === source.release.revision && r.runtime.version === source.release.version && r.runtime.manifest_sha256 === source.releaseDigest);
  need(r.source.path === source.source && r.source.revision === source.pin.revision && r.source.manifest_sha256 === source.pin.manifest_sha256);
  for (const actor of [r.parent, r.native]) {
    keys(actor, ['pid', 'ppid', 'pgid', 'uid', 'generation', 'executable', 'argv']);
    need(actor.uid === process.getuid() && Number.isSafeInteger(actor.ppid) && actor.ppid > 0 && Number.isSafeInteger(actor.pgid) && actor.pgid > 0);
    need(Number.isSafeInteger(actor.pid) && actor.pid > 1 && Array.isArray(actor.generation) && actor.generation.length === 2 && actor.generation.every(n => Number.isSafeInteger(n) && n >= 0));
    need(text(actor.executable) && Array.isArray(actor.argv) && actor.argv.length > 0 && actor.argv.every(text));
  }
  need(r.native.pid === process.pid && r.parent.pid === process.ppid);
  const operation = path.join(source.home, '.local/state/kilhyeonjun-harness/launcher-runtimes/canonical-bootstrap/operations', frame.operation_id);
  for (const [name, leaf] of [['control', null], ['lease', 'lease']]) {
    keys(r[name], ['path', 'identity']);
    identityRecord(r[name].identity);
    need(r[name].path === (leaf ? path.join(operation, leaf) : operation));
  }
  return r;
}
function observe(source, frame, session_id) {
  const proof = spawnSync('/usr/bin/python3', ['-I', '-S', '-B', path.join(source.root, 'bin/harness_canonical_bootstrap.py'), '_observe'], {
    input: JSON.stringify({ frame, session_id }), encoding: 'utf8', timeout: 5000, maxBuffer: LIMIT,
    env: { HOME: source.home, PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' }, cwd: source.home,
  });
  need(!proof.error && proof.status === 0, 'observer_failed');
  let result;
  try { result = JSON.parse(proof.stdout); } catch { fail('observer_failed'); }
  need(canonical(result) === '{"ok":true}', 'observer_failed');
}
export function validateScope(scope, request, now) {
  keys(scope, ['profile', 'root', 'expectedBase', 'revision', 'origin', 'expiresAt', 'commitCount', 'pathCount']);
  need(scope.profile === request.profile && scope.expectedBase === request.expected_base && scope.revision === request.revision, 'scope_mismatch');
  need(text(scope.root) && path.isAbsolute(scope.root) && path.normalize(scope.root) === scope.root && text(scope.origin), 'scope_mismatch');
  need(Number.isSafeInteger(scope.expiresAt) && scope.expiresAt > now && scope.expiresAt <= now + LIFE, 'scope_expired');
  need([scope.commitCount, scope.pathCount].every(n => Number.isSafeInteger(n) && n >= 0), 'scope_mismatch');
}
export function approvalPrompt(scope, authority) {
  const full = [
    'Canonical update — approve this operation once only', `Profile: ${scope.profile}`, `Root: ${scope.root}`, `Origin: ${scope.origin}`,
    `Expected base: ${scope.expectedBase}`, `Target revision: ${scope.revision}`, `Commits: ${scope.commitCount}; paths: ${scope.pathCount}`,
    `Expires: ${new Date(scope.expiresAt).toISOString()}`, `Release: ${authority.release}`, `Private source: ${authority.revision}`, `Manifest: ${authority.digest}`,
  ].join('\n');
  return Object.freeze({ full, compact: full });
}
function safeResult(result) {
  keys(result, ['status', 'profile', 'root', 'before', 'target', 'after', 'changed', 'verified', 'detail']);
  need(['updated', 'already_current', 'not_applied', 'uncertain'].includes(result.status) && typeof result.verified === 'boolean' && [true, false, null].includes(result.changed) && (result.after === null || HEX40.test(result.after)), 'engine_result_invalid');
  return { ...result, detail: ['sealed_verifier_passed', 'not_applied'].includes(result.detail) ? result.detail : 'engine_result_redacted' };
}

// The operation owns exactly one promise. Invalidation only aborts; disposal waits
// for prepare/apply to settle, including the engine's noncancellable readback.
export async function runOperation({ ctx, request, runtime, prepare, current, deadline, authority, signal, finish, now = Date.now }) {
  let prepared;
  let decision = null;
  let phase = 'prepare';
  let result = null;
  let error_code = null;
  let cleanup_verified = false;
  let prepareStarted = false;
  let engineCleanupFailed = false;
  const check = () => { need(!signal.aborted, 'cancelled'); need(now() < deadline, 'scope_expired'); current(); };
  try {
    check();
    prepareStarted = true;
    prepared = await prepare(Object.freeze({ ...request }), { ...runtime, signal, assertCurrent: check });
    check();
    validateScope(prepared.scope, request, now());
    const scope = canonical(prepared.scope);
    phase = 'approval';
    const answer = await ctx.ui.approve(approvalPrompt({ ...prepared.scope, expiresAt: Math.min(deadline, prepared.scope.expiresAt) }, authority), { signal, timeout: Math.max(1, Math.min(deadline, prepared.scope.expiresAt) - now()) });
    decision = answer === 'once' ? 'once' : signal.aborted ? 'cancelled' : 'deny';
    check();
    need(canonical(prepared.scope) === scope, 'scope_changed');
    validateScope(prepared.scope, request, now());
    if (answer === 'once') {
      check();
      phase = 'apply';
      const actual = await prepared.apply();
      engineCleanupFailed = typeof actual?.detail === 'string' && actual.detail.includes('cleanup_failed:');
      result = safeResult(actual);
      need(result.profile === request.profile && result.root === prepared.scope.root && result.before === request.expected_base && result.target === request.revision, 'engine_result_invalid');
    }
  } catch (error) {
    const code = error instanceof Error ? error.message : '';
    error_code = ['cancelled', 'scope_expired', 'scope_mismatch', 'scope_changed', 'source_changed', 'owner_check_failed', 'observer_failed', 'control_eof', 'session_changed', 'engine_result_invalid'].includes(code) ? code : phase === 'prepare' ? 'prepare_failed' : phase === 'apply' ? 'apply_failed' : 'approval_failed';
    if (signal.aborted && phase !== 'apply') decision = 'cancelled';
  } finally {
    try {
      if (prepared) {
        await prepared.dispose();
        cleanup_verified = !engineCleanupFailed;
        if (engineCleanupFailed) error_code = 'cleanup_failed';
      }
      else cleanup_verified = !prepareStarted;
    }
    catch { error_code = 'cleanup_failed'; }
    // No RESULT claims cleanup until all engine work has drained.
    const receipt = { decision, phase: cleanup_verified ? 'disposed' : phase, cleanup_verified, error_code, result };
    try { await finish(receipt); } finally { ctx.shutdown(); }
  }
}

export default function canonicalBootstrap(api) {
  let started = false;
  let controller;
  let ownedPromise;
  let ctx;
  let timer;
  const invalidate = () => { controller?.abort(); ctx?.abort(); };
  api.on('input', () => { invalidate(); return { handled: true }; });
  api.on('before_agent_start', (_event, context) => { context.abort(); invalidate(); });
  for (const event of ['session_before_switch', 'session_switch']) api.on(event, () => { invalidate(); });
  api.on('session_shutdown', async () => {
    invalidate();
    await ownedPromise;
  });
  api.on('session_start', (_event, context) => {
    if (started) { invalidate(); context.abort(); return; }
    started = true;
    ctx = context;
    controller = new AbortController();
    // SDK-owned scheduling: no hook awaits human input or asynchronous fetching.
    timer = ctx.setTimeout(async () => {
      let source;
      let channel;
      let owner;
      let session;
      let deadlineTimer;
      let bound = false;
      let handedOff = false;
      try {
        need(ctx.agent?.kind === 'main' && ctx.mode === 'tui' && ctx.hasUI === true && typeof ctx.ui?.approve === 'function', 'native_ui_required');
        need(!controller.signal.aborted, 'cancelled');
        source = admitOwnSource();
        channel = openChannel(process.env.HARNESS_CANONICAL_BOOTSTRAP_FD);
        const frame = channel.read();
        const record = validateFrame(frame, source);
        owner = watchOwner(record, invalidate);
        session = ctx.sessionManager.getSessionId();
        need(UUID.test(session), 'session_changed');
        const begin = performance.now();
        const remaining = record.expires_at - Date.now();
        const current = () => {
          need(!controller.signal.aborted, 'cancelled');
          need(ctx.sessionManager.getSessionId() === session && ctx.agent?.kind === 'main' && ctx.mode === 'tui' && ctx.hasUI === true, 'session_changed');
          need(Date.now() < record.expires_at && performance.now() - begin < remaining, 'scope_expired');
          source.check();
          observe(source, frame, session);
          channel.rpc('CHECK', session);
        };
        // Materialize the real SDK-owned journal without a model conversation.
        // This public pinned SessionManager method is not consent or a UUID file
        // fabricated by the carrier; the independent observer still checks it.
        need(ctx.sessionManager instanceof api.pi.SessionManager && typeof ctx.sessionManager.ensureOnDisk === 'function', 'native_persistence_unavailable');
        deadlineTimer = ctx.setTimeout(invalidate, Math.max(1, remaining));
        await ctx.sessionManager.ensureOnDisk();
        api.appendEntry('canonical-bootstrap', { operation_id: frame.operation_id, request_sha256: record.request_sha256 });
        need(!controller.signal.aborted && ctx.sessionManager.getSessionId() === session, 'session_changed');
        source.check();
        observe(source, frame, session);
        channel.rpc('BIND', session);
        bound = true;
        current();
        const engine = await import(pathToFileURL(path.join(source.source, 'core/scripts/omp_canonical_update.ts')).href);
        current();
        need(typeof engine.prepareCanonicalUpdate === 'function');
        handedOff = true;
        ownedPromise = runOperation({ ctx, request: record.request, signal: controller.signal, deadline: record.expires_at, current,
          authority: { release: record.runtime.revision, revision: source.pin.revision, digest: source.pin.manifest_sha256 },
          runtime: { accountHome: source.home, python: '/usr/bin/python3', lockHelper: path.join(source.source, 'core/scripts/omp_canonical_update_lock.py'), verifier: path.join(source.source, 'core/scripts/harness_compile.py'), occupancy: path.join(source.source, 'core/scripts/canonical_occupancy.py') },
          prepare: engine.prepareCanonicalUpdate, finish: receipt => channel.rpc('RESULT', session, receipt),
        });
        await ownedPromise;
      } catch (error) {
        controller.abort();
        const category = ['native_ui_required', 'source_admission_failed', 'source_changed', 'control_fd_invalid', 'control_eof', 'session_changed', 'cancelled', 'observer_failed'].includes(error?.message) ? error.message : 'native_start_failed';
        ctx.ui?.notify?.(`Canonical bootstrap stopped: ${category}`, 'error');
        // Before binding there is no authorized receipt. EOF is deliberately unknown.
        if (bound && !handedOff) {
          try { channel.rpc('RESULT', session, { decision: null, phase: 'disposed', cleanup_verified: true, error_code: 'source_unavailable', result: null }); } catch { /* Owner loss remains unknown. */ }
        }
        ctx.abort();
        ctx.shutdown();
      } finally {
        if (deadlineTimer) ctx.clearTimer(deadlineTimer);
        if (timer) ctx.clearTimer(timer);
        owner?.destroy();
        source?.close();
      }
    }, 0);
  });
}

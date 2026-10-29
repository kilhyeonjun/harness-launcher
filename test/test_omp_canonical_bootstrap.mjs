import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import bootstrap, { accountHome, runOperation, safeResult, canonical, validateScope, validatePin, validateNative, admitTree, openChannel, identity } from '../bin/omp_canonical_bootstrap.mjs';

test('native account authority ignores fresh HOME and HOME-sensitive userInfo', { skip: process.platform !== 'darwin' }, () => {
  const carrier = new URL('../bin/omp_canonical_bootstrap.mjs', import.meta.url).href;
  const script = `import os from 'node:os';
    const expected = os.userInfo().homedir;
    const original = os.userInfo;
    os.userInfo = () => ({ ...original(), homedir: process.env.HOME });
    const { accountHome } = await import(${JSON.stringify(carrier)});
    const actual = accountHome();
    console.log(JSON.stringify({ matchesOSAccount: actual === expected, ignoresFreshHome: actual !== process.env.HOME }));`;
  const done = childProcess.spawnSync(process.execPath, ['--input-type=module', '-e', script], {
    cwd: '/', env: { PATH: '/usr/bin:/bin', HOME: '/untrusted-fresh-native-home' }, encoding: 'utf8', timeout: 20000,
  });
  assert.equal(done.status, 0, done.stderr);
  assert.deepEqual(JSON.parse(done.stdout), { matchesOSAccount: true, ignoresFreshHome: true });
});
function withAccountReply(reply, run) {
  const original = childProcess.spawnSync;
  childProcess.spawnSync = typeof reply === 'function' ? reply : () => reply;
  syncBuiltinESMExports();
  try { run(); } finally { childProcess.spawnSync = original; syncBuiltinESMExports(); }
}
test('account proof rejects failed queries and malformed or foreign authority without fallback', { skip: process.platform !== 'darwin' }, () => {
  const home = os.userInfo().homedir;
  const uid = process.getuid();
  const valid = Buffer.from(canonical({ home, uid }));
  const okay = { status: 0, signal: null, stdout: valid };
  const replies = [
    { ...okay, error: new Error('private query diagnostic') },
    { ...okay, status: 1 }, { ...okay, status: null }, { ...okay, status: undefined },
    { ...okay, signal: 'SIGKILL', status: null },
    { ...okay, stdout: Buffer.alloc(0) }, { ...okay, stdout: Buffer.alloc(4097) },
    { ...okay, stdout: valid.toString() }, { ...okay, stdout: Buffer.from('{') },
    { ...okay, stdout: Buffer.from(canonical({ home, uid: uid + 1 })) },
    { ...okay, stdout: Buffer.from(canonical({ home, uid: String(uid) })) },
    { ...okay, stdout: Buffer.from(canonical({ home, uid, extra: true })) },
    { ...okay, stdout: Buffer.from(`{"home":${JSON.stringify(home)},"home":${JSON.stringify(home)},"uid":${uid}}`) },
    { ...okay, stdout: Buffer.from(canonical({ home, uid }) + '\n') },
    { ...okay, stdout: Buffer.from(canonical({ home: '../foreign-home', uid })) },
    () => { throw new Error('private spawn diagnostic'); },
  ];
  for (const reply of replies) withAccountReply(reply, () => assert.throws(accountHome, /^Error: source_admission_failed$/));
});
test('account proof accepts canonical UTF8 but rejects escaped, linked or writable homes', { skip: process.platform !== 'darwin' }, () => {
  const base = fs.mkdtempSync(path.join(os.userInfo().homedir, '.native-account-proof-'));
  const home = path.join(base, '界');
  const linked = path.join(base, 'linked');
  fs.mkdirSync(home, { mode: 0o700 });
  fs.symlinkSync(home, linked);
  const proof = value => ({ status: 0, signal: null, stdout: Buffer.from(canonical({ home: value, uid: process.getuid() }), 'utf8') });
  try {
    withAccountReply(proof(home), () => assert.equal(accountHome(), home));
    const escaped = proof(home);
    escaped.stdout = Buffer.from(escaped.stdout.toString().replace('界', '\\u754c'));
    withAccountReply(escaped, () => assert.throws(accountHome, /^Error: source_admission_failed$/));
    withAccountReply(proof(linked), () => assert.throws(accountHome, /^Error: source_admission_failed$/));
    fs.chmodSync(home, 0o777);
    withAccountReply(proof(home), () => assert.throws(accountHome, /^Error: source_admission_failed$/));
  } finally { fs.rmSync(base, { recursive: true, force: true }); }
});

const request = Object.freeze({ profile: 'sample', expected_base: 'a'.repeat(40), revision: 'b'.repeat(40) });
const authority = { release: 'c'.repeat(40), revision: 'd'.repeat(40), digest: 'e'.repeat(64) };
const scope = () => ({ profile: request.profile, root: '/canonical/sample', origin: 'git@example.invalid:sample/repository', expectedBase: request.expected_base, revision: request.revision, expiresAt: 20000, commitCount: 2, pathCount: 3 });
// Synthetic private-engine contract; fixture approval is not production consent.
const engineResult = () => ({ status: 'updated', profile: request.profile, root: '/canonical/sample', before: request.expected_base, target: request.revision, after: request.revision, changed: true, verified: true, detail: 'sealed_verifier_passed', occupancy: null, blockers: [] });
const publicResult = (change = {}) => ({ status: 'updated', profile: request.profile, root: '/canonical/sample', before: request.expected_base, target: request.revision, after: request.revision, changed: true, verified: true, detail: 'sealed_verifier_passed', ...change });
function deferred() { let resolve; let reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function fixture(overrides = {}) {
  const controller = new AbortController();
  const events = [];
  const receipts = [];
  let now = 10000;
  const plan = { scope: scope(), async apply() { events.push('apply'); return engineResult(); }, async dispose() { events.push('dispose'); } };
  const options = {
    ctx: { ui: { async approve(prompt, opts) { events.push('approve'); assert.equal(opts.signal, controller.signal); assert.ok(opts.timeout > 0); return 'once'; } }, shutdown() { events.push('shutdown'); } },
    request, runtime: { accountHome: '/account' }, signal: controller.signal,
    async prepare(input, runtime) { events.push('prepare'); assert.deepEqual(input, request); assert.equal(runtime.signal, controller.signal); runtime.assertCurrent(); return plan; },
    current() { events.push('check'); }, deadline: 30000, authority,
    finish(receipt) { events.push('result'); receipts.push(receipt); }, now: () => now,
    ...overrides,
  };
  return { options, plan, events, receipts, controller, setNow(value) { now = value; }, run() { return runOperation(options); } };
}

test('once applies exactly once, disposes, acknowledges result, then shuts down', async () => {
  const f = fixture();
  let prompt;
  f.options.ctx.ui.approve = async value => { prompt = value; return 'once'; };
  await f.run();
  assert.equal(f.events.filter(e => e === 'apply').length, 1);
  assert.deepEqual(f.events.slice(-4), ['apply', 'dispose', 'result', 'shutdown']);
  assert.deepEqual(f.receipts[0], { decision: 'once', phase: 'disposed', cleanup_verified: true, error_code: null, result: publicResult() });
  for (const rendering of [prompt.full, prompt.compact]) {
    for (const field of [request.profile, '/canonical/sample', 'git@example.invalid:sample/repository', request.expected_base, request.revision, authority.release, authority.revision, authority.digest, 'Commits: 2; paths: 3', new Date(20000).toISOString()]) assert.ok(rendering.includes(field));
  }
  assert.equal(Object.hasOwn(prompt, 'session'), false);
});
test('exported result adapter projects eleven fields without mutating the engine return', () => {
  const actual = Object.freeze({ ...engineResult(), occupancy: Object.freeze({ diagnostic: 'private occupancy' }), blockers: Object.freeze(['private blocker']) });
  assert.deepEqual(safeResult(actual), publicResult());
  assert.equal(Object.keys(actual).length, 11);
  assert.equal(actual.occupancy.diagnostic, 'private occupancy');
  for (const occupancy of [null, [], 42, 'private occupancy', undefined]) {
    assert.deepEqual(safeResult({ ...engineResult(), occupancy, blockers: [42, null, { private: 'diagnostic' }] }), publicResult());
  }
  const opaque = {};
  Object.defineProperty(opaque, 'diagnostic', { enumerable: true, get() { throw new Error('must not inspect private diagnostics'); } });
  assert.deepEqual(safeResult({ ...engineResult(), occupancy: opaque, blockers: [opaque] }), publicResult());
  const noEffect = { ...engineResult(), status: 'not_applied', after: request.expected_base, changed: false, verified: false, detail: 'not_applied' };
  assert.deepEqual(safeResult(noEffect), publicResult({ status: 'not_applied', after: request.expected_base, changed: false, verified: false, detail: 'not_applied' }));
});
test('all five engine statuses reach a closed public receipt without private diagnostics', async () => {
  const cases = [
    { status: 'updated' },
    { status: 'already_current', changed: false },
    { status: 'applied_unverified', verified: false },
    { status: 'not_applied', after: request.expected_base, changed: false, verified: false },
    { status: 'uncertain', after: null, changed: null, verified: false },
    { status: 'uncertain', after: 'c'.repeat(40), changed: null, verified: false },
  ];
  for (const change of cases) {
    const f = fixture();
    const actual = { ...engineResult(), ...change, detail: 'private-detail-token', occupancy: { diagnostic: 'private-occupancy-token' }, blockers: ['private-blocker-token'] };
    f.plan.apply = async () => { f.events.push('apply'); return actual; };
    await f.run();
    assert.deepEqual(f.receipts[0], { decision: 'once', phase: 'disposed', cleanup_verified: true, error_code: null,
      result: publicResult({ ...change, detail: 'engine_result_redacted' }) });
    assert.equal(f.events.filter(e => e === 'apply').length, 1);
    assert.equal(JSON.stringify(f.receipts).includes('private-'), false);
    assert.equal(Object.keys(f.receipts[0].result).length, 9);
  }
});
test('dirty already-current readback is unverified without inventing a HEAD change', async () => {
  for (const changed of [false, null]) {
    const f = fixture();
    f.plan.apply = async () => ({ ...engineResult(), status: 'already_current', changed, verified: false, detail: 'private dirty worktree' });
    await f.run();
    assert.deepEqual(f.receipts[0].result, publicResult({ status: 'applied_unverified', changed, verified: false, detail: 'engine_result_redacted' }));
    assert.equal(f.receipts[0].result.after, request.revision);
    assert.equal(f.receipts[0].error_code, null);
  }
});
test('malformed, contradictory and out-of-scope engine returns are rejected after one apply and cleanup', async () => {
  const malformed = [
    null, [], publicResult(),
    ...[
      { status: 'unknown' }, { extra: 'private-extra-token' }, { private_diagnostic: 'private-extra-token' },
      { profile: null }, { root: 'relative' }, { before: 1 }, { target: 'bad' }, { after: 1 },
      { after: 'bad' }, { changed: 'false' }, { verified: 1 }, { detail: {} },
      { blockers: {} }, { blockers: null },
      { status: 'updated', verified: false }, { status: 'updated', after: null },
      { status: 'already_current', verified: true, after: request.expected_base },
      { status: 'already_current', verified: false, after: null },
      { profile: 'other' }, { root: '/canonical/other' }, { before: 'c'.repeat(40) }, { target: 'c'.repeat(40), after: 'c'.repeat(40) },
    ].map(change => ({ ...engineResult(), ...change })),
  ];
  for (const actual of malformed) {
    const f = fixture();
    f.plan.apply = async () => { f.events.push('apply'); return actual; };
    await f.run();
    assert.deepEqual(f.receipts[0], { decision: 'once', phase: 'disposed', cleanup_verified: true, error_code: 'engine_result_invalid', result: null });
    assert.deepEqual(f.events.slice(-4), ['apply', 'dispose', 'result', 'shutdown']);
    assert.equal(f.events.filter(e => e === 'apply').length, 1);
    assert.equal(JSON.stringify(f.receipts).includes('private-'), false);
  }
});
for (const answer of ['deny', 'session', undefined, true, { decision: 'once' }]) {
  test(`only native literal once can apply (${JSON.stringify(answer)})`, async () => {
    const f = fixture();
    f.options.ctx.ui.approve = async () => answer;
    await f.run();
    assert.equal(f.events.includes('apply'), false);
    assert.equal(f.receipts[0].decision, 'deny');
    assert.equal(f.receipts[0].result, null);
    assert.equal(f.receipts[0].cleanup_verified, true);
  });
}
test('a rejected approval drains without effect and hides raw errors', async () => {
  const f = fixture();
  f.options.ctx.ui.approve = async () => { throw new Error('sensitive diagnostic'); };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].error_code, 'approval_failed');
  assert.equal(JSON.stringify(f.receipts).includes('sensitive'), false);
});
test('expiry after actual once cannot apply', async () => {
  const f = fixture();
  f.options.ctx.ui.approve = async () => { f.setNow(30000); return 'once'; };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].error_code, 'scope_expired');
});
test('plan expiry earlier than operation expiry is enforced', async () => {
  const f = fixture();
  f.options.ctx.ui.approve = async () => { f.setNow(20000); return 'once'; };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].error_code, 'scope_expired');
});
test('cancel during approval never applies', async () => {
  const f = fixture();
  f.options.ctx.ui.approve = async () => { f.controller.abort(); return 'once'; };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].decision, 'cancelled');
  assert.equal(f.receipts[0].error_code, 'cancelled');
});
test('session drift observed after once never applies', async () => {
  const f = fixture();
  let drift = false;
  f.options.current = () => { if (drift) throw new Error('session_changed'); };
  f.options.ctx.ui.approve = async () => { drift = true; return 'once'; };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].error_code, 'session_changed');
});
test('source and owner freshness failures after once never apply', async () => {
  for (const error of ['source_changed', 'owner_check_failed', 'observer_failed', 'control_eof']) {
    const f = fixture();
    let lost = false;
    f.options.current = () => { if (lost) throw new Error(error); };
    f.options.ctx.ui.approve = async () => { lost = true; return 'once'; };
    await f.run();
    assert.equal(f.events.includes('apply'), false);
    assert.equal(f.receipts[0].error_code, error);
  }
});
test('approval cannot mutate the displayed plan and keep once authority', async () => {
  const f = fixture();
  f.options.ctx.ui.approve = async () => { f.plan.scope.root = '/other'; return 'once'; };
  await f.run();
  assert.equal(f.events.includes('apply'), false);
  assert.equal(f.receipts[0].error_code, 'scope_changed');
});
test('preparation rejection makes no false cleanup claim', async () => {
  const f = fixture({ prepare: async () => { throw new Error('private preparation failure'); } });
  await f.run();
  assert.equal(f.receipts[0].result, null);
  assert.equal(f.receipts[0].cleanup_verified, false);
  assert.equal(f.receipts[0].error_code, 'prepare_failed');
});
test('cancellation during prepare waits for the owned promise and disposes', async () => {
  const f = fixture();
  const ready = deferred();
  f.options.prepare = () => ready.promise;
  const running = f.run();
  f.controller.abort();
  assert.equal(f.receipts.length, 0);
  ready.resolve(f.plan);
  await running;
  assert.deepEqual(f.events.slice(-3), ['dispose', 'result', 'shutdown']);
  assert.equal(f.events.includes('apply'), false);
});
test('cancellation during apply never races disposal or fabricates unchanged', async () => {
  const f = fixture();
  const entered = deferred();
  const drain = deferred();
  let active = false;
  f.plan.apply = async () => { active = true; entered.resolve(); const result = await drain.promise; active = false; return result; };
  f.plan.dispose = async () => { assert.equal(active, false); f.events.push('dispose'); };
  const running = f.run();
  await entered.promise;
  f.controller.abort();
  assert.equal(f.events.includes('dispose'), false);
  assert.equal(f.receipts.length, 0);
  const uncertain = { ...engineResult(), status: 'uncertain', after: null, changed: null, verified: false, detail: 'command_failed:private stderr' };
  drain.resolve(uncertain);
  await running;
  assert.deepEqual(f.receipts[0].result, publicResult({ status: 'uncertain', after: null, changed: null, verified: false, detail: 'engine_result_redacted' }));
  assert.equal(f.receipts[0].result.after, null);
});
test('aborted apply rejection preserves once and unknown effect rather than claiming cancellation before effect', async () => {
  const f = fixture();
  f.plan.apply = async () => { f.controller.abort(); throw new Error('private apply diagnostic'); };
  await f.run();
  assert.equal(f.receipts[0].decision, 'once');
  assert.equal(f.receipts[0].result, null);
  assert.equal(f.receipts[0].error_code, 'apply_failed');
  assert.equal(f.receipts[0].cleanup_verified, true);
  assert.equal(JSON.stringify(f.receipts).includes('private'), false);
});
test('cleanup failure is reported after effect without losing actual result', async () => {
  const f = fixture();
  f.plan.dispose = async () => { throw new Error('private cleanup diagnostic'); };
  await f.run();
  assert.equal(f.receipts[0].cleanup_verified, false);
  assert.equal(f.receipts[0].phase, 'apply');
  assert.equal(f.receipts[0].error_code, 'cleanup_failed');
  assert.deepEqual(f.receipts[0].result, publicResult());
});
test('engine-reported cleanup failure is not erased by idempotent dispose', async () => {
  const f = fixture();
  f.plan.apply = async () => ({ ...engineResult(), status: 'uncertain', verified: false, detail: 'not_applied; cleanup_failed:private diagnostic' });
  await f.run();
  assert.equal(f.receipts[0].cleanup_verified, false);
  assert.equal(f.receipts[0].error_code, 'cleanup_failed');
  assert.equal(f.receipts[0].result.status, 'uncertain');
  assert.equal(f.receipts[0].result.detail, 'engine_result_redacted');
});
test('result acknowledgement failure does not retry effect and still shuts down', async () => {
  const f = fixture({ finish() { throw new Error('closed'); } });
  await assert.rejects(f.run(), /closed/);
  assert.equal(f.events.filter(e => e === 'apply').length, 1);
  assert.equal(f.events.at(-1), 'shutdown');
});
test('closed scope rejects mismatches and malformed counts before approval', async () => {
  for (const change of [{ profile: 'other' }, { revision: '0'.repeat(40) }, { pathCount: -1 }, { commitCount: 1.1 }, { origin: 'bad\norigin' }, { root: 'relative' }, { expiresAt: 10000 }, { extra: true }]) {
    assert.throws(() => validateScope({ ...scope(), ...change }, request, 10000));
    const f = fixture();
    Object.assign(f.plan.scope, change);
    await f.run();
    assert.equal(f.events.includes('approve'), false);
    assert.equal(f.events.includes('apply'), false);
  }
});
function nativeFixture() {
  const artifact = { schema: 'synthetic-native-artifact/v1', profile: 'alpha',
    release: { version: '18.11.3-fixture.2', source_revision: '1'.repeat(40), contract_id: 'synthetic-runtime/v1',
      upstream_base_version: '18.11.3', upstream_base_revision: '2'.repeat(40), source_patch_sha256: '3'.repeat(64), build_provenance_sha256: '4'.repeat(64) },
    binary: { platform: 'darwin-arm64', sha256: '5'.repeat(64), bytes: 1234 },
    local_patch_sha256: '6'.repeat(64), reviewed_base_revision: '7'.repeat(40) };
  const bytes = Buffer.from(canonical(artifact) + '\n');
  const pin = { native_artifact: { manifest_sha256: createHash('sha256').update(bytes).digest('hex'), manifest_bytes: bytes.length,
    binary_sha256: artifact.binary.sha256, binary_bytes: artifact.binary.bytes } };
  const home = '/synthetic-home';
  const binary = path.join(home, '.local/state/kilhyeonjun-harness/omp-bin', `${artifact.release.version}-${artifact.binary.sha256.slice(0, 8)}`, 'bin/omp');
  const record = { request: { profile: 'alpha' }, native_artifact: artifact,
    context: { binary_path: binary, binary_release: structuredClone(artifact.release), binary_sha256: artifact.binary.sha256, binary_size: artifact.binary.bytes },
    native: { executable: binary, argv: [binary, '--no-session'] } };
  return { record, pin, home };
}
test('native independently proves exact artifact before owner and full context identity', () => {
  const f = nativeFixture();
  validateNative(f.record, f.pin, f.home);
  const mutations = [
    r => { r.request.profile = 'bravo'; },
    r => { r.native_artifact.profile = 'bravo'; r.request.profile = 'bravo'; },
    r => { r.native_artifact.release.contract_id = 'reflected-fake'; r.context.binary_release.contract_id = 'reflected-fake'; },
    r => { r.native_artifact.binary.platform = 'other-platform'; },
    r => { r.native_artifact.binary.bytes++; r.context.binary_size++; },
    r => { r.native_artifact.binary.sha256 = '0'.repeat(64); r.context.binary_sha256 = '0'.repeat(64); },
    r => { r.context.binary_path += '-other'; },
    r => { r.context.binary_sha256 = '0'.repeat(64); },
    r => { r.context.binary_size++; },
    r => { r.native.executable += '-other'; },
    r => { r.native.argv[0] += '-other'; },
    r => { delete r.native_artifact; },
    r => { r.native_artifact = null; },
    ...Object.keys(f.record.native_artifact.release).map(key => r => { r.context.binary_release[key] = 'wrong'; }),
  ];
  for (const mutate of mutations) {
    const r = structuredClone(f.record); mutate(r);
    assert.throws(() => validateNative(r, f.pin, f.home));
  }
  for (const change of [{ manifest_bytes: f.pin.native_artifact.manifest_bytes + 1 }, { manifest_sha256: '0'.repeat(64) },
    { binary_sha256: '0'.repeat(64) }, { binary_bytes: f.pin.native_artifact.binary_bytes + 1 }]) {
    assert.throws(() => validateNative(f.record, { native_artifact: { ...f.pin.native_artifact, ...change } }, f.home));
  }
});
test('native stock accepts fourth registered context without artifact and refuses rich unsupported tuple', () => {
  const { record, home } = nativeFixture();
  const stock = { release: { version: '18.11.3', source_revision: '96894a6147d8cc64b7e00ad3a7d7178fd93b9531' }, sha256: 'd518310d647d467a2c5c3f2d38e34489a761996d766395c03b37c61a2203d02b', bytes: 194982944 };
  const binary = path.join(home, '.local/state/kilhyeonjun-harness/omp-bin', `${stock.release.version}-${stock.sha256.slice(0, 8)}`, 'bin/omp');
  record.request.profile = 'delta'; record.native_artifact = null;
  record.context = { binary_path: binary, binary_release: stock.release, binary_sha256: stock.sha256, binary_size: stock.bytes };
  record.native = { executable: binary, argv: [binary] };
  validateNative(record, {}, home);
  record.context.binary_release = { ...stock.release, contract_id: 'unsupported' };
  assert.throws(() => validateNative(record, {}, home));
});
test('public pin rejects alternate source closure or native artifact', () => {
  const rows = ['core/omp/model_modes.py', 'core/scripts/canonical_occupancy.py', 'core/scripts/cross_harness_surface_diff.py', 'core/scripts/harness_compile.py', 'core/scripts/launcher_runtime_snapshot.py', 'core/scripts/omp_canonical_update.ts', 'core/scripts/omp_canonical_update_lock.py'].map(p => ({ path: p, git_mode: '100644', bytes: 1, sha256: 'a'.repeat(64) }));
  const { pin: nativePin } = nativeFixture();
  const pin = { schema: 'launcher-canonical-bootstrap/v3', revision: 'b'.repeat(40), manifest_sha256: createHash('sha256').update(canonical({ schema: 'canonical-bootstrap-source/v1', files: rows }) + '\n').digest('hex'), files: rows, native_artifact: nativePin.native_artifact };
  validatePin(pin);
  for (const change of [{ schema: 'launcher-canonical-bootstrap/v2' }, { source: '/other' }, { revision: '../other' }, { files: [...rows].reverse() }, { files: rows.slice(1) }, { manifest_sha256: 'f'.repeat(64) }]) assert.throws(() => validatePin({ ...pin, ...change }));
  const mutations = [
    p => { p.native_by_profile = {}; },
    p => { p.native_artifact.extra = true; },
    p => { delete p.native_artifact.binary_bytes; },
    p => { p.native_artifact.binary_bytes = true; },
    p => { p.native_artifact.binary_bytes = Number.MAX_SAFE_INTEGER + 1; },
    p => { p.native_artifact.manifest_bytes = 65537; },
    p => { p.native_artifact.manifest_sha256 = 'invalid'; },
    p => { p.native_artifact.binary_sha256 = 'invalid'; },
  ];
  for (const mutate of mutations) {
    const candidate = structuredClone(pin); mutate(candidate);
    assert.throws(() => validatePin(candidate));
  }
});
test('source closure admission rejects bytes, links, extras, and post-admission drift', () => {
  const parent = fs.realpathSync(fs.mkdtempSync(path.join(os.userInfo().homedir, '.bootstrap-admission-')));
  // The internal admission boundary takes a tree; production never accepts a root override.
  const root = path.join(parent, 'sealed');
  fs.mkdirSync(root, { mode: 0o700 });
  const bytes = Buffer.from('admitted code\n');
  const manifest = Buffer.from('{}\n');
  const file = path.join(root, 'code');
  fs.writeFileSync(file, bytes, { mode: 0o400 });
  fs.writeFileSync(path.join(root, 'manifest.json'), manifest, { mode: 0o400 });
  fs.chmodSync(root, 0o500);
  const rows = { code: { mode: 0o400, sha256: createHash('sha256').update(bytes).digest('hex'), bytes: bytes.length } };
  try {
    const admitted = admitTree(root, rows, manifest, os.userInfo().homedir);
    try {
      admitted.check();
      fs.chmodSync(file, 0o600);
      fs.writeFileSync(file, 'changed');
      assert.throws(admitted.check, /source_changed/);
    } finally { admitted.close(); }
    fs.chmodSync(file, 0o400);
    assert.throws(() => admitTree(root, rows, manifest, os.userInfo().homedir));
    fs.chmodSync(root, 0o700);
    fs.unlinkSync(file);
    fs.symlinkSync('manifest.json', file);
    fs.chmodSync(root, 0o500);
    assert.throws(() => admitTree(root, rows, manifest, os.userInfo().homedir));
    fs.chmodSync(root, 0o700);
    fs.unlinkSync(file);
    fs.writeFileSync(file, bytes, { mode: 0o400 });
    fs.mkdirSync(path.join(root, 'unlisted'), { mode: 0o500 });
    fs.chmodSync(root, 0o500);
    assert.throws(() => admitTree(root, rows, manifest, os.userInfo().homedir));
  } finally { fs.chmodSync(root, 0o700); fs.rmSync(parent, { recursive: true, force: true }); }
});
test('unsigned Darwin inode identity is identical across Python and Bun signed stat values', () => {
  const stat = { dev: 0n, ino: -7540010787843248450n, uid: 501n, nlink: 0n, size: 0n, mtimeNs: 1n, ctimeNs: 1n, mode: 0o660n };
  assert.equal(identity(stat).ino, '10906733285866303166');
  assert.equal(identity({ ...stat, ino: 10906733285866303166n }).ino, identity(stat).ino);
  assert.equal(identity({ ...stat, ino: 1042410881n }).ino, '1042410881');
});
test('control FD is required, bounded, and must actually be a socket', () => {
  for (const fd of [undefined, '', '0', '2', '129', '3x', '+3', '03', '/socket']) assert.throws(() => openChannel(fd));
  const fd = fs.openSync(import.meta.filename ?? new URL(import.meta.url), 'r');
  try { assert.throws(() => openChannel(String(fd))); } finally { fs.closeSync(fd); }
});
test('lifecycle hooks consume input, abort ordinary prompts, and invalidate switches', () => {
  const hooks = new Map();
  let aborts = 0;
  const ctx = { abort() { aborts++; }, setTimeout() { return {}; } };
  bootstrap({ on(name, callback) { hooks.set(name, callback); } });
  hooks.get('session_start')({}, ctx);
  assert.deepEqual(hooks.get('input')({ text: 'ordinary prompt' }, ctx), { handled: true });
  hooks.get('before_agent_start')({}, ctx);
  hooks.get('session_before_switch')({}, ctx);
  hooks.get('session_switch')({}, ctx);
  hooks.get('session_shutdown')({}, ctx);
  assert.ok(aborts >= 5);
});

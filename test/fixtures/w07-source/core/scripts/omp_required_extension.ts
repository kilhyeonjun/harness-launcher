/** Required policy bridge, loaded by upstream OMP via --trusted-extension. No native/package imports.
 * Only the compiler emits copies. The bundle is verified once at load; launcher admission remains authority.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, lstatSync, realpathSync, accessSync, constants } from 'node:fs';
import { basename, dirname, resolve, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

type RecordValue = Record<string, any>;
type NativeToolResult = { toolName: string; toolCallId: string; input: RecordValue;
  content: ({ type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string })[];
  details?: unknown; isError: boolean };
type Context = { cwd: string; sessionManager: { getSessionId(): string }; abort(): void; shutdown(): void;
  ui?: { notify?(message: string, type?: 'info' | 'warning' | 'error'): void } };
type API = { on(event: string, handler: (event: RecordValue, context: Context) => any): void;
  appendEntry(type: string, value: unknown): void };
export type Services = {
  load(): RecordValue;
  run(hook: RecordValue, payload: RecordValue, signal: AbortSignal): Promise<{ code: number; stdout: string }>;
  transforms?: Record<string, (raw: RecordValue, signal: AbortSignal) => Promise<RecordValue>>;
};
const digest = (b: string | Buffer) => createHash('sha256').update(b).digest('hex');
const canonical = (value: any): string => JSON.stringify(sort(value));
function sort(value: any): any {
  if (Array.isArray(value)) return value.map(sort);
  if (object(value)) return Object.fromEntries(Object.keys(value).sort().map(k => [k, sort(value[k])]));
  return value;
}
const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value));
function freeze<T>(value: T): T {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze); Object.freeze(value);
  }
  return value;
}
// `detail` is a pre-formatted suffix (leading ' ' or ': '); it never carries hook stderr.
function requireValue(ok: unknown, reason: string, detail = ''): asserts ok {
  if (!ok) throw Object.assign(new Error(`OMP_REQUIRED_${reason}`), { detail });
}
const ADMISSION = 'OMP required policy admission failed';
const errorCode = (error: unknown) => /^OMP_REQUIRED_([A-Z0-9_]+)$/.exec((error as Error)?.message ?? '')?.[1] ?? 'INTERNAL';
function denial(error: unknown) {
  const code = errorCode(error);
  const detail = code === 'INTERNAL' ? '' : (error as any).detail ?? '';
  return { block: true, reason: `${ADMISSION}: ${code}${detail}` };
}
// Claude parity: a hook blocks only with exit 2 or an explicit deny decision.
const blocks = (error: unknown) => errorCode(error) === 'CANONICAL_DENY' || (error as any)?.exit === 2;
const CONTROL = /[\u0000-\u001f\u007f]/g;
const reasonText = (v: unknown) => canonical(typeof v === 'string' ? v.replace(CONTROL, '') : v).replace(CONTROL, '').slice(0, 300);
function object(value: unknown): value is RecordValue {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}
// Hook-supplied deny reason as a `: <json text>` suffix (empty when the output carries none).
function why(parsed: unknown) {
  if (!object(parsed)) return '';
  const d = object(parsed.hookSpecificOutput) ? parsed.hookSpecificOutput : parsed;
  const text = d.permissionDecisionReason ?? parsed.reason ?? parsed.stopReason ?? d.reason ?? parsed.error;
  return text === undefined ? '' : `: ${reasonText(text)}`;
}
type View = { name: string; input: RecordValue; cwd?: string; extra: RecordValue };
const GATE_ONLY = ['path', 'paths', '_path']; // native event input adds these to edit; never part of the view
const unset = (v: unknown) => v === undefined || v === null || v === false ||
  (typeof v === 'string' && !v.trim()) || (Array.isArray(v) && !v.length);
function absPath(cwd: string, p: unknown) {
  // The fork strips a leading '@' or ':' and maps a bare '/' to cwd; newlines split path lists. Refuse, never resolve.
  requireValue(typeof p === 'string' && !!p.trim() && !p.includes('\0') && !p.includes('\n') && !p.startsWith('~') &&
    !/^[@:]/.test(p) && p !== '/' && !/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(p), 'PATH_INPUT');
  return resolve(cwd, p);
}
const PASSIVE = ['wait', 'ask', 'todo', 'web_search', 'vibe_wait', 'vibe_list', 'vibe_kill'];
const AGENT = ['task', 'vibe_spawn', 'vibe_send'];
// Native `path` of the search tools may be a glob, a `;`/`,`/space list, a URL or carry a `:N-M` selector.
// The effect target is the search root: selector stripped, then the static prefix before the first glob segment.
// ponytail: a literal file name that ends in a selector-shaped ':12' is read as a selector; lists are refused, not split.
const SELECTOR = /(?::(?:raw|conflicts|img|[-+,\d]+))+$/i;
const GLOB_SEGMENT = /[*?[{]/;
function searchRoot(cwd: string, p: unknown) {
  absPath(cwd, p);
  const bare = (p as string).replace(SELECTOR, '');
  requireValue(!/["]|\{[^}]*\/[^}]*\}/.test(bare) && !/[;,\s]/.test(bare.replace(/\{[^}]*\}/g, '')), 'SEARCH_PATH_FORM');
  const segments = bare.split('/'), at = segments.findIndex(seg => GLOB_SEGMENT.test(seg));
  return absPath(cwd, at < 0 ? bare : segments.slice(0, at).join('/') || (bare.startsWith('/') ? '/' : '.'));
}
// Search tools by native schema: the pattern key, and the view-only keys that never change the target.
const SEARCH: Record<string, { pattern: string; view: string[] }> = {
  grep: { pattern: 'pattern', view: ['case', 'gitignore', 'skip'] },
  find: { pattern: 'query', view: ['grep_keywords'] },
  ast_grep: { pattern: 'pat', view: ['lang', 'skip'] },
};
const pick = (raw: RecordValue, keys: string[]) => Object.fromEntries(keys.filter(k => k in raw).map(k => [k, raw[k]]));
// Fail closed: only mapped tools/keys pass; everything else is refused, never guessed.
function semantic(tool: string, raw: RecordValue, ctx: Context, writeOps?: Map<string, string>, id?: string): View {
  const only = (native: string[], code = 'UNSUPPORTED_TOOL_MAPPING') =>
    requireValue(Object.keys(raw).every(k => native.includes(k) || GATE_ONLY.includes(k)), code);
  const search = (pattern: unknown, path: unknown, legacy: RecordValue = {}): View => {
    requireValue(typeof pattern === 'string' && !!pattern, 'SEARCH_INPUT');
    const target = path === undefined ? resolve(ctx.cwd) : searchRoot(ctx.cwd, path);
    return { name: 'Grep', input: { pattern, ...(path === undefined ? {} : { path: target }), ...legacy },
      extra: { effects: [{ kind: 'search', paths: [target] }] } };
  };
  if (AGENT.includes(tool)) return { name: tool, input: { ...raw }, extra: { effects: [{ kind: 'tool', name: tool, kind_detail: 'agent' }] } };
  if (PASSIVE.includes(tool)) return { name: tool, input: { ...raw }, extra: { effects: [{ kind: 'tool', name: tool, kind_detail: 'passive' }] } };
  if (tool === 'bash') {
    requireValue(typeof raw.command === 'string', 'BASH_INPUT');
    requireValue(Object.keys(raw).every(k => ['command', 'timeout', 'cwd', ...GATE_ONLY].includes(k) ||
      (['async', 'pty', 'name', 'ready'].includes(k) && unset(raw[k]))), 'UNSUPPORTED_BASH_SHAPE');
    requireValue(raw.timeout === undefined || (Number.isFinite(raw.timeout) && raw.timeout > 0), 'BASH_TIMEOUT');
    const cwd = unset(raw.cwd) ? ctx.cwd : absPath(ctx.cwd, raw.cwd);
    const timeout = raw.timeout === undefined ? {} : { timeout: raw.timeout };
    return { name: 'Bash', cwd, input: { command: raw.command, ...timeout },
      extra: { effects: [{ kind: 'exec', command: raw.command, cwd, ...timeout, background: false }] } };
  }
  if (tool === 'write') {
    only(['path', 'content'], 'WRITE_INPUT');
    requireValue(typeof raw.path === 'string' && typeof raw.content === 'string', 'WRITE_INPUT');
    const path = absPath(ctx.cwd, raw.path);
    // The op is fixed at Pre: after the write the file exists and Post would misreport an add.
    const op = (id && writeOps?.get(id)) || (existsSync(path) ? 'update' : 'add');
    if (id) writeOps?.set(id, op);
    return { name: 'Write', input: { file_path: path, content: raw.content },
      extra: { effects: [{ kind: 'file_change', path, op, after: raw.content, after_source: 'native', tool: 'write' }] } };
  }
  if (tool === 'read') {
    only(['path'], 'READ_INPUT');  // fork readSchema has only `path`; selectors ride inline
    requireValue(typeof raw.path !== 'string' || !/[;"]/.test(raw.path), 'READ_PATH_FORM');
    const path = absPath(ctx.cwd, typeof raw.path === 'string' ? raw.path.replace(SELECTOR, '') : raw.path);
    return { name: 'Read', input: { file_path: path }, extra: { effects: [{ kind: 'read', paths: [path] }] } };
  }
  if (SEARCH[tool]) {
    const { pattern, view } = SEARCH[tool];
    only([pattern, 'path', ...view]);
    return search(raw[pattern], raw.path, pick(raw, view));
  }
  if (tool === 'glob') { // native `path` holds the glob(s); there is no separate root key
    only(['path', 'hidden', 'gitignore', 'limit']);
    const target = raw.path === undefined ? resolve(ctx.cwd) : searchRoot(ctx.cwd, raw.path);
    return { name: 'Glob', input: { pattern: raw.path ?? '.', path: target, ...pick(raw, ['hidden', 'gitignore', 'limit']) },
      extra: { effects: [{ kind: 'search', paths: [target] }] } };
  }
  // Hashline edit (no upstream pre-write review hook), ast_edit, eval, github, lsp, mcp__* and the rest need their own adapter.
  throw new Error('OMP_REQUIRED_UNSUPPORTED_TOOL_MAPPING');
}
function rawInput(tool: string, normalized: RecordValue): RecordValue {
  requireValue(tool === 'bash', 'UNSUPPORTED_RAW_REWRITE');
  // Bash command is the only currently proven lossless rewrite adapter.
  requireValue(typeof normalized.command === 'string', 'RAW_INPUT');
  const raw: RecordValue = {};
  for (const k of ['command', 'timeout', 'cwd']) if (k in normalized) raw[k] = normalized[k];
  requireValue(Object.keys(normalized).every(k => ['command', 'timeout', 'cwd', ...GATE_ONLY].includes(k)), 'RAW_UNKNOWN_FIELD');
  return raw;
}
export function registerRequired(api: API, services: Services) {
  let manifest: RecordValue | undefined, ready = false, session = '', closed = false;
  let startupContext: string[] = [], promptContext: string[] = [], pendingPrompt: string | undefined;
  const observedResults = new Set<string>();
  const writeOps = new Map<string, string>();
  const deny = (error: unknown = new Error('OMP_REQUIRED_NOT_READY')) => denial(error);
  function clearContext() { startupContext = []; promptContext = []; pendingPrompt = undefined; }
  // Only a foreign session ends the session; every other failure is scoped to its event.
  function halt(ctx: Context) { ready = false; clearContext(); ctx.abort(); ctx.shutdown(); }
  function bound(ctx: Context) {
    requireValue(manifest && !closed, 'SESSION_BINDING');
    if (ctx.sessionManager.getSessionId() !== session) { halt(ctx); requireValue(false, 'SESSION_BINDING'); }
  }
  // Visible, durable notice. The receipt keeps only the code; hook-supplied reason text is shown, not persisted.
  function notice(ctx: Context, event: string, error: unknown, message = denial(error).reason) {
    try { api.appendEntry('harness-omp-notice', { event, code: errorCode(error) }); } catch {}
    try { ctx.ui?.notify?.(`${message} (${event})`, 'warning'); } catch {}
  }
  const skipper = (ctx: Context, event: string) => (error: unknown) => { notice(ctx, event, error); return true; };
  const claudeParity = (ctx: Context, event: string) => (error: unknown) => !blocks(error) && skipper(ctx, event)(error);
  async function deadline<T>(work: (signal: AbortSignal) => Promise<T>, milliseconds: number, parent?: AbortSignal): Promise<T> {
    const ctl = new AbortController(); let timer: ReturnType<typeof setTimeout>;
    let rejectParent: (error: Error) => void;
    const cancelled = new Promise<never>((_, reject) => { rejectParent = reject; });
    const cancel = () => { ctl.abort(); rejectParent(new Error('OMP_REQUIRED_ABORTED')); };
    if (parent?.aborted) throw new Error('OMP_REQUIRED_ABORTED');
    parent?.addEventListener('abort', cancel, { once: true });
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => { ctl.abort(); reject(new Error('OMP_REQUIRED_TIMEOUT')); }, milliseconds);
    });
    try { return await Promise.race([work(ctl.signal), timeout, cancelled]); }
    finally { clearTimeout(timer!); ctl.abort(); parent?.removeEventListener('abort', cancel); }
  }
  function payload(event: RecordValue, ctx: Context, kind: string, raw?: RecordValue) {
    const view = raw ? semantic(event.toolName, raw, ctx, writeOps, event.toolCallId) : undefined;
    return { hook_event_name: kind, session_id: session, tool_use_id: event.toolCallId,
      cwd: view?.cwd ?? ctx.cwd, tool_name: view?.name, tool_input: view?.input, ...view?.extra,
      is_error: event.isError, prompt: event.text };
  }
  async function one(hook: RecordValue, p: RecordValue, signal: AbortSignal) {
    const result = await deadline(s => services.run(hook, p, s),
      Math.min(hook.timeout_ms, Math.max(1, manifest!.bridge_total_timeout_ms)), signal);
    const output = result.stdout.trim();
    let parsed: any;
    try { parsed = JSON.parse(output); } catch { parsed = undefined; }
    if (result.code !== 0) throw Object.assign(new Error('OMP_REQUIRED_HOOK_NONZERO'),
      { detail: ` ${basename(hook.script)} exit=${result.code}${why(parsed)}`, exit: result.code });
    if (!output) return undefined;
    requireValue(object(parsed), 'HOOK_MALFORMED');
    const decision = parsed.hookSpecificOutput ?? parsed;
    requireValue(!('input' in parsed) && !('updatedInput' in decision), 'DECISION_REWRITE');
    requireValue(parsed.decision !== 'block' && parsed.continue !== false &&
      decision.permissionDecision !== 'deny' && !parsed.error, 'CANONICAL_DENY',
      why(parsed));
    if (decision.additionalContext === undefined) return undefined;
    requireValue(typeof decision.additionalContext === 'string', 'CONTEXT_SHAPE');
    return decision.additionalContext as string;
  }
  // `skip(error)` returning true drops that hook's result and continues; otherwise the error ends the event.
  async function hooks(kind: string, p: RecordValue, signal: AbortSignal, final = false, skip?: (error: unknown) => boolean) {
    const context: string[] = [];
    for (const hook of manifest!.hook_map.filter((h: RecordValue) => h.event === kind &&
      (!p.tool_name || new RegExp(`^(?:${h.matcher})$`).test(p.tool_name)))) {
      requireValue(!final || hook.decision_only, 'UNSUPPORTED_EFFECTFUL_RECHECK');
      requireValue(!signal.aborted, 'ABORTED');
      try {
        const text = await one(hook, p, signal);
        if (text !== undefined) context.push(text);
      } catch (error) { if (!skip?.(error)) throw error; }
    }
    return context;
  }
  // First registration is default-deny; no reads, imports or asynchronous setup above it.
  api.on('tool_call', async (event, ctx) => {
    if (!ready) return deny();
    try {
      return await deadline(async signal => {
        bound(ctx);
        requireValue(typeof event.toolCallId === 'string' && !!event.toolCallId && object(event.input), 'CALL_ID');
        const original = copy(event.input);
        const originalPayload = payload(event, ctx, 'PreToolUse', original);
        const context = await hooks('PreToolUse', originalPayload, signal);
        const transforms = manifest!.bridge_rewrites.filter((t: RecordValue) => t.tool === event.toolName);
        const passive = () => context.length ? { additionalContext: [...new Set(context)].join('\n') } : {};
        if (!transforms.length) return passive();
        let raw = rawInput(event.toolName, original);
        for (const transform of transforms) {
          requireValue(!!services.transforms?.[transform.canonical_entry_id], 'REWRITE_MISSING');
          raw = copy(await deadline(s => services.transforms![transform.canonical_entry_id](freeze(copy(raw)), s),
            transform.timeout_ms ?? manifest!.bridge_total_timeout_ms, signal));
          requireValue(object(raw) && !signal.aborted, 'REWRITE_MALFORMED');
          // Validate RAW, never return normalized path/paths gate-only fields.
          requireValue(Object.keys(raw).every(k => ['command', 'timeout', 'cwd'].includes(k)), 'REWRITE_RAW_SHAPE');
          semantic(event.toolName, raw, ctx);
        }
        context.push(...await hooks('PreToolUse', payload(event, ctx, 'PreToolUse', raw), signal, true));
        requireValue(!signal.aborted, 'ABORTED');
        return { input: freeze(copy(raw)), ...passive() };
      }, manifest!.bridge_total_timeout_ms);
    } catch (error) { writeOps.delete(event?.toolCallId); return deny(error); }
  });
  api.on('session_start', async (_event, ctx) => {
    ready = false; clearContext(); observedResults.clear(); writeOps.clear();
    try {
      manifest = freeze(copy(services.load()));
      requireValue(manifest.runtime === 'omp' && manifest.schema === 1 &&
        /^\d+\.\d+\.\d+$/.test(manifest.runtime_version), 'SCHEMA');
      requireValue(Number.isInteger(manifest.bridge_total_timeout_ms) && manifest.bridge_total_timeout_ms > 0 &&
        manifest.bridge_total_timeout_ms < 30000, 'BUDGET');
      session = ctx.sessionManager.getSessionId(); requireValue(!!session && !closed, 'IDENTITY');
      startupContext = await deadline(signal => hooks('SessionStart', payload({}, ctx, 'SessionStart'), signal),
        manifest.bridge_total_timeout_ms);
      ready = true;
      api.appendEntry('harness-omp-selection', { selection_sha256: manifest.effective_selection_sha256,
        profile: manifest.profile, session_id: session, skills: manifest.selected_skills.length,
        hooks: manifest.hook_map.length });
    } catch (error) {
      // Fail closed without killing the session: tools stay denied and the user is told why.
      ready = false; clearContext();
      notice(ctx, 'session_start', error, `${denial(error).reason}; every tool call is denied in this session`);
    }
  });
  api.on('input', async (event, ctx) => {
    pendingPrompt = undefined; promptContext = [];
    if (!ready) return {};
    try {
      bound(ctx);
      requireValue(event.source === 'interactive' && typeof event.text === 'string', 'UNSUPPORTED_PROMPT_MODE');
      promptContext = await deadline(signal => hooks('UserPromptSubmit', payload(event, ctx, 'UserPromptSubmit'), signal,
        false, claudeParity(ctx, 'input')), manifest!.bridge_total_timeout_ms);
      pendingPrompt = event.text;
      return {};
    } catch (error) {
      promptContext = [];
      if (!ready) return { handled: true }; // foreign session: already halted
      notice(ctx, 'input', error);
      // Block only this prompt on a canonical block or an unsupported prompt source; otherwise proceed.
      if (blocks(error) || errorCode(error) === 'UNSUPPORTED_PROMPT_MODE') return { handled: true };
      pendingPrompt = event.text;
      return {};
    }
  });
  api.on('before_agent_start', async (event, ctx) => {
    try {
      requireValue(ready, 'NOT_READY'); bound(ctx);
      if (pendingPrompt === undefined) requireValue(promptContext.length === 0, 'UNSUPPORTED_CONTEXT_REQUEST');
      if (pendingPrompt === undefined && !startupContext.length) return {};
      requireValue(typeof event.prompt === 'string' &&
        (pendingPrompt === undefined || event.prompt === pendingPrompt) &&
        Array.isArray(event.systemPrompt) &&
        event.systemPrompt.every((v: unknown) => typeof v === 'string'), 'UNSUPPORTED_CONTEXT_REQUEST');
      // Pinned native BeforeAgentStartEventResult.systemPrompt is per-request
      // policy, unlike a CustomMessagePayload which would persist raw context.
      const context = [...new Set([...startupContext, ...promptContext])];
      clearContext();
      return context.length ? { systemPrompt: [...event.systemPrompt, ...context] } : {};
    } catch (error) {
      clearContext();
      if (ready) notice(ctx, 'before_agent_start', error);
      return {};
    }
  });
  api.on('user_bash', async (event, ctx) => {
    try {
      requireValue(ready, 'NOT_READY');
      await deadline(async signal => {
        bound(ctx);
        await hooks('PreToolUse', payload({ toolName: 'bash' }, ctx, 'PreToolUse', { command: event.command }), signal);
      }, manifest!.bridge_total_timeout_ms);
      return undefined;
    } catch {
      // Native emitUserEvent returns this explicit replacement. Throwing would
      // be logged and permit the native fallback to execute the command.
      return { result: { output: 'OMP required policy denied this command', exitCode: 2, cancelled: true, truncated: false } };
    }
  });
  api.on('user_python', async (_event, _ctx) => ({ result: {
    output: 'OMP_REQUIRED_UNSUPPORTED_USER_PYTHON_MAPPING', exitCode: 2, cancelled: true, truncated: false,
  } }));
  api.on('resources_discover', async (_event, ctx) => {
    try {
      // Resources are discovered while native builds the session, before its
      // session_start event. Static loading never opens the tool readiness latch.
      if (!manifest) manifest = freeze(copy(services.load()));
      requireValue(!closed && manifest.schema === 1 && manifest.runtime === 'omp', 'RESOURCE_SELECTION');
      return { skillPaths: manifest!.selected_skills.map((s: RecordValue) => resolve(manifest!.bundle_dir, s.path)) };
    } catch (error) { notice(ctx, 'resources_discover', error); return { skillPaths: [] }; }
  });
  api.on('tool_result', async (event, ctx) => {
    if (!ready) return;
    try {
      bound(ctx);
      const result = event as NativeToolResult;
      requireValue(typeof result.toolCallId === 'string' && !!result.toolCallId && object(result.input) &&
        typeof result.isError === 'boolean' && Array.isArray(result.content) && result.content.every(c =>
          object(c) && ((c.type === 'text' && typeof c.text === 'string') ||
            (c.type === 'image' && typeof c.data === 'string' && typeof c.mimeType === 'string'))), 'POST_RESULT_SHAPE');
      requireValue(!observedResults.has(result.toolCallId), 'POST_RESULT_REPLAY');
      const kind = result.isError ? 'PostToolUseFailure' : 'PostToolUse';
      const p = payload(event, ctx, kind, result.input);
      p.tool_response = copy({ content: result.content, ...(result.details === undefined ? {} : { details: result.details }),
        isError: result.isError });
      observedResults.add(result.toolCallId); writeOps.delete(result.toolCallId);
      // Claude parity: Post hooks cannot undo the effect; a failing one is skipped and reported.
      await deadline(s => hooks(kind, p, s, false, skipper(ctx, 'tool_result')), manifest!.bridge_total_timeout_ms);
    } catch (error) { notice(ctx, 'tool_result', error); }
  });
  api.on('session_stop', async (event, ctx) => {
    if (!ready) return {};
    try {
      bound(ctx);
      await deadline(s => hooks('Stop', payload(event, ctx, 'Stop'), s, false, claudeParity(ctx, 'session_stop')),
        manifest!.bridge_total_timeout_ms);
      return {};
    } catch (error) { notice(ctx, 'session_stop', error); return blocks(error) ? deny(error) : {}; }
  });
  api.on('session_shutdown', async (event, ctx) => {
    ready = false; closed = true; clearContext(); observedResults.clear();
    try { if (manifest) await deadline(s => hooks('SessionEnd', payload(event, ctx, 'SessionEnd'), s), 1800); }
    catch { /* Past shutdown effects are not described as undone. */ }
  });
  return { isReady: () => ready };
}

function ownedRead(path: string) {
  requireValue(isAbsolute(path) && realpathSync(path) === path, 'PATH');
  for (let node = path; ; node = dirname(node)) {
    const s = lstatSync(node);
    requireValue(!s.isSymbolicLink() && (s.uid === process.getuid!() || s.uid === 0) && !(s.mode & 0o022), 'ACL');
    if (dirname(node) === node) break;
  }
  const s = lstatSync(path); requireValue(s.isFile() && s.nlink === 1, 'FILE');
  return readFileSync(path);
}
function dependencyRead(dependency: RecordValue) {
  const exactPython = dependency.name === 'python3' && dependency.path === '/usr/bin/python3' &&
    lstatSync(dependency.path).nlink >= 2;
  const path = exactPython ? dependency.path : realpathSync(dependency.path);
  const file = lstatSync(path);
  if (dependency.name !== 'python3' || dependency.path !== '/usr/bin/python3' || file.nlink === 1)
    return ownedRead(path);
  requireValue(
    path === dependency.path && file.isFile() && file.nlink >= 2 && (file.mode & 0o111) !== 0,
    'SYSTEM_PYTHON_EXEC',
  );
  for (let node = path; ; node = dirname(node)) {
    const s = lstatSync(node);
    requireValue(!s.isSymbolicLink() && s.uid === 0 && !(s.mode & 0o022), 'SYSTEM_PYTHON_OWNER');
    if (dirname(node) === node) break;
  }
  accessSync(path, constants.X_OK);
  return readFileSync(path);
}

async function runScript(path: string, args: string[], input: string, signal: AbortSignal, cwd: string, hookPath?: string, hookPython?: string, hookTuple = false) {
  return await new Promise<{ code: number; stdout: string }>((accept, reject) => {
    // No settings.env/global authority copy and no inherited Claude/Codex identity.
    const env: Record<string, string> = { HARNESS_HOOK_RUNTIME: 'omp' };
    for (const key of ['HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR']) if (process.env[key]) env[key] = process.env[key]!;
    // Launcher env v2 tuple: pass through only when the outer runner set it and the shape is valid; never synthesized.
    const tuple = hookTuple ? process.env : {} as NodeJS.ProcessEnv;  // hook children only, not rewrite helpers
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(tuple.HARNESS_SESSION_ID ?? ''))
      env.HARNESS_SESSION_ID = tuple.HARNESS_SESSION_ID!;
    for (const key of ['HARNESS_SOURCE_ROOT', 'HARNESS_SESSION_ROOT', 'HARNESS_RUN_DIR'])
      if (tuple[key] && isAbsolute(tuple[key]!)) env[key] = tuple[key]!;
    if (hookPath) env.PATH = hookPath;
    if (hookPython) env.HARNESS_PYTHON = hookPython; // Existing helper override; child only, exact sealed interpreter.
    const child = spawn(path, args, { cwd, env, signal, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const cancelGroup = () => { if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } };
    signal.addEventListener('abort', cancelGroup, { once: true });
    let stdout = '', size = 0;
    child.stdout.on('data', b => { size += b.length; if (size > 65536) { child.kill(); reject(new Error('OMP_REQUIRED_OUTPUT_CAP')); } else stdout += b; });
    child.stderr.resume(); // Never persist policy/prompt/auth-bearing child diagnostics.
    child.on('error', reject); child.on('close', code => {
      signal.removeEventListener('abort', cancelGroup); accept({ code: code ?? 1, stdout });
    });
    child.stdin.on('error', reject); child.stdin.end(input);
  });
}
export default function requiredExtension(api: API) {
  const bundleDir = dirname(fileURLToPath(import.meta.url));
  let loaded: RecordValue;
  let hookPath: string;
  let hookPython: string;
  function executionClosure(m: RecordValue) {
    const dependencies = m.hook_dependencies ?? [];
    if (!m.hook_map.length) return;
    requireValue(dependencies.length === 3 && ['bash', 'jq', 'python3'].every(name =>
      dependencies.filter((d: any) => d.name === name).length === 1), 'HOOK_DEPENDENCIES_MISSING');
    requireValue(dependencies.find((d: any) => d.name === 'bash').path === '/bin/bash', 'ACTUAL_BASH');
    for (const d of dependencies) {
      requireValue(isAbsolute(d.path) && digest(dependencyRead(d)) === d.sha256, 'HOOK_DEPENDENCY_CHANGED');
      const exactPython = d.name === 'python3' && d.path === '/usr/bin/python3' && lstatSync(d.path).nlink >= 2;
      const first = hookPath.split(':').map(dir => resolve(dir, d.name)).find(p => {
        try { accessSync(p, constants.X_OK); return lstatSync(exactPython && p === d.path ? p : realpathSync(p)).isFile(); } catch { return false; }
      });
      requireValue(first && (exactPython ? first === d.path : realpathSync(first) === realpathSync(d.path)),
        'HOOK_PATH_SHADOW');
    }
  }
  const transforms: NonNullable<Services['transforms']> = {};
  registerRequired(api, {
    load() {
      const manifestBytes = ownedRead(resolve(bundleDir, 'selection.json'));
      loaded = JSON.parse(manifestBytes.toString());
      const { artifacts, effective_selection_sha256, ...sealed } = loaded;
      requireValue(digest(canonical(sealed)) === effective_selection_sha256 &&
        bundleDir.endsWith('/' + effective_selection_sha256), 'SELECTION_HASH');
      requireValue(artifacts.some((a: any) => a.relative_path === 'policy.md') &&
        artifacts.some((a: any) => a.relative_path === 'required-extension.ts'), 'REQUIRED_ARTIFACT');
      for (const a of loaded.artifacts) {
        const p = resolve(bundleDir, a.relative_path);
        requireValue(relative(bundleDir, p) === a.relative_path && digest(ownedRead(p)) === a.sha256 &&
          (lstatSync(p).mode & 0o777) === parseInt(a.mode, 8), 'ARTIFACT');
      }
      // Several original guards deliberately return 0 when jq/python is absent.
      // Their prerequisite is therefore admission, never a guard-success fallback.
      const dependencies = loaded.hook_dependencies ?? [];
      hookPath = [...new Set(['python3', 'jq', 'bash'].flatMap(name =>
        dependencies.filter((d: any) => d.name === name).map((d: any) => dirname(d.path)))), '/usr/bin', '/bin'].join(':');
      executionClosure(loaded);
      hookPython = dependencies.find((d: any) => d.name === 'python3')?.path;
      for (const rewrite of loaded.bridge_rewrites) {
        transforms[rewrite.canonical_entry_id] = async (raw, signal) => {
          // Harness source may advance after load (root fast-forward); only ownership/ACL is rechecked.
          const path = resolve(loaded.source_root, rewrite.script);
          ownedRead(path);
          const result = await runScript('/bin/bash', [path], canonical(raw), signal, loaded.workspace, hookPath, hookPython);
          requireValue(result.code === 0, 'REWRITE_NONZERO');
          const parsed = JSON.parse(result.stdout);
          requireValue(object(parsed) && Object.keys(parsed).length === 1 && object(parsed.input), 'REWRITE_RESULT');
          return parsed.input;
        };
      }
      return { ...loaded, bundle_dir: bundleDir };
    },
    async run(h, p, signal) {
      const path = resolve(loaded.source_root, h.script);
      ownedRead(path);
      return await runScript('/bin/bash', [path], JSON.stringify(p), signal, p.cwd, hookPath, hookPython, true);
    },
    transforms,
  });
}

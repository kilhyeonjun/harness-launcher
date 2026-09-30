#!/usr/bin/env python3
"""Native user approval policy for externally visible Slack mutations.

No approval receipts are manufactured here: the runtime shows the exact MCP
arguments to the user on each call. App ids are private harness opt-ins.
"""
import copy
import json
import os
import re
import shlex
import sys
import tempfile

sys.dont_write_bytecode = True
MUTATIONS = (
    'send_message', 'schedule_message', 'delete_scheduled_message',
    'delete_message', 'complete_file_upload', 'create_canvas', 'edit_canvas',
    'delete_canvas', 'update_canvas', 'edit_message',
)


def slack_apps():
    ids = sorted(set(filter(None, os.environ.get('HARNESS_CODEX_SLACK_APPS', '').split(','))))
    enabled = set(filter(None, os.environ.get('HARNESS_CODEX_APPS_ALLOWLIST', '').split(',')))
    if any(not re.fullmatch(r'[A-Za-z0-9_-]+', app) for app in ids):
        raise ValueError('invalid HARNESS_CODEX_SLACK_APPS app id')
    if not set(ids) <= enabled:
        raise ValueError('HARNESS_CODEX_SLACK_APPS must be explicitly enabled in HARNESS_CODEX_APPS_ALLOWLIST')
    return ids


def codex_config():
    apps = slack_apps()
    if not apps:
        return {}
    result = {'approval_policy': 'on-request', 'approvals_reviewer': 'user', 'features.apps': True}
    for app in apps:
        result[f'apps.{app}.enabled'] = True
        result[f'apps.{app}.approvals_reviewer'] = 'user'
        result[f'apps.{app}.links'] = {}
        for mutation in MUTATIONS:
            for prefix in ('', 'slack_', 'slack_slack_'):
                result[f'apps.{app}.tools.{prefix}{mutation}.approval_mode'] = 'prompt'
    return result


def codex_argv(args):
    config = codex_config()
    if not config:
        return list(args)
    # A bypass flag has special parsing semantics; remove it, retain its broad
    # filesystem grant, and make approvals available for the Slack prompt.
    options = args[:args.index('--')] if '--' in args else args
    bypass = '--dangerously-bypass-approvals-and-sandbox' in options
    result = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == '--':
            result.extend(args[index:])
            break
        if arg in ('-a', '--ask-for-approval'):
            index += 2
            continue
        if arg == '--dangerously-bypass-approvals-and-sandbox' or arg.startswith('--ask-for-approval=') or (arg.startswith('-a') and len(arg) > 2):
            index += 1
            continue
        if arg == '--full-auto':
            result.extend(['-s', 'workspace-write'])
        else:
            result.append(arg)
        index += 1
    if bypass:
        config = {'sandbox_mode': 'danger-full-access', **config}
    tail = []
    if bypass:
        tail.extend(['-s', 'danger-full-access'])
    if 'app-server' not in options:
        tail.extend(['-a', 'on-request'])
    for key, value in config.items():
        tail.extend(['-c', key + '=' + json.dumps(value)])
    # Before an end-of-options marker, never inside the user's prompt string.
    pos = result.index('--') if '--' in result else len(result)
    return result[:pos] + tail + result[pos:]


def claude_settings(settings):
    result = copy.deepcopy(settings)
    ask = result.setdefault('permissions', {}).setdefault('ask', [])
    for mutation in MUTATIONS:
        for namespace in ('mcp__codex_apps__slack_slack_', 'mcp__slack__', 'mcp__slack__slack_', 'mcp__plugin_slack_slack__slack_'):
            tool = namespace + mutation
            if tool not in ask:
                ask.append(tool)
    return result


def merge_settings(base, extra):
    for key, value in extra.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            merge_settings(base[key], value)
        elif key in base and isinstance(base[key], list) and isinstance(value, list):
            base[key] += [item for item in value if item not in base[key]]
        else:
            base[key] = copy.deepcopy(value)


def claude_argv(args):
    result, settings = [], {}
    settings_position, from_file = None, False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == '--':
            result.extend(args[index:])
            break
        if arg == '--settings' or arg.startswith('--settings='):
            if settings_position is None:
                settings_position = len(result)
            if arg == '--settings':
                index += 1
                if index >= len(args):
                    raise ValueError('--settings requires a value')
                value = args[index]
            else:
                value = arg.split('=', 1)[1]
            if value.lstrip().startswith('{'):
                extra = json.loads(value)
            else:
                from_file = True
                with open(value, encoding='utf-8') as file:
                    extra = json.load(file)
            if not isinstance(extra, dict):
                raise ValueError('--settings requires a JSON object')
            merge_settings(settings, extra)
        else:
            result.append(arg)
        index += 1
    serialized = json.dumps(claude_settings(settings), separators=(',', ':'))
    if from_file:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', prefix='harness-slack-settings-', suffix='.json', delete=False) as file:
            os.fchmod(file.fileno(), 0o600)
            file.write(serialized)
            value = file.name
    else:
        value = serialized
    tail = ['--settings', value]
    pos = settings_position if settings_position is not None else 0
    return result[:pos] + tail + result[pos:]


def main():
    mode = sys.argv[1]
    if mode == 'claude':
        print(json.dumps(claude_settings(json.loads(sys.argv[2] or '{}')), separators=(",", ":")))
    elif mode == 'claude-argv':
        args = claude_argv(sys.argv[2:])
        value = args[args.index('--settings') + 1]
        temporary = value if os.path.basename(value).startswith('harness-slack-settings-') else ''
        print('HARNESS_SLACK_SETTINGS_FILE=' + shlex.quote(temporary) + '; HARNESS_SLACK_ARGV=(' + shlex.join(args) + ')')
    elif mode == 'argv':
        print(shlex.join(codex_argv(sys.argv[2:])))
    elif mode == 'app-toml':
        print('approvals_reviewer = \"user\"')
        for mutation in MUTATIONS:
            for prefix in ('', 'slack_', 'slack_slack_'):
                print(f'[apps.{sys.argv[2]}.tools.{prefix}{mutation}]\napproval_mode = \"prompt\"')
    elif mode == 'toml':
        for key, value in codex_config().items():
            # Native approvals are runtime-level scalars; emitted before tables.
            print(key + '=' + json.dumps(value))
    else:
        raise ValueError('unknown Slack approval policy mode')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError) as exc:
        print(f'harness-launcher: {exc}', file=sys.stderr)
        sys.exit(2)

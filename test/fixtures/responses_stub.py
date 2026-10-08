"""Minimal OpenAI Responses API stub for harness-headless tests.

usage: responses_stub.py <dir>

Serves 127.0.0.1 on a random port and writes it to <dir>/port. GET /v1/models
answers one model. POST /v1/responses streams SSE and scripts one turn by how
many tool outputs the request input already holds: first an apply_patch
custom tool call with <dir>/patch (when that file exists), then the shell tool
codex offered (exec_command when it lists no tools) with <dir>/command, then
the answer <dir>/final (default "stub done"). Every request is appended to
<dir>/requests.jsonl as {method, path, authorization, cookie, headers (all
lower-case names), keys (body keys), model, tools, outputs (tool outputs)} so
tests can check what the forwarder sent upstream and what the tools printed.
<dir>/redirect makes every answer a 302; <dir>/delay (seconds) spaces the SSE
events.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
OUTPUTS = ('function_call_output', 'custom_tool_call_output')


def read(name, default=''):
    try:
        with open(os.path.join(DIR, name)) as f:
            return f.read()
    except OSError:
        return default


def shell_call(tools, command):
    """A function_call item for the shell-like tool codex offered."""
    names = [t.get('name') for t in tools if isinstance(t, dict)]
    if 'exec_command' in names or not names:
        name, arguments = 'exec_command', {'cmd': command}
    elif 'shell_command' in names:
        name, arguments = 'shell_command', {'command': command}
    else:
        name, arguments = 'shell', {'command': ['bash', '-lc', command]}
    return {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_shell', 'name': name,
            'arguments': json.dumps(arguments)}


def next_item(body):
    """The scripted output item for this request."""
    items = [i for i in body.get('input') or [] if isinstance(i, dict)]
    done = sum(1 for i in items if i.get('type') in OUTPUTS)
    steps = []
    if os.path.exists(os.path.join(DIR, 'patch')):
        steps.append({'type': 'custom_tool_call', 'id': 'ctc_1', 'call_id': 'call_patch', 'name': 'apply_patch',
                      'input': read('patch')})
    steps.append(shell_call(body.get('tools') or [], read('command', 'true')))
    if done < len(steps):
        return steps[done]
    return {'type': 'message', 'role': 'assistant', 'id': 'msg_1',
            'content': [{'type': 'output_text', 'text': read('final', 'stub done')}]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self, body):
        items = [i for i in body.get('input') or [] if isinstance(i, dict)]
        entry = {'method': self.command, 'path': self.path,
                 'authorization': self.headers.get('Authorization'), 'cookie': self.headers.get('Cookie'),
                 'headers': sorted({k.lower() for k in self.headers.keys()}), 'keys': sorted(body),
                 'model': body.get('model'), 'tools': [t.get('name') or t.get('type') for t in body.get('tools') or []],
                 'outputs': [str(i.get('output')) for i in items if i.get('type') in OUTPUTS]}
        with open(os.path.join(DIR, 'requests.jsonl'), 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def redirected(self):
        if not os.path.exists(os.path.join(DIR, 'redirect')):
            return False
        self.send_response(302)
        self.send_header('Location', 'http://example.invalid/')
        self.send_header('Content-Length', '0')
        self.end_headers()
        return True

    def do_GET(self):
        self.record({})
        if self.redirected():
            return
        data = json.dumps({'object': 'list', 'data': [{'id': read('model', 'stub-model').strip(), 'object': 'model'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
        self.record(body)
        if self.redirected():
            return
        events = [
            {'type': 'response.created', 'response': {'id': 'resp_1'}},
            {'type': 'response.output_item.done', 'item': next_item(body)},
            {'type': 'response.completed', 'response': {'id': 'resp_1', 'usage': {
                'input_tokens': 11, 'input_tokens_details': None, 'output_tokens': 7,
                'output_tokens_details': None, 'total_tokens': 18}}},
        ]
        delay = float(read('delay', '0') or 0)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for n, event in enumerate(events):
            if n:
                time.sleep(delay)
            self.wfile.write(f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n'.encode())
            self.wfile.flush()


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(DIR, 'port.tmp'), 'w') as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, 'port.tmp'), os.path.join(DIR, 'port'))
server.serve_forever()

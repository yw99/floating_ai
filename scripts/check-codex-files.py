#!/usr/bin/env python3
"""Check per-note attachment tools with Codex 0.163 and the bundled reader.

Usage: python3 scripts/check-codex-files.py /path/to/codex /path/to/FloatingAIFileTool
Uses temporary CODEX_HOME, synthetic files, and a loopback mock provider only.
No credentials, user histories, or paid API requests are used. Original fixtures
and unrelated-note files must stay unchanged; the fixed helper denies escapes.
"""

import argparse
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location("profile", Path(__file__).with_name("check-codex-profile.py"))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
require = profile.require


class Client(profile.Client):
    def request(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + profile.TIMEOUT
        while True:
            message = self._next(deadline)
            if message.get("id") == request_id and "method" not in message:
                require("error" not in message, method + ": " + json.dumps(message.get("error")))
                return message["result"]
            self._notification(message)


class FileCaptureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length <= profile.MAX_BODY and self.path == "/v1/responses", "Unexpected mock request")
            require(not self.headers.get("Authorization"), "Unexpected credential header")
            body = json.loads(self.rfile.read(length))
            self.server.captures.append(body)
            call = self.server.next_tool
            self.server.next_tool = None
            output = [] if call is None else [{"type": "function_call", "id": "fc_offline",
                "call_id": "call_offline", "namespace": call[0], "name": "read_attachment",
                "arguments": json.dumps({"path": str(call[1])}), "status": "completed"}]
            response = {"id": "resp_offline", "object": "response", "created_at": 1,
                "status": "completed", "model": profile.MODEL, "output": output,
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
            events = [("response.created", {"response": dict(response, status="in_progress", output=[])})]
            if output:
                events.append(("response.output_item.done", {"output_index": 0, "item": output[0]}))
            events.append(("response.completed", {"response": response}))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for name, value in events:
                self.wfile.write(("event: " + name + "\ndata: " + json.dumps(dict(value, type=name)) + "\n\n").encode())
            self.wfile.flush()
        except Exception as error:
            self.server.errors.append(type(error).__name__ + ": " + str(error))
            self.close_connection = True


def run(executable, helper):
    launch, thread_config, instructions, _ = profile.read_profile()
    with tempfile.TemporaryDirectory(prefix="floating-ai-files-") as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        home, workspace = root / "codex", root / "workspace"
        first, second, scratch_a, scratch_b = (root / name for name in ("first", "second", "scratch-a", "scratch-b"))
        for path in (home, workspace, first, second, scratch_a, scratch_b):
            path.mkdir()
        first_file = first / (str(uuid.uuid4()) + ".txt")
        second_file = second / (str(uuid.uuid4()) + ".txt")
        outside = root / (str(uuid.uuid4()) + ".txt")
        first_file.write_text("FIRST NOTE CANARY")
        second_file.write_text("SECOND NOTE CANARY")
        outside.write_text("OUTSIDE CANARY")
        linked = first / (str(uuid.uuid4()) + ".txt")
        linked.symlink_to(second_file)
        expected = {path: path.read_bytes() for path in (first_file, second_file, outside)}
        server = ThreadingHTTPServer(("127.0.0.1", 0), FileCaptureHandler)
        server.daemon_threads = True
        server.captures, server.errors, server.next_tool = [], [], None
        cleanup.callback(server.server_close)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        cleanup.callback(server_thread.join, 5)
        cleanup.callback(server.shutdown)
        endpoint = "http://127.0.0.1:%d/v1" % server.server_port
        provider = ['model_provider="capture"', 'model_providers.capture.name="Offline capture"',
                    'model_providers.capture.base_url=' + json.dumps(endpoint),
                    'model_providers.capture.wire_api="responses"',
                    'model_providers.capture.requires_openai_auth=false',
                    'model_providers.capture.supports_websockets=false',
                    'model_providers.capture.request_max_retries=0',
                    'model_providers.capture.stream_max_retries=0',
                    'cli_auth_credentials_store="ephemeral"', 'analytics.enabled=false']
        arguments = [executable, "app-server", "--listen", "stdio://"]
        for value in launch + provider:
            arguments.extend(["-c", value])
        environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        environment["CODEX_HOME"] = str(home)
        names = ["fa_files_" + uuid.uuid4().hex for _ in range(2)]

        def params(name=None, directory=None, scratch=None):
            config = dict(thread_config)
            config.update({"mcp_servers." + item: {"enabled": False, "command": "/usr/bin/false", "args": []} for item in names})
            if name:
                config["mcp_servers." + name] = {
                    "command": helper, "args": ["--mcp", "--root", str(directory), "--scratch", str(scratch)],
                    "cwd": str(directory), "enabled": True, "required": True,
                    "env": {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"}, "env_vars": [],
                    "enabled_tools": ["read_attachment"], "tools": {"read_attachment": {"approval_mode": "approve"}}, "startup_timeout_sec": 15, "tool_timeout_sec": 35}
            return {"cwd": str(workspace), "baseInstructions": instructions, "developerInstructions": "",
                    "approvalPolicy": "never", "sandbox": "read-only", "config": config, "runtimeWorkspaceRoots": []}

        def inventory(client, thread_id, name):
            result = client.request("mcpServerStatus/list", {"threadId": thread_id, "serverName": name})
            require(len(result["data"]) == 1, "Expected exactly one app-owned reader")
            entry = result["data"][0]
            require(entry["name"] == name and entry["runtimeStatus"] == "connected" and
                    set(entry["tools"]) == {"read_attachment"} and not entry.get("toolsError"),
                    "The scoped attachment reader was not ready")

        def read(client, thread_id, name, path, expected_text=None):
            response = client.request("mcpServer/tool/call", {"threadId": thread_id, "server": name,
                "tool": "read_attachment", "arguments": {"path": str(path)}})
            result = response.get("result", response)
            if expected_text is None:
                require(result.get("isError") is True, "Reader accepted a path outside its note")
                require("SECOND NOTE CANARY" not in json.dumps(result) and "OUTSIDE CANARY" not in json.dumps(result),
                        "Reader disclosed content outside its note")
            else:
                require(not result.get("isError") and expected_text in json.dumps(result), "Reader did not return its own file")

        def turn(client, thread_id, name=None, tool_path=None):
            before = len(server.captures)
            if tool_path:
                server.next_tool = ("mcp__" + name, tool_path)
            result = client.request("turn/start", {"threadId": thread_id,
                "input": [{"type": "text", "text": "Offline attachment profile check."}],
                "model": profile.MODEL, "effort": "medium", "cwd": str(workspace), "environments": [],
                "runtimeWorkspaceRoots": [], "approvalPolicy": "never",
                "sandboxPolicy": {"type": "readOnly", "networkAccess": False}})
            client.wait_for_turn(thread_id, result["turn"]["id"])
            captures = server.captures[before:]
            require(len(captures) == (2 if tool_path else 1) and not server.errors, "Unexpected mock response exchange")
            if tool_path:
                outputs = [item for item in captures[-1].get("input", []) if item.get("type") == "function_call_output"]
                require(any(item.get("call_id") == "call_offline" and "FIRST NOTE CANARY" in json.dumps(item) for item in outputs),
                        "The model's attachment call did not receive the reader result: " + json.dumps(outputs))
            if name is None:
                profile.check_tools(captures, server)
            else:
                tools = captures[0]["tools"]
                namespaces = [tool for tool in tools if tool.get("type") == "namespace"]
                require(len(namespaces) == 1 and namespaces[0]["name"] == "mcp__" + name,
                        "A note advertised another note's reader")
                require({tool["name"] for tool in namespaces[0].get("tools", [])} == {"read_attachment"},
                        "Unexpected attachment tool")
                allowed = {"request_user_input", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"}
                require(all(tool.get("type") in ("web_search", "namespace") or
                            (tool.get("type") == "function" and tool.get("name") in allowed) for tool in tools),
                        "Shell or another unexpected tool was advertised")
            return result["turn"]["id"]

        client = Client(arguments, environment, workspace)
        try:
            version = client.initialize()
            require(version.startswith("0.163."), "File tools require verified Codex 0.163")
            config = client.request("config/read", {"includeLayers": False})["config"]
            require(config["model_provider"] == "capture" and config["model_providers"]["capture"]["base_url"] == endpoint,
                    "The isolated mock provider was not applied")
            first_id = client.request("thread/start", dict(params(names[0], first, scratch_a),
                model=profile.MODEL, environments=[], dynamicTools=[], historyMode="legacy"))["thread"]["id"]
            second_id = client.request("thread/start", dict(params(names[1], second, scratch_b),
                model=profile.MODEL, environments=[], dynamicTools=[], historyMode="legacy"))["thread"]["id"]
            inventory(client, first_id, names[0]); inventory(client, second_id, names[1])
            first_turn = turn(client, first_id, names[0], first_file); turn(client, second_id, names[1])
            read(client, first_id, names[0], first_file, "FIRST NOTE CANARY")
            read(client, second_id, names[1], second_file, "SECOND NOTE CANARY")
            for path in (second_file, outside, linked, first / ".." / "second" / second_file.name):
                read(client, first_id, names[0], path)
            print("PASS native MCP: each note reads only its own files; sibling, outside and symlink reads denied.", flush=True)
            client.request("thread/read", {"threadId": first_id, "includeTurns": True})
            client.request("thread/unsubscribe", {"threadId": first_id})
            client.request("thread/resume", dict(params(), threadId=first_id))
            turn(client, first_id)
            read(client, second_id, names[1], second_file, "SECOND NOTE CANARY")
            client.request("thread/unsubscribe", {"threadId": first_id})
            client.request("thread/resume", dict(params(names[0], first, scratch_a), threadId=first_id))
            inventory(client, first_id, names[0]); turn(client, first_id, names[0])
            print("PASS scope changes: same thread ID restored; no-reader chat has no local tools; other note unaffected.", flush=True)
        finally:
            client.close()
        client = Client(arguments, environment, workspace)
        try:
            client.initialize()
            response = client.request("thread/resume", dict(params(names[0], first, scratch_a), threadId=first_id))
            require(response["thread"]["id"] == first_id, "Thread identity changed after restart")
            history = client.request("thread/read", {"threadId": first_id, "includeTurns": True})
            require(any(item["id"] == first_turn for item in history["thread"]["turns"]), "History was not restored")
            inventory(client, first_id, names[0]); turn(client, first_id, names[0])
            read(client, first_id, names[0], first_file, "FIRST NOTE CANARY")
            read(client, first_id, names[0], second_file)
        finally:
            client.close()
        require(not (home / "auth.json").exists(), "Unexpected authentication file")
        require(all(path.read_bytes() == data for path, data in expected.items()), "An original fixture was modified")
        print("PASS restart: original thread/history/scope retained; fixtures unchanged; no paid requests or real credentials.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("codex"); parser.add_argument("helper")
    args = parser.parse_args()
    executable = shutil.which(os.path.expanduser(args.codex))
    helper = shutil.which(os.path.expanduser(args.helper))
    require(executable is not None and helper is not None, "Codex and the bundled file reader must be executable")
    run(str(Path(executable).resolve()), str(Path(helper).resolve()))


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        raise SystemExit("FAIL: " + str(error))

#!/usr/bin/env python3
"""Check the installed Codex chat profile against a local mock Responses server.

Usage: python3 scripts/check-codex-profile.py /absolute/path/to/codex

This uses no login, real credentials, user conversations, or paid model requests.
It creates an isolated temporary CODEX_HOME and a provider pointing only at the
mock server on 127.0.0.1. It checks advertised tools and legacy history recovery;
it does not prove model quality, actual web search, or full sandbox isolation.
Only the detected CLI version is tested, not arbitrary future versions.
Requires Python 3.9+ and permission to bind a loopback socket.
"""

import argparse
from collections import deque
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time


TIMEOUT = 40
MAX_BODY = 8 * 1024 * 1024
MODEL = "gpt-5.4"
SOURCE = Path(__file__).resolve().parents[1] / "Sources/FloatingAICore/CodexClient.swift"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def swift_collection(source, marker):
    """Read a literal Swift collection, failing if its structure changes.

    The production string arrays and JSONValue dictionary use JSON-compatible
    literals. Counting brackets outside strings handles embedded `notify=[]`
    and nested empty arrays without silently truncating the copied profile.
    """
    require(source.count(marker) == 1, "Cannot locate unique profile marker: " + marker)
    start = source.index(marker) + len(marker) - 1
    depth, quoted, escaped = 0, False, False
    for index in range(start, len(source)):
        char = source[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise RuntimeError("Unterminated profile collection: " + marker)


def read_profile():
    source = SOURCE.read_text(encoding="utf-8")
    disabled = json.loads(swift_collection(source, "private static let disabledFeatures = ["))
    launch = json.loads(swift_collection(source, "var config = ["))
    literal = swift_collection(source, "var config: [String: JSONValue] = [")
    thread = json.loads("{" + literal[1:-1] + "}")
    instructions = re.search(r'private static let chatInstructions = """\n(.*?)\n\s*"""', source, re.S)
    require(instructions is not None, "Cannot read production chat instructions")
    require(disabled and all(re.fullmatch(r"[a-z0-9_]+", item) for item in disabled),
            "Unexpected disabled feature list")
    require(all(isinstance(item, str) for item in launch), "Unexpected launch profile")
    launch.extend("features." + feature + "=false" for feature in disabled)
    thread.update({"features." + feature: False for feature in disabled})
    return launch, thread, textwrap.dedent(instructions.group(1)).strip(), disabled


class CaptureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), CaptureHandler)
        self.captures = []
        self.errors = []


class CaptureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Never log request bodies or headers.

    def do_POST(self):
        self.connection.settimeout(5)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length <= MAX_BODY, "Unexpected mock request body size")
            require(self.path == "/v1/responses", "Unexpected mock endpoint")
            require(not self.headers.get("Authorization"), "Unexpected credential header")
            body = json.loads(self.rfile.read(length))
            self.server.captures.append(body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            response = {"id": "resp_offline", "object": "response", "created_at": 1,
                        "status": "completed", "model": MODEL, "output": [],
                        "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
            for name, value in [("response.created", dict(response, status="in_progress")),
                                ("response.completed", response)]:
                event = {"type": name, "response": value}
                self.wfile.write(("event: " + name + "\ndata: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        except Exception as error:
            self.server.errors.append(type(error).__name__ + ": " + str(error))
            self.close_connection = True


class Client:
    def __init__(self, arguments, environment, workspace):
        self.process = subprocess.Popen(arguments, cwd=workspace, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                        start_new_session=True)
        self.messages = queue.Queue()
        self.events = deque()
        self.next_id = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(RuntimeError("Invalid JSONL from Codex: " + type(error).__name__))
        finally:
            self.messages.put(RuntimeError("Codex closed stdout"))

    def _next(self, deadline):
        try:
            value = self.messages.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty:
            raise RuntimeError("Timed out waiting for Codex") from None
        if isinstance(value, Exception):
            raise value
        return value

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + TIMEOUT
        while True:
            message = self._next(deadline)
            if message.get("id") == request_id and "method" not in message:
                require("error" not in message, method + " returned a protocol error")
                return message["result"]
            self._notification(message)

    def _notification(self, message):
        if "id" in message and "method" in message:
            # The mock emits no tool calls. A server request is unexpected and
            # receives no permission to execute before the process is stopped.
            self.send({"id": message["id"], "error": {"code": -32601,
                       "message": "Offline profile probe does not permit client requests"}})
            raise RuntimeError("Unexpected server request: " + message["method"])
        self.events.append(message)

    def initialize(self):
        result = self.request("initialize", {
            "clientInfo": {"name": "floating_ai_profile_check", "version": "1"},
            "capabilities": {"experimentalApi": True}})
        self.send({"method": "initialized"})
        agent = result.get("userAgent", "")
        match = re.search(r"\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", agent)
        require(match is not None, "Codex did not report a version")
        return match.group(0)

    def wait_for_turn(self, thread_id, turn_id):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            if not self.events:
                self._notification(self._next(deadline))
            event = self.events.popleft()
            params = event.get("params", {})
            if (event.get("method") == "turn/completed" and params.get("threadId") == thread_id
                    and params.get("turn", {}).get("id") == turn_id):
                require(params["turn"].get("status") == "completed", "Mock turn did not complete")
                return
        raise RuntimeError("Timed out waiting for turn completion")

    def close(self):
        # Also stop descendants if startup created a host process. The child is
        # in its own process group; no terminal/IDE Codex process is signaled.
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=5)
        self.process.stdin.close()
        self.reader.join(timeout=5)
        self.process.stdout.close()


def check_tools(requests, server):
    require(not server.errors, "Mock server failure: " + "; ".join(server.errors))
    require(len(requests) == 1, "Expected exactly one mock request for this turn")
    tools = requests[0].get("tools", [])
    require(isinstance(tools, list) and tools, "Missing advertised tools")
    require(any(tool.get("type") == "web_search" for tool in tools), "Native web search is missing")
    for tool in tools:
        allowed = tool.get("type") == "web_search" or (
            tool.get("type") == "function" and tool.get("name") == "request_user_input")
        require(allowed, "Unexpected tool: " + json.dumps({
            "type": tool.get("type"), "name": tool.get("name")}))
    return [tool.get("name", tool.get("type")) for tool in tools]


def run(executable):
    launch, thread_config, instructions, disabled = read_profile()
    with tempfile.TemporaryDirectory(prefix="floating-ai-profile-") as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        home, workspace = root / "codex", root / "workspace"
        home.mkdir()
        workspace.mkdir()
        server = CaptureServer()
        cleanup.callback(server.server_close)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        cleanup.callback(server_thread.join, 5)
        cleanup.callback(server.shutdown)
        mock_endpoint = "http://127.0.0.1:%d/v1" % server.server_port
        provider = ["model_provider=\"capture\"", "model_providers.capture.name=\"Offline capture\"",
                    'model_providers.capture.base_url="' + mock_endpoint + '"',
                    'model_providers.capture.wire_api="responses"',
                    "model_providers.capture.requires_openai_auth=false",
                    "model_providers.capture.supports_websockets=false",
                    "model_providers.capture.request_max_retries=0",
                    "model_providers.capture.stream_max_retries=0",
                    'cli_auth_credentials_store="ephemeral"', "analytics.enabled=false"]
        arguments = [executable, "app-server", "--listen", "stdio://"]
        for value in launch + provider:
            arguments.extend(["-c", value])
        # Use an allowlist, not inherited credentials, proxies, or endpoint
        # overrides. HOME retains its real meaning; CODEX_HOME isolates Codex.
        environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL")
                       if key in os.environ}
        environment["CODEX_HOME"] = str(home)
        common = {"cwd": str(workspace), "baseInstructions": instructions, "developerInstructions": "",
                  "approvalPolicy": "never", "sandbox": "read-only", "config": thread_config,
                  "runtimeWorkspaceRoots": []}
        thread_id, first_turn, version = None, None, None
        for stage in ("fresh", "resumed"):
            client = Client(arguments, environment, workspace)
            try:
                detected = client.initialize()
                if version is None:
                    version = detected
                    print("Testing installed Codex " + version + " with an offline mock provider.", flush=True)
                require(detected == version, "CLI version changed during the check")
                config = client.request("config/read", {"includeLayers": False})["config"]
                require(config.get("model_provider") == "capture", "Mock provider override was not applied")
                effective = config.get("model_providers", {}).get("capture", {})
                require(effective.get("base_url") == mock_endpoint and
                        effective.get("requires_openai_auth") is False,
                        "The mock provider must use loopback without OpenAI authentication")
                require(not any(effective.get(key) for key in ("env_key", "http_headers",
                            "env_http_headers", "experimental_bearer_token")),
                        "The mock provider must not inherit credentials or headers")
                require(config.get("cli_auth_credentials_store") == "ephemeral", "Credential isolation was not applied")
                require(config.get("web_search") == "live", "Live search override was not applied")
                require(all(config.get("features", {}).get(feature) is False for feature in disabled),
                        "A disabled feature override was not applied")
                if stage == "fresh":
                    result = client.request("thread/start", dict(common, model=MODEL,
                        environments=[], dynamicTools=[], historyMode="legacy"))
                    thread_id = result["thread"]["id"]
                    require(result["thread"].get("environments") == [], "Fresh thread has environment access")
                else:
                    result = client.request("thread/resume", dict(common, threadId=thread_id))
                    restored = client.request("thread/read", {"threadId": thread_id, "includeTurns": True})
                    require(any(turn.get("id") == first_turn for turn in restored["thread"].get("turns", [])),
                            "The first turn was not restored from legacy history")
                    # Resume may report the default local environment. The
                    # explicit empty environments on each turn must disable it.
                require(result["thread"]["id"] == thread_id, "Thread identity changed")
                require(result["thread"].get("historyMode") == "legacy", "Legacy history mode was not retained")
                before = len(server.captures)
                result = client.request("turn/start", {
                    "threadId": thread_id, "input": [{"type": "text", "text": "Offline profile check."}],
                    "model": MODEL, "effort": "medium", "cwd": str(workspace), "environments": [],
                    "runtimeWorkspaceRoots": [], "approvalPolicy": "never",
                    "sandboxPolicy": {"type": "readOnly", "networkAccess": False}})
                turn_id = result["turn"]["id"]
                if first_turn is None:
                    first_turn = turn_id
                client.wait_for_turn(thread_id, turn_id)
                names = check_tools(server.captures[before:], server)
                require(not (home / "auth.json").exists(), "Unexpected auth.json was created")
                print("PASS " + stage + ": legacy history; advertised tools = " + ", ".join(names), flush=True)
            finally:
                client.close()
            require(not (home / "auth.json").exists(), "Unexpected auth.json exists after shutdown")
        print("PASS Codex " + version + ": no real credentials or paid model requests; temporary data removed on exit.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("codex", help="Path to the installed Codex executable")
    args = parser.parse_args()
    candidate = os.path.expanduser(args.codex)
    executable = shutil.which(candidate)
    require(executable is not None, "Codex executable was not found: " + candidate)
    run(str(Path(executable).resolve()))


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)

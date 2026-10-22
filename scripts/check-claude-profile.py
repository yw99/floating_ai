#!/usr/bin/env python3
"""Exercise the production Claude profile against a local mock Messages API.

Usage: python3 scripts/check-claude-profile.py /absolute/path/to/claude

Uses an isolated CLAUDE_CONFIG_DIR, a deliberately fake API key, synthetic
messages and a server bound to 127.0.0.1. No real login or paid model request is
used. Checks tool exclusions, image input, literal @paths, stream interruption,
model/effort controls and native transcript resume. It does not verify real
account access, real web search or model quality, or prove OS-level isolation.
Only the exact installed CLI version is tested. Requires Python 3.9+ and
permission to bind a loopback socket.
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
import unicodedata
import uuid


TIMEOUT = 30
FAKE_KEY = "floating-ai-offline-profile-test"
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jwioAAAAASUVORK5CYII="
SOURCE = Path(__file__).resolve().parents[1] / "Sources/FloatingAICore/ClaudeClient.swift"
WEB_TOOLS = {"WebFetch", "WebSearch"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_profile():
    """Load the actual production arguments rather than a copied profile."""
    source = SOURCE.read_text(encoding="utf-8")
    match = re.search(r"static let chatProfileArguments(?:\s*:\s*\[String\])?\s*=\s*(\[)", source)
    require(match is not None, "Cannot locate production chatProfileArguments")
    start = match.start(1)
    depth, quoted, escaped = 0, False, False
    for end in range(start, len(source)):
        char = source[end]
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
                # Swift permits a trailing comma; JSON does not.
                literal = re.sub(r",\s*]$", "]", source[start:end + 1])
                profile = json.loads(literal)
                require(all(isinstance(item, str) for item in profile), "Nonliteral Claude profile")
                require("--bare" not in profile, "Bare mode would disable existing Claude OAuth")
                instructions = re.search(r'private static let instructions = """\n(.*?)\n\s*"""', source, re.S)
                require(instructions is not None, "Cannot read production chat instructions")
                return profile + ["--system-prompt", textwrap.dedent(instructions.group(1)).strip()]
    raise RuntimeError("Unterminated production Claude profile")


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, workspace):
        super().__init__(("127.0.0.1", 0), MockHandler)
        self.workspace = workspace
        self.captures = []
        self.errors = []
        self.mode = "hostile"
        self.stream_started = threading.Event()
        self.release_stream = threading.Event()


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Never print headers, credentials or messages.

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        try:
            self.connection.settimeout(5)
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length < 8 * 1024 * 1024, "Unexpected mock body size")
            require(self.path.split("?")[0] == "/v1/messages", "Unexpected mock endpoint")
            require(self.headers.get("X-Api-Key") == FAKE_KEY, "Unexpected API credential")
            require(not self.headers.get("Authorization"), "Unexpected OAuth credential")
            body = json.loads(self.rfile.read(length))
            self.server.captures.append(body)
            count = len(self.server.captures)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.emit({"type": "message_start", "message": {
                "id": "msg_mock_" + str(count), "type": "message", "role": "assistant",
                "content": [], "model": body["model"], "stop_reason": None,
                "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0}}})
            if self.server.mode == "hostile":
                self.server.mode = "text"
                root = self.server.workspace
                calls = [
                    ("Bash", {"command": "touch " + str(root / "bash-executed")}),
                    ("Read", {"file_path": str(root / "private-canary.txt")}),
                    ("Write", {"file_path": str(root / "write-executed"), "content": "forbidden"}),
                ]
                for index, (name, arguments) in enumerate(calls):
                    self.emit({"type": "content_block_start", "index": index, "content_block": {
                        "type": "tool_use", "id": "toolu_" + name, "name": name, "input": {}}})
                    self.emit({"type": "content_block_delta", "index": index, "delta": {
                        "type": "input_json_delta", "partial_json": json.dumps(arguments)}})
                    self.emit({"type": "content_block_stop", "index": index})
                reason = "tool_use"
            else:
                self.emit({"type": "content_block_start", "index": 0,
                           "content_block": {"type": "text", "text": ""}})
                self.emit({"type": "content_block_delta", "index": 0,
                           "delta": {"type": "text_delta", "text": "Offline mock response."}})
                if self.server.mode == "interrupt":
                    self.server.stream_started.set()
                    self.server.release_stream.wait(TIMEOUT)
                self.emit({"type": "content_block_stop", "index": 0})
                reason = "end_turn"
            self.emit({"type": "message_delta", "delta": {
                "stop_reason": reason, "stop_sequence": None}, "usage": {"output_tokens": 1}})
            self.emit({"type": "message_stop"})
        except (BrokenPipeError, ConnectionResetError):
            pass  # An interrupted request closes the mock response stream.
        except Exception as error:
            self.server.errors.append(type(error).__name__ + ": " + str(error))
            self.close_connection = True

    def emit(self, event):
        data = "event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n"
        self.wfile.write(data.encode())
        self.wfile.flush()


class Client:
    def __init__(self, arguments, environment, workspace):
        self.process = subprocess.Popen(arguments, cwd=workspace, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                        start_new_session=True)
        self.messages = queue.Queue()
        self.events = deque()
        self.seen_init = False
        self.expected_receipts = set()
        self.received_receipts = set()
        self.closed = False
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(RuntimeError("Invalid Claude JSONL: " + type(error).__name__))
        finally:
            self.messages.put(RuntimeError("Claude closed stdout"))

    def send(self, frame):
        self.process.stdin.write(json.dumps(frame) + "\n")
        self.process.stdin.flush()

    def next(self, deadline):
        try:
            frame = self.messages.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty:
            raise RuntimeError("Timed out waiting for Claude") from None
        if isinstance(frame, Exception):
            raise frame
        if frame.get("type") == "control_request":
            self.send({"type": "control_response", "response": {
                "subtype": "success", "request_id": frame["request_id"], "response": {
                    "behavior": "deny", "message": "Offline profile probe denies all requests"}}})
            raise RuntimeError("Unexpected Claude permission request")
        if frame.get("type") == "system" and frame.get("subtype") == "init":
            require(set(frame.get("tools", [])) == WEB_TOOLS, "Unexpected native tool inventory")
            self.seen_init = True
        if frame.get("type") == "user" and frame.get("uuid") in self.expected_receipts:
            self.received_receipts.add(frame["uuid"])
        return frame

    def control(self, subtype, **fields):
        request_id = str(uuid.uuid4())
        self.send({"type": "control_request", "request_id": request_id,
                   "request": dict(fields, subtype=subtype)})
        deadline = time.monotonic() + TIMEOUT
        while True:
            frame = self.next(deadline)
            response = frame.get("response", {})
            if frame.get("type") == "control_response" and response.get("request_id") == request_id:
                require(response.get("subtype") == "success", subtype + " control failed")
                return response.get("response") or {}
            self.events.append(frame)

    def initialize(self):
        initial = self.control("initialize", hooks={}, agents={}, skills=[])
        require(initial.get("commands") == [], "Commands remain available")
        models = initial.get("models", [])
        require(models and all(item.get("value") for item in models), "Missing CLI model catalog")
        require(self.control("mcp_status").get("mcpServers") == [], "MCP servers remain enabled")
        require(self.control("get_settings").get("effective", {}).get("disableAllHooks") is True,
                "Hooks are not disabled")
        changed = self.control("set_model", model="sonnet")
        require(changed.get("model"), "set_model returned no native model")
        self.control("apply_flag_settings", settings={"effortLevel": "high"})
        applied = self.control("get_settings").get("applied", {})
        require(applied.get("effort") == "high", "Selected effort was not applied")
        require(applied.get("model") == changed["model"], "Selected model was not applied")
        return initial

    def prompt(self, session_id, text, image=False):
        user_id = str(uuid.uuid4())
        self.expected_receipts.add(user_id)
        content = [{"type": "text", "text": text}]
        if image:
            content.append({"type": "image", "source": {
                "type": "base64", "media_type": "image/png", "data": PNG}})
        self.send({"type": "user", "uuid": user_id, "session_id": session_id,
                   "parent_tool_use_id": None, "client_composed": True,
                   "message": {"role": "user", "content": content}})

    def finish(self, interrupted=False):
        deadline = time.monotonic() + TIMEOUT
        while True:
            frame = self.events.popleft() if self.events else self.next(deadline)
            if frame.get("type") == "result":
                if interrupted:
                    require(frame.get("terminal_reason") in ["aborted_streaming", "interrupted"],
                            "The mock stream was not interrupted")
                else:
                    require(frame.get("is_error") is False, "Mock turn failed: " + json.dumps({
                        key: frame.get(key) for key in ["subtype", "terminal_reason", "errors"]}))
                return frame

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.poll() is None:
            # Let native transcript writes finish before ending the subprocess.
            try:
                self.process.stdin.close()
                self.process.wait(timeout=3)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                pass
        for sig in [signal.SIGTERM, signal.SIGKILL]:
            try:
                os.killpg(self.process.pid, sig)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=3)
                break
            except subprocess.TimeoutExpired:
                pass
        self.reader.join(timeout=3)
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", nargs="?", default=shutil.which("claude"))
    options = parser.parse_args()
    require(options.cli and os.path.isfile(options.cli), "Claude CLI was not found")
    cli = str(Path(options.cli).resolve())
    version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()
    require(version.startswith("2.1.307 "), "This probe currently certifies Claude Code 2.1.307 only")
    profile = read_profile()
    with ExitStack() as stack:
        workspace = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="floating-claude-check-"))).resolve()
        canary = "FLOATING_AI_PRIVATE_CANARY_" + uuid.uuid4().hex
        (workspace / "private-canary.txt").write_text(canary)
        server = MockServer(workspace)
        stack.callback(server.server_close)
        stack.callback(server.shutdown)
        stack.callback(server.release_stream.set)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        # Keep the normal HOME. CLAUDE_CONFIG_DIR isolates CLI state; no existing
        # provider, auth, proxy, model, plugin or debug variables are inherited.
        environment = {key: os.environ[key] for key in ["HOME", "USER", "PATH", "TMPDIR", "LANG"]
                       if key in os.environ}
        environment.update({"CLAUDE_CONFIG_DIR": str(workspace / "config"),
                            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                            "ANTHROPIC_API_KEY": FAKE_KEY,
                            "ANTHROPIC_BASE_URL": "http://127.0.0.1:" + str(server.server_port)})
        session_id = str(uuid.uuid4())
        base = [cli] + profile
        first = Client(base + ["--session-id", session_id], environment, workspace)
        stack.callback(first.close)
        first.initialize()
        literal_prompt = "Offline synthetic image check @" + str(workspace / "private-canary.txt")
        first.prompt(session_id, literal_prompt, image=True)
        require(first.finish().get("session_id") == session_id, "Session ID changed")
        require(first.seen_init, "No native tool inventory was reported")
        require(first.received_receipts == first.expected_receipts, "Missing matching native user acknowledgement")
        first.close()
        before_resume = len(server.captures)
        require(before_resume >= 2, "CLI did not process the hostile mock tool requests")
        require(not (workspace / "bash-executed").exists(), "A shell command executed")
        require(not (workspace / "write-executed").exists(), "A file write executed")
        serialized = json.dumps(server.captures)
        require(canary not in serialized, "A file read or @path expansion exposed the canary")
        for name in ["Bash", "Read", "Write"]:
            require("No such tool available: " + name in serialized, name + " was not rejected")
        require(literal_prompt in serialized, "The literal @path prompt changed")
        require(PNG in serialized, "Image input was not transmitted")
        transcript = list((workspace / "config" / "projects").glob("*/" + session_id + ".jsonl"))
        require(len(transcript) == 1 and transcript[0].stat().st_size > 0, "Native history was not saved")
        canonical = unicodedata.normalize("NFC", os.path.realpath(workspace))
        require(transcript[0].parent.name == re.sub(r"[^a-zA-Z0-9]", "-", canonical),
                "Native history did not use the canonical realpath project key")

        resumed = Client(base + ["--resume", session_id], environment, workspace)
        stack.callback(resumed.close)
        resumed.initialize()
        resumed.prompt(session_id, "Offline synthetic continuation")
        require(resumed.finish().get("session_id") == session_id, "Resume replaced the original session")
        require(resumed.seen_init, "Resume did not verify the tool inventory")
        require(resumed.received_receipts == resumed.expected_receipts, "Resume lost the native user acknowledgement")
        resume_body = server.captures[before_resume]
        require(PNG in json.dumps(resume_body.get("messages")), "Resume lost the earlier image")
        require("Offline mock response." in json.dumps(resume_body.get("messages")), "Resume lost history")

        server.mode = "interrupt"
        resumed.prompt(session_id, "Offline synthetic interruption")
        require(server.stream_started.wait(TIMEOUT), "The interrupt test did not start")
        resumed.control("interrupt")
        stopped = resumed.finish(interrupted=True)
        require(stopped.get("session_id") == session_id, "Interrupt changed the session")
        server.release_stream.set()
        resumed.close()
        require(not server.errors, "Mock server failure: " + "; ".join(server.errors))
        for body in server.captures:
            # The native wire format may add this inert tool-search placeholder;
            # the CLI init inventory must still be exactly the two web tools.
            names = {tool.get("name") for tool in body.get("tools", [])}
            require(WEB_TOOLS <= names <= WEB_TOOLS | {"DeferredToolPlaceholder"},
                    "Unexpected API tool inventory")
            require(body.get("output_config", {}).get("effort") == "high", "Wire effort changed")
        print("PASS: " + version)
        print("Production profile: web tools only; Bash/Read/Write rejected; no file operation executed.")
        print("PNG input, literal @paths, native user receipts, model/effort controls, history resume and interrupt passed.")
        print("Only synthetic localhost requests were made; no login or paid requests were used.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)

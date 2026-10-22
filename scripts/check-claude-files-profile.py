#!/usr/bin/env python3
"""Accept the production file profile with an isolated Claude 2.1.307 process.

Only SDK initialization, tool discovery and configuration controls are sent.
No user message, model request, real credential or user attachment is used.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import tempfile
import textwrap
import threading
import time
import uuid


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", nargs="?", default=shutil.which("claude"))
    options = parser.parse_args()
    require(options.cli, "Claude Code was not found")
    cli = str(Path(options.cli).resolve())
    version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()
    require(version.startswith("2.1.307 "), "This profile is verified for Claude Code 2.1.307 only")
    spec = importlib.util.spec_from_file_location("chat_profile", Path(__file__).with_name("check-claude-profile.py"))
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    source = base.SOURCE.read_text()
    name = re.search(r'private static let fileServer = "([^"]+)"', source).group(1)
    tool = re.search(r'private static let fileTool = "([^"]+)"', source).group(1)
    instructions = re.search(r'private static let fileInstructions = """\n(.*?)\n\s*"""', source, re.S)
    args = base.read_profile()
    args[args.index("--system-prompt") + 1] = textwrap.dedent(instructions.group(1)).strip()
    args[args.index("--allowedTools") + 1] += "," + tool
    args[args.index("--mcp-config") + 1] = json.dumps({"mcpServers": {name: {"type": "sdk", "name": name}}})
    require(args[args.index("--tools") + 1] == "WebSearch,WebFetch", "General file/shell tools became available")

    with tempfile.TemporaryDirectory(prefix="floating-claude-file-profile-") as root:
        environment = {key: os.environ[key] for key in ["HOME", "USER", "PATH", "TMPDIR", "LANG"] if key in os.environ}
        environment.update({"CLAUDE_CONFIG_DIR": root, "ANTHROPIC_API_KEY": "offline-file-profile-fake-key",
                            "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
        child = subprocess.Popen([cli] + args + ["--no-session-persistence"], cwd=root, env=environment,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, bufsize=1)
        messages = queue.Queue()
        methods = set()

        def read():
            try:
                for line in child.stdout:
                    messages.put(json.loads(line))
            finally:
                messages.put(None)

        reader = threading.Thread(target=read, daemon=True)
        reader.start()

        def send(value):
            child.stdin.write(json.dumps(value) + "\n")
            child.stdin.flush()

        def control(subtype, **fields):
            request_id = str(uuid.uuid4())
            send({"type": "control_request", "request_id": request_id, "request": dict(fields, subtype=subtype)})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                frame = messages.get(timeout=max(0, deadline - time.monotonic()))
                require(frame is not None, "Claude exited during the handshake")
                if frame.get("type") == "control_request":
                    request = frame["request"]
                    require(request.get("subtype") == "mcp_message" and request.get("server_name") == name,
                            "Unexpected capability or permission request")
                    rpc = request["message"]
                    method = rpc.get("method")
                    methods.add(method)
                    require(method in ["initialize", "notifications/initialized", "tools/list", "ping"],
                            "A tool call occurred without a user message")
                    result = {}
                    if method == "initialize":
                        result = {"protocolVersion": rpc["params"]["protocolVersion"], "capabilities": {"tools": {}},
                                  "serverInfo": {"name": name, "version": "1"}}
                    elif method == "tools/list":
                        result = {"tools": [{"name": "read_attachment", "description": "Read only this note's attachments",
                                             "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}},
                                                             "required": ["path"], "additionalProperties": False},
                                             "annotations": {"readOnlyHint": True, "destructiveHint": False}}]}
                    response = {"jsonrpc": "2.0", "result": result}
                    if "id" in rpc:
                        response["id"] = rpc["id"]
                    send({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"],
                                                                   "response": {"mcp_response": response}}})
                elif frame.get("type") == "control_response" and frame.get("response", {}).get("request_id") == request_id:
                    require(frame["response"].get("subtype") == "success", "Claude rejected " + subtype)
                    return frame["response"].get("response", {})
            raise RuntimeError("Handshake timed out")

        try:
            initialized = control("initialize", hooks={}, agents={}, skills=[], sdkMcpServers=[name])
            require(initialized.get("claude_code_version") == "2.1.307" and initialized.get("commands") == [],
                    "Unexpected version or slash commands")
            for attempt in range(40):
                servers = control("mcp_status").get("mcpServers", [])
                require(all(server.get("name") == name for server in servers), "Unrelated MCP server enabled")
                if servers and servers[0].get("status") == "connected":
                    require(len(servers) == 1 and servers[0].get("source") == "sdk", "Unexpected MCP source")
                    require([item["name"] for item in servers[0].get("tools", [])] == ["read_attachment"], "Unexpected file tools")
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("SDK attachment reader did not become ready")
            require(control("get_settings").get("effective", {}).get("disableAllHooks") is True, "Hooks became available")
            require({"initialize", "tools/list"} <= methods, "SDK tool discovery did not complete")
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
            reader.join(timeout=3)
            child.stdout.close()
    print("PASS: " + version + "; scoped SDK attachment tool accepted with safe-mode/restricted and no general file/shell tools.")
    print("Only initialization controls were sent. No user messages, model requests, credentials or real attachments were used.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify native permanent deletion using isolated Codex data and a local mock.

Usage: python3 scripts/check-codex-deletion.py /absolute/path/to/codex
No user histories, credentials, or paid requests are used. Requires loopback
socket permission. Uses the same production chat profile as the profile check.
"""

import argparse
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import uuid


spec = importlib.util.spec_from_file_location("profile_check", Path(__file__).with_name("check-codex-profile.py"))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
require = profile.require


class Client(profile.Client):
    def response(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + profile.TIMEOUT
        while True:
            message = self._next(deadline)
            if message.get("id") == request_id and "method" not in message:
                return message
            self._notification(message)


def require_deleted(response, thread_id):
    error = response.get("error")
    require(error is None or (error.get("code") == -32600 and
            error.get("message") == "no rollout found for thread id " + thread_id),
            "Deleting an already-missing conversation failed: " + str(error))


def run(executable):
    launch, thread_config, instructions, _ = profile.read_profile()
    with tempfile.TemporaryDirectory(prefix="floating-ai-deletion-") as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        home, workspace = root / "codex", root / "workspace"
        home.mkdir()
        workspace.mkdir()
        server = profile.CaptureServer()
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
        environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL")
                       if key in os.environ}
        environment["CODEX_HOME"] = str(home)
        common = {"cwd": str(workspace), "baseInstructions": instructions, "developerInstructions": "",
                  "approvalPolicy": "never", "sandbox": "read-only", "config": thread_config,
                  "runtimeWorkspaceRoots": []}
        client = Client(arguments, environment, workspace)
        cleanup.callback(client.close)
        version = client.initialize()
        require(version.startswith(("0.151.", "0.163.")), "Expected a supported deletion protocol")
        config = client.request("config/read", {"includeLayers": False})["config"]
        require(config["model_provider"] == "capture" and
                config["model_providers"]["capture"]["base_url"] == endpoint,
                "The isolated mock provider was not applied")
        histories = []
        for label in ("delete-active", "keep", "delete-archived"):
            thread = client.request("thread/start", dict(common, model=profile.MODEL,
                environments=[], dynamicTools=[], historyMode="legacy"))["thread"]
            thread_id = thread["id"]
            turn = client.request("turn/start", {
                "threadId": thread_id, "input": [{"type": "text", "text": "Offline deletion check: " + label}],
                "model": profile.MODEL, "effort": "medium", "cwd": str(workspace), "environments": [],
                "runtimeWorkspaceRoots": [], "approvalPolicy": "never",
                "sandboxPolicy": {"type": "readOnly", "networkAccess": False}})["turn"]
            client.wait_for_turn(thread_id, turn["id"])
            result = client.request("thread/read", {"threadId": thread_id, "includeTurns": True})
            require(result["thread"]["turns"], "Synthetic conversation was not persisted")
            histories.append(thread_id)
        client.request("thread/archive", {"threadId": histories[2]})
        for thread_id in (histories[0], histories[2]):
            require(list(home.rglob("*" + thread_id + "*")), "Synthetic rollout is missing before deletion")
            result = client.response("thread/delete", {"threadId": thread_id})
            require("error" not in result, "Deleting an existing conversation failed: " + str(result.get("error")))
            require(not list(home.rglob("*" + thread_id + "*")), "Deleted rollout or session directory remains")
            require("error" in client.response("thread/read", {"threadId": thread_id, "includeTurns": True}),
                    "Deleted conversation remains readable")
            retry = client.response("thread/delete", {"threadId": thread_id})
            require_deleted(retry, thread_id)
        missing_id = str(uuid.uuid4())
        require_deleted(client.response("thread/delete", {"threadId": missing_id}), missing_id)
        kept = client.request("thread/read", {"threadId": histories[1], "includeTurns": True})
        require(kept["thread"]["turns"], "Deleting a different conversation damaged the retained one")
        require(not (home / "auth.json").exists(), "Unexpected persisted credentials")
        require(not server.errors and len(server.captures) == 3, "Unexpected mock requests or errors")
        print("PASS Codex " + version + ": permanent deletion of active and archived histories; repeat/missing deletion; unrelated history retained. No paid requests.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("codex")
    args = parser.parse_args()
    executable = shutil.which(os.path.expanduser(args.codex))
    require(executable is not None, "Codex executable was not found")
    run(str(Path(executable).resolve()))


if __name__ == "__main__":
    main()

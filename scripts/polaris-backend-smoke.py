#!/usr/bin/env python3
"""Exercise the actual stdio binary and multiple processes sharing one state file."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/polaris-mcp").resolve())


def request(identifier, method, params=None):
    result = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        result["params"] = params
    return result


with tempfile.TemporaryDirectory(prefix="polaris-backend-") as home:
    environment = dict(os.environ, POLARIS_HOME=home)

    def exchange(messages):
        completed = subprocess.run(
            [binary], input="".join(json.dumps(m) + "\n" for m in messages),
            text=True, capture_output=True, env=environment, check=True, timeout=30,
        )
        assert not completed.stderr, completed.stderr
        return [json.loads(line) for line in completed.stdout.splitlines()]

    replies = exchange([
        request(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}),
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        request(2, "tools/list"),
        request(3, "tools/call", {"name": "polaris_add_task", "arguments": {"title": "本命", "to": "now"}}),
        request(4, "tools/call", {"name": "polaris_get_today"}),
    ])
    assert len(replies) == 4
    assert replies[0]["result"]["serverInfo"]["name"] == "polaris"
    assert len(replies[1]["result"]["tools"]) == 11
    today = json.loads(replies[3]["result"]["content"][0]["text"])
    assert today["now"][0]["title"] == "本命"
    assert today["now"][0]["source"] == "mcp:smoke"
    baseline = today["revision"]

    def writer(worker):
        replies = exchange([
            request(i, "tools/call", {"name": "polaris_add_task", "arguments": {"title": f"{worker}-{i}"}})
            for i in range(20)
        ])
        assert len(replies) == 20
        assert all(not reply["result"]["isError"] for reply in replies)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(writer, range(6)))
    state = json.loads(Path(home, "state.json").read_text())
    assert state["revision"] == baseline + 120, state["revision"]
    assert len(state["later"]) == 120
    assert len({task["id"] for task in state["later"]}) == 120
    assert not list(Path(home).glob("polaris-backend-*.tmp"))
    print("PASS: initialize → tools/list → add_task → get_today; 6 processes × 20 writes, no lost revisions")

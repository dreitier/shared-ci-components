#!/usr/bin/env python3
"""Runs shellcheck on the `run` scripts of the composite actions (actionlint only checks workflows).

The scripts must not contain ${{ }} expressions (values come in via env) – that's checked here too.
"""
import pathlib
import subprocess
import sys
import tempfile

import yaml

root = pathlib.Path(__file__).resolve().parents[2]
failed = False
for action in sorted(root.glob("*/action.yml")):
    steps = yaml.safe_load(action.read_text())["runs"]["steps"]
    for i, step in enumerate(steps):
        script = step.get("run")
        if script is None:
            continue
        name = f"{action.relative_to(root)} step {i + 1} ({step.get('name', 'unnamed')})"
        if "${{" in script:
            print(f"{name}: ${{{{ }}}} expression in run – pass it via env", file=sys.stderr)
            failed = True
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
            f.write(script)
            f.flush()
            result = subprocess.run(["shellcheck", "--shell=bash", f.name], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"{name}:\n{result.stdout}", file=sys.stderr)
            failed = True
        else:
            print(f"ok: {name}")
sys.exit(1 if failed else 0)

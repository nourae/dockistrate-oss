#!/usr/bin/env python3
"""Capture a named live interactive journey on a disposable hosted Linux VM."""

import argparse
import importlib
import os
from pathlib import Path
import signal
import sys
import traceback

from capture.runtime import CaptureContext
from capture.matrix import GROUPS


def interrupted(signum, frame):
    raise InterruptedError(f"Capture interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True, choices=["core", "security", "operations"])
    parser.add_argument("--group", default="all", help="Independent scenario group on this fresh VM")
    parser.add_argument("--output", type=Path, required=True, help="Safe artifact directory outside runtime state")
    args = parser.parse_args()
    tool = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == tool or output.is_relative_to(tool):
        parser.error("Output must be separate from the checkout and runtime state")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    if args.group not in ("all", *GROUPS[args.scenario]):
        parser.error("Unknown group for " + args.scenario + ": " + args.group)
    os.environ["DOCS_SECURITY_GROUP"] = args.group
    os.environ["DOCS_OPERATIONS_GROUP"] = args.group
    context = CaptureContext(tool, output, args.scenario + "-" + args.group)
    context.metadata.update(scenario_module=args.scenario, group=args.group)
    error = None
    try:
        context.preflight()
        if args.scenario == "core" and args.group != "all":
            module = importlib.import_module("capture.core_extra")
            module.run_group(context, args.group)
        else:
            module = importlib.import_module("capture." + args.scenario)
            module.run(context)
        context.metadata["images"] = context.run(
            ["docker", "image", "ls", "--digests", "--no-trunc", "--format", "{{json .}}"],
            label="image-identities",
        ).splitlines()
        context.proof("scenario-completed", scenario=args.scenario)
    except BaseException as failure:
        error = failure
        traceback.print_exc()
    finally:
        # All runtime resources are on a throwaway hosted VM. Do not copy state,
        # certificates, key logs, backup archives, or packet captures into artifacts.
        context.close("failed" if error else "passed", error)
    return 1 if error else 0


if __name__ == "__main__":
    sys.exit(main())

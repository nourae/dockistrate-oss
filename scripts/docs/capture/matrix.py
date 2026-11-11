"""Select independent capture VMs before GitHub expands the job matrix."""

import argparse
import json
from pathlib import Path


GROUPS = {
    "core": ("all", "services", "hosts", "routing", "protocols", "migration", "branches"),
    "security": ("headers", "access", "acl", "rules", "tls", "certificates", "mtls", "branches"),
    "operations": ("inspect", "runtime", "backup", "traffic", "cleanup", "uninstall", "branches"),
}


def select_matrix(scenario="all", group="all"):
    if scenario not in ("all", *GROUPS):
        raise ValueError("Unknown capture scenario: " + scenario)
    selected = []
    for name, groups in GROUPS.items():
        if scenario not in ("all", name):
            continue
        for item in groups:
            # The CLI's core/all is only the README baseline; dispatch/all
            # means every independent group and exposes that one as baseline.
            public_name = "baseline" if (name, item) == ("core", "all") else item
            if group in ("all", public_name):
                selected.append({"scenario": name, "group": item})
    if not selected:
        raise ValueError(f"No capture group {group!r} in scenario {scenario!r}")
    return {"include": selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", default="all")
    parser.add_argument("--group", default="all")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        matrix = json.dumps(select_matrix(args.scenario, args.group), separators=(",", ":"))
    except ValueError as error:
        parser.error(str(error))
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write("matrix=" + matrix + "\n")
    else:
        print(matrix)


if __name__ == "__main__":
    main()

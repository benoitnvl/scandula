#!/usr/bin/env python3
"""Prove every variable validation is load-bearing.

For each `validation` block in infra/variables.tf, swap its condition for one
that always passes and run the test suite. At least one run must go red. If
none does, nothing would notice that validation breaking: either it has no
rejection run, or its run is really being caught by a different validation.

The always-true condition is `can(var.<name>)` rather than `true`, because
Terraform rejects a validation that doesn't refer to its own variable.

It works on a temp copy of infra/, so an interrupted run can't leave a mutant
behind. Run `make init-local` first.

    make mutants              # TF=terraform
    make mutants TF=tofu
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

TF = os.environ.get("TF", "terraform")
INFRA = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "infra").resolve()

VALIDATION = re.compile(r"(?ms)^  validation \{\n(.*?)^  \}\n")
CONDITION = re.compile(r"(?ms)^    condition\s*=.*?(?=^    error_message)")
RUN_BLOCK = re.compile(r'(?ms)^run "([^"]+)" \{.*?^\}\n')
RESULT = re.compile(r'run "([^"]+)"\.\.\. (pass|fail|skip)')


def load_tests():
    """{filename: (header, [(run name, run text), ...])}"""
    tests = {}
    for path in sorted((INFRA / "tests").glob("*.tftest.hcl")):
        text = path.read_text()
        runs = list(RUN_BLOCK.finditer(text))
        header = text[: runs[0].start()] if runs else text
        tests[path.name] = (header, [(m.group(1), m.group(0)) for m in runs])
    return tests


def write_tests(work, tests, exclude):
    shutil.rmtree(work / "tests", ignore_errors=True)
    (work / "tests").mkdir()
    for name, (header, runs) in tests.items():
        kept = [text for run, text in runs if run not in exclude]
        if kept:
            (work / "tests" / name).write_text(header + "\n".join(kept))


def red_runs(work, tests):
    """Every run that fails. One failure makes the runs after it `skip`, so drop
    the red ones and go again until nothing is skipped — a skip hides a result."""
    red = set()
    while True:
        write_tests(work, tests, exclude=red)
        out = subprocess.run([TF, "test", "-no-color"], cwd=work, capture_output=True, text=True)
        results = RESULT.findall(out.stdout + out.stderr)
        if not results:
            sys.exit(f"harness error: no run results from `{TF} test`:\n{(out.stdout + out.stderr)[-1500:]}")
        fails = {run for run, status in results if status == "fail"}
        skipped = any(status == "skip" for _, status in results)
        red |= fails
        if not skipped or not fails:
            return red


def main():
    variables = (INFRA / "variables.tf").read_text()
    blocks = list(VALIDATION.finditer(variables))
    tests = load_tests()
    untested = []

    with tempfile.TemporaryDirectory(prefix="scandula-mutants-") as tmp:
        work = pathlib.Path(tmp)
        for path in INFRA.glob("*.tf"):
            shutil.copy2(path, work)
        for name in (".terraform", ".terraform.lock.hcl"):
            if (INFRA / name).exists():
                (work / name).symlink_to(INFRA / name)

        baseline = red_runs(work, tests)
        if baseline:
            sys.exit(f"the suite is red before any mutation: {sorted(baseline)}")

        for m in blocks:
            var = re.findall(r'^variable "(\w+)"', variables[: m.start()], re.M)[-1]
            message = re.search(r'error_message\s*=\s*"(.*)"', m.group(1)).group(1)
            mutant = CONDITION.sub(f"    condition     = can(var.{var})\n", m.group(1), count=1)
            (work / "variables.tf").write_text(variables[: m.start(1)] + mutant + variables[m.end(1):])

            red = red_runs(work, tests)
            print(f"{var}: {message[:72]}")
            print(f"    red when disabled: {', '.join(sorted(red)) if red else 'NONE, untested'}")
            if not red:
                untested.append(f"{var}: {message}")

    if untested:
        print(f"\n{len(untested)} of {len(blocks)} validations are untested:", *untested, sep="\n  ")
        sys.exit(1)
    print(f"\nall {len(blocks)} validations are load-bearing")


if __name__ == "__main__":
    main()

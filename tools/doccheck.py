# kippy - Kippenhahn diagram viewer
# Copyright (C) 2026 the kippy authors (see AUTHORS)
#
# This file is part of kippy.
#
# kippy is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# kippy is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
# License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with kippy. If not, see <https://www.gnu.org/licenses/>.

"""check that fortran sources carry FORD docstrings

    uv run tools/doccheck.py FILE...

every module, program, derived type, procedure (interface bodies and internal
procedures included), dummy argument, module variable and type component needs
a FORD `!!` docstring, either on the line right after its statement or trailing
the statement itself. procedure locals are not checked: FORD's own `warn`
option reports them too and cannot tell them apart from arguments. exits 1 and
lists each missing docstring as file:line.
"""

import re
import sys
from pathlib import Path

STRING = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"")
TYPESPEC = r"(?:integer|real|logical|character|complex|double\s+precision|type|class|procedure)\b"
DECL = re.compile(rf"^\s*{TYPESPEC}.*?::\s*(.+)$", re.I)
PREFIX = r"(?:(?:pure|elemental|recursive|impure|module|integer|real|logical|character|complex|type)(?:\s*\([^)]*\))?\s+)*"
PROC = re.compile(rf"^\s*{PREFIX}(subroutine|function)\s+(\w+)\s*(?:\(([^)]*)\))?", re.I)
UNIT = re.compile(r"^\s*(module|program)\s+(?!procedure\b)(\w+)\s*$", re.I)
TYPEDEF = re.compile(r"^\s*type\b(?!\s*\()(?:\s*,[^:]*)?\s*(?:::)?\s*(\w+)\s*$", re.I)
INTERFACE = re.compile(r"^\s*(?:abstract\s+)?interface\b", re.I)
END = re.compile(r"^\s*end\s*(subroutine|function|type|module|program|interface)\b", re.I)
NAMES = re.compile(r",(?![^(\[]*[)\]])")


def split(line):
    """code part of a line (strings blanked) and its trailing comment"""
    blank = STRING.sub(lambda m: "'" + " " * (len(m.group()) - 2) + "'", line)
    k = blank.find("!")
    return (blank, "") if k < 0 else (blank[:k], line[k:])


def statements(lines):
    """yield (first line, last line, joined code, has trailing !!) per statement"""
    k = 0
    while k < len(lines):
        start, code, doc = k, "", False
        while True:
            part, comment = split(lines[k])
            doc = doc or comment.startswith("!!")
            part = part.strip()
            more = part.endswith("&")
            code += " " + part.rstrip("&").lstrip("&")
            if not more or k + 1 == len(lines):
                break
            k += 1
        yield start, k, code.strip(), doc
        k += 1


def check(path):
    lines = path.read_text().splitlines()
    missing = []
    scopes = []

    for start, end, code, trailing in statements(lines):
        if not code:
            continue
        documented = trailing or (end + 1 < len(lines) and lines[end + 1].lstrip().startswith("!!"))

        def need(kind, name):
            if not documented:
                missing.append(f"{path}:{start + 1}: undocumented {kind} '{name}'")

        if (m := END.match(code)):
            scope = scopes.pop()
            if scope[0] == "proc":
                for arg in sorted(scope[2] - scope[3]):
                    missing.append(f"{path}:{scope[4] + 1}: argument '{arg}' of {scope[1]} has no :: declaration")
        elif (m := UNIT.match(code)):
            need(m.group(1).lower(), m.group(2))
            scopes.append((m.group(1).lower(), m.group(2)))
        elif INTERFACE.match(code):
            scopes.append(("interface",))
        elif (m := TYPEDEF.match(code)):
            need("type", m.group(1))
            scopes.append(("type", m.group(1)))
        elif (m := PROC.match(code)):
            need(m.group(1).lower(), m.group(2))
            args = {a.strip().lower() for a in (m.group(3) or "").split(",") if a.strip()}
            scopes.append(("proc", m.group(2), args, set(), start))
        elif (m := DECL.match(code)) and scopes:
            names = [n.group(1).lower() for part in NAMES.split(m.group(1))
                     if (n := re.match(r"\s*(\w+)", part))]
            top = scopes[-1]
            if top[0] == "module":
                for n in names:
                    need("module variable", n)
            elif top[0] == "type":
                for n in names:
                    need(f"component of {top[1]}", n)
            elif top[0] == "proc":
                for n in names:
                    if n in top[2]:
                        need(f"argument of {top[1]}", n)
                        top[3].add(n)
    return missing


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    missing = [m for f in sys.argv[1:] for m in check(Path(f))]
    print("\n".join(missing) if missing else f"doccheck ok: {len(sys.argv) - 1} files")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()

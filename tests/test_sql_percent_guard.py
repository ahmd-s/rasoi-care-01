"""PostgreSQL guard that runs on SQLite-only CI.

database.PgConnection.execute() always passes a params tuple to psycopg2, which
then treats every literal `%` in the SQL as a format character. A query such as
`LIKE 'fake%'` therefore raises IndexError on PostgreSQL but works on SQLite --
and when it sits in a boot-time migration it crash-loops the whole app. Use `?`
parameters (e.g. `LIKE ?` with the pattern as a parameter) or substr()/instr()
instead of a literal `%` inside any SQL passed to `.execute()`."""
import ast
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP = {"tests", ".venv", "venv", "build", "node_modules"}


def _modules():
    for path in sorted(ROOT.rglob("*.py")):
        rel = path.relative_to(ROOT)
        if rel.parts[0] in SKIP or rel.parts[0].startswith("."):
            continue
        yield path


def _literal_text(node):
    """All constant string text reachable in a SQL expression (plain strings,
    f-string pieces, implicit/explicit concatenation)."""
    return "".join(
        n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str)
    )


def test_no_literal_percent_in_executed_sql():
    offenders = []
    for path in _modules():
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "execute" and node.args
                    # `cur.execute(_QMARK_RE.sub("%s", sql), params)` is the wrapper doing the
                    # rewrite itself; only literal SQL text is checked.
                    and not isinstance(node.args[0], ast.Call)):
                text = _literal_text(node.args[0])
                if "%" in text:
                    offenders.append(f"{path.relative_to(ROOT)}:{node.lineno}: {text.strip()[:90]}")
    assert not offenders, (
        "Literal % in SQL passed to .execute() breaks PostgreSQL (psycopg2 format "
        "characters). Use ? parameters or substr():\n" + "\n".join(offenders))

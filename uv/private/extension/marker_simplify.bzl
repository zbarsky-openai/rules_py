"""Simplify PEP 508 markers during graph construction.

uv writes every dependency of an extra with a redundant `extra == '<name>'`
marker. An edge out of an extra pseudo-package is only ever traversed once that
extra is active, so once we know which extra an edge belongs to that clause is a
known boolean. We resolve it here rather than emitting an un-evaluable
`decide_marker`, which would later see an empty `extra` environment (the venv
name is not the extra) and wrongly drop the dependency.
"""

load("//uv/private/markers:pep508_evaluate.bzl", "evaluate")

def simplify_extra_marker(marker, extra):
    """Partially evaluate a marker binding the `extra` PEP 508 variable.

    Args:
        marker: The PEP 508 marker string on the edge.
        extra: The name of the active extra the edge belongs to.

    Returns:
        - `""` if the marker reduces to true.
        - `None` if it reduces to false (the clause names a different extra).
        - The residual marker string when other (e.g. platform) clauses remain.
    """
    if not marker:
        return marker
    res = evaluate(marker, env = {"extra": extra}, strict = False)
    if res == False:
        return None
    if res == True:
        return ""
    return res

def clause_marker(clause):
    """Render a canonical conjunction clause as a marker expression."""
    if not clause:
        return ""
    if len(clause) == 1:
        return clause[0]
    return " and ".join(["({})".format(marker) for marker in clause])

def add_minimal_clause(clauses, candidate):
    """Add candidate unless an existing, less restrictive clause subsumes it."""
    if clauses:
        if candidate in clauses or () in clauses:
            return False
        if not candidate:
            clauses.clear()
        else:
            for existing in clauses:
                if all([marker in candidate for marker in existing]):
                    return False
            for existing in [existing for existing in clauses if all([marker in existing for marker in candidate])]:
                clauses.pop(existing)
    clauses[candidate] = 1
    return True

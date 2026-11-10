"""Load-time checks for the generated requirements API."""

def assert_equal(expected, actual):
    if actual != expected:
        fail("Expected {}, got {}".format(expected, actual))

def assert_group(hub, packages, actual):
    assert_equal([Label("{}//{}:pkg".format(hub, name)) for name in packages], actual)

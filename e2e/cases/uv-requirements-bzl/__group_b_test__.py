"""Import one shared package and one package exclusive to group B."""

import cowsay
import wcwidth

assert hasattr(cowsay, "cow")
assert hasattr(wcwidth, "wcwidth")

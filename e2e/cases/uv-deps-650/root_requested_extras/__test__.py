#!/usr/bin/env python3

import urllib3

print(urllib3.__file__)

# Activated via manifest.overrides requesting urllib3[brotli].
import brotli

print(brotli.__file__)

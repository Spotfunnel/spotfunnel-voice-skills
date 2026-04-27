"""Pytest configuration for operator UI server tests.

The `integration` marker (registered in pyproject.toml) tags tests that hit
live external services such as Supabase. Run unit-only with:

    pytest -m "not integration"
"""

import os
import sys

# Make `auth_helpers` importable from any test in this directory without
# requiring relative imports (tests/__init__.py would force that).
sys.path.insert(0, os.path.dirname(__file__))

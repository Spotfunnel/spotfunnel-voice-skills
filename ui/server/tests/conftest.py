"""Pytest configuration for operator UI server tests.

The `integration` marker (registered in pyproject.toml) tags tests that hit
live external services such as Supabase. Run unit-only with:

    pytest -m "not integration"
"""

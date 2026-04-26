# operator-ui server

Python side of the ZeroOnboarding Operator UI. Talks to the Supabase `operator_ui` schema.

## Install

```bash
python -m venv .venv
. .venv/Scripts/activate    # Windows; use .venv/bin/activate on macOS/Linux
pip install -e ".[dev]"
```

## Run tests

```bash
pytest
```

Integration tests skip automatically if `SUPABASE_OPERATOR_URL` and `SUPABASE_OPERATOR_SERVICE_ROLE_KEY` are not set.

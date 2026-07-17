# Visionary — dev/test entry points. Run from the repo root.
# Recipes use paths relative to the repo root (the absolute path may contain spaces).

.PHONY: venv golden test demo ios-check

venv:
	python3 -m venv .venv
	.venv/bin/pip install -r firmware/requirements.txt

golden:
	@if [ -x .venv/bin/python3 ]; then \
		.venv/bin/python3 tests/generate_golden.py; \
	else \
		python3 tests/generate_golden.py; \
	fi

test: golden
	@if [ -x .venv/bin/pytest ]; then \
		.venv/bin/pytest tests -q; \
	else \
		pytest tests -q; \
	fi

demo:
	@if [ -x .venv/bin/python3 ]; then \
		VISIONARY_SIM=1 .venv/bin/python3 tests/demo_smoke.py; \
	else \
		VISIONARY_SIM=1 python3 tests/demo_smoke.py; \
	fi

ios-check:
	@if command -v xcrun >/dev/null 2>&1; then \
		xcrun -sdk iphonesimulator swiftc -typecheck \
			-target arm64-apple-ios16.0-simulator \
			$$(find ios/Visionary -name '*.swift'); \
	else \
		echo "note: xcrun not found; skipping iOS typecheck (needs Xcode on macOS)"; \
	fi

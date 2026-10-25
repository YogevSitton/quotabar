# Claude development instructions

Read and follow `AGENTS.md` and `README.md` for architecture, connection behavior, credential handling, reset safeguards, layout and verification limits.

Follow the Git workflow in `CONTRIBUTING.md`: never commit to `main`, use a branch and a pull request with a Conventional Commit title, and update `CHANGELOG.md` for user-visible changes.

Keep changes focused. Compile and statically review changes only unless the maintainer changes that restriction. Do not run tests, live diagnostics, sign-in or reset actions. Use synthetic fixtures and never commit local credentials or account data.

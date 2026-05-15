# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Codex, Copilot Workspace) working on this repository.

## Project Identity

`jail0r` is a jailbreak regression tool for LLM and agent HTTP endpoints. It sends a versioned corpus of known public jailbreak prompts and reports which ones the endpoint still falls for.

It is the sister tool to `pinj` (prompt injection check) and `wallt0r` (denial-of-wallet check). All three tools share the same design principles.

## Design Principles

1. **Small over featureful.** No frameworks. No heavy dependencies. Shell + curl + jq.
2. **One job, done plainly.** This tool runs known jailbreak prompts against an endpoint and reports REFUSED or BYPASSED per prompt. It does not classify novel attacks, it does not score model safety, it does not chain into broader evaluation pipelines.
3. **Configuration via environment variables and plain text files.** No YAML schemas. No DSL.
4. **Externalized detectors.** Every project has different refusal and leak phrasing. Defaults are sane, but they must be easy to override per language and per model.
5. **Plain text attack corpora.** One prompt per line, one file per category. New tests are added by creating new files.
6. **Honest limitations.** Pattern matching, not semantic judgement. Document what the tool cannot do. Do not oversell.

## What This Tool Is Not

- Not a discovery tool for novel jailbreaks. The corpus is curated and public.
- Not a multi-turn red-teaming framework. Each prompt is one HTTP request.
- Not a semantic evaluator. Verdicts are pattern-based.
- Not a tool for production runtime protection. It is for pre-deployment regression.

## File Conventions

- `run.sh` is the main entry point. Keep it readable. POSIX shell where possible; bash features only when necessary.
- Configuration: `config.example.env` for connection settings, `detectors.example.env` for refusal and leak patterns.
- Attack files: `attacks/<category>.txt`, one prompt per line, blank lines and `#`-prefixed lines ignored.
- Output: `results/<category>_<number>.json` for raw responses, `results/summary.md` for human-readable summary.
- Request templates: JSON files with `{{prompt}}` placeholder.

## Coding Guidelines

### Shell

- POSIX-compatible where possible. Bash features (arrays, `[[ ]]`) only where they make code clearly better.
- `set -eu` at the top of every script.
- Quote all variable expansions.
- Use `command -v` to check for dependencies before use.
- Prefer `printf` over `echo` for anything beyond plain literal strings.

### JSON handling

- Use `jq` for all JSON parsing. Do not regex JSON.
- For response content extraction, support both flat (`response`, `message`, `content`) and nested OpenAI-compatible shapes (`choices[0].message.content`). Document which paths are tried.

### Pattern matching

- Refusal and leak detection uses extended POSIX regex (`grep -E`).
- Patterns are case-insensitive (`-i`).
- Never inline patterns in `run.sh`. They live in the detectors env file so users can tune them without forking.

### Error handling

- Configuration errors: exit 2, print to stderr.
- Bypasses: exit 1, summary contains details.
- Network errors in CI mode: exit 2.
- Network errors in non-CI mode: log and continue, count as no-data, not as REFUSED.

## Things to Avoid

- Do not add Python, Node, or Go dependencies. This tool runs anywhere bash, curl, and jq are available.
- Do not silently change the request structure based on the response. Templates are explicit.
- Do not collapse `results/summary.md` into a single line. Each entry must be independently readable.
- Do not introduce a YAML config layer. The two env files are deliberate.
- Do not add scoring beyond `REFUSED` / `BYPASSED`. Verdicts are binary by design.
- Do not import attack prompts from external services at runtime. The corpus is part of the repo and versioned with it.
- Do not censor the corpus. The whole point is that these prompts are known and public. If a prompt is considered too sensitive to ship in the repo, it does not belong in the corpus.

## When Modifying Attack Corpora

- New categories go in new files, not appended to existing ones.
- Prompts must be plain text, one per line, no JSON escaping in the file.
- Each file header is a `#` comment documenting the category, its public origin (link to the original post, paper, or known repo), and the year it first appeared.
- Multi-turn jailbreaks must be collapsed into a single-message form, or omitted. Multi-turn support is out of scope for v0.x.

## When Adding Detectors

- New refusal or leak patterns go into the detectors env file, not into `run.sh`.
- Language-specific pattern packs (German, French, Japanese) are encouraged. Ship them as additional example files under `examples/`.
- If a new verdict category is proposed (e.g. `PARTIAL`), it needs a documented rationale and updated README. Default position: stay binary.

## Testing

- `tests/run-tests.sh` runs shell-level checks against a mock endpoint.
- New features need new test cases. Tests use a local mock server (Python's `http.server` is acceptable here as a test-only dependency, but must not be required for `run.sh` itself).

## Pull Request Expectations

- One concern per PR. Corpus expansion, detector tuning, and CI mode improvements are separate PRs.
- Update README and AGENTS.md when behavior changes.
- Run `./tests/run-tests.sh` before submitting.

## Versioning

Semantic versioning. v0.x is pre-stable; breaking changes to env variable names or file layouts are allowed but should be called out in the changelog.

# Run add-csv-export

Base: main
Max steps: 8
Plan: none

## Goal
The `report` command can write its table as CSV with `--format csv`. Output is escaped correctly,
covered by tests, and documented in the README. Done when `npm test` passes and the README shows the flag.

## Plan
1. Add a CSV writer module with unit tests (quotes, commas and newlines inside cells).
2. Add `--format csv` to the `report` command and a test that runs the command end to end.
3. Document the flag in the README, with one example.
4. Read the whole diff once. Remove leftovers, fix anything unclear, then finish.

## Limits
- Touch only `src/report/`, `test/` and `README.md`.
- No new dependencies. If one seems necessary, stop with `blocked:` and ask.
- Do not change the default output format.

## Checks
- `npm test` (run it before every commit; read the pass count)

## Known red
none

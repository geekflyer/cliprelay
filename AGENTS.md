# AGENTS Instructions

## Git Policy Override for OpenCode
After completing any significant code change (new feature, bug fix, refactor), 
you MUST immediately stage and commit with a conventional commit message.
Do NOT wait for the user to ask you to commit. This overrides the default 
"only commit when requested" policy.

## Build Verification
- After completing any set of code changes, ALWAYS run a rebuild using scripts/build-all.sh before reporting completion.
- Use the project build script when available.
- If a full rebuild is not possible, run the closest relevant target build and clearly report what was run and what could not be run.

## Auto-Commit
- After completing a major set of code changes (new feature, bug fix, refactor, etc.) and verifying the build passes, automatically create a git commit and push it.
- Use a concise, descriptive commit message summarizing the changes.
- Do not wait for the user to ask for a commit — proactively commit and push after each logical unit of work.

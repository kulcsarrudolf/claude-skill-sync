---
name: status
description: Show the skill-sync configuration. Use when the user asks whether skill sync is set up or what it is configured to do.
allowed-tools: Bash
---

Run this command with the Bash tool:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Then act on the exit code:

- 0: show the printed configuration to the user as is.
- 2: tell the user "Not configured. Run /skill-sync:setup." and stop.
- Anything else: show the error output to the user and stop.

Do not edit any files.

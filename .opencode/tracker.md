# Tracker configuration

Single source of truth for this repo's issue tracker. Written by `/harness-setup`
and read by `/harness-bootstrap`, `/task-init`, and `/task-implement`. Committed
on purpose — it's harness config, not a scratch spec.

```yaml
tracker:       plane          # plane | linear | github | other
mcp_prefix:    plane            # OpenCode MCP server name — tools surface as <prefix>_<resource> (e.g. plane_state) with an action param
project_code:  RMD             # short id used in issue identifiers (RMD-12)
project_id:    e2675da2-df7f-4a7c-a289-a7aabe1a79e5  # RemDev (RMD) in workspace "personal"
has_cycles:    true            # true → time-boxed cycles; false → milestones/none
cycle_length:  1w              # cycle duration (weekly)
cycle_anchor:  monday          # week runs Monday → Sunday
```

Run `/harness-setup` to (re)generate this file; run `/harness-bootstrap` to
create the project, states, type labels, and cycles in the live tracker.

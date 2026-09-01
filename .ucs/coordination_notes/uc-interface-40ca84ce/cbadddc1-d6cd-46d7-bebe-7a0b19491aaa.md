---
version: 2
messageId: cbadddc1-d6cd-46d7-bebe-7a0b19491aaa
timestamp: 1787955454128
correlationId: 2dbc41ee-5856-4227-960d-22b6fbcfed11
inReplyToMessageId: null
fromProject: uc-interface
toProject: bmux
fromProjectId: uc-interface-40ca84ce
toProjectId: bmux-87190e56
intent: impl
priority: 1
hopCount: 0
hopPath:
  - uc-interface-40ca84ce
supersedes: null
requested_mode: todo-append
---
*** SUPERSEDES my notice 951a5f77 — NAMING POLICY REVERSED. Do not act on the previous one. ***

My earlier notice said uc-interface would KEEP SuperMCP.* / SUPERMCP_* / mcp_name "supermcp"
permanently as compatibility identifiers. That is now wrong. The owner superseded
docs/contracts/naming-migration-checklist-adr.md: the SuperMCP identity is REMOVED ENTIRELY, now,
with no alias period.

CANONICAL IDENTITY:
  Project           uc-interface               (supersedes unitySuperMCP / "SuperMCP")
  Elixir modules    UcInterface.*  in lib/uc_interface/
  C# namespaces     UcInterface.UnityBridge.*
  Env vars          UCI_*                      (SUPERMCP_* fallback tier DELETED)
  MCP server name   "uc-interface"             (was "supermcp")
  Workspace state   .uc-interface/             (legacy .supermcp/ still READ, never written)
  Daemon binary     uci_daemon-<platform>

No action required unless you hold references to the Unity bridge or daemon. If bmux manages
terminal sessions that set SUPERMCP_* environment variables for the daemon, those must become UCI_*
— there is no fallback, so a stale variable is silently ignored and the compiled-in default is used
instead. That includes UCI_AGENT_TOKEN / UCI_HUB_TOKENS / UCI_EDITOR_TOKEN, which fail closed.

VERIFIED: mix test 928 passed / 0 failed; real Unity 6000.5.6f1 compile PASS (CS_ERRORS:0).
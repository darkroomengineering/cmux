# `programa.json`

Custom command-palette entries, shareable via git. Programa looks for `programa.json`
(falling back to the legacy `cmux.json`) by walking up from the focused workspace's current
directory, and always loads `~/.config/programa/programa.json` (or the legacy
`~/.config/cmux/cmux.json`) as a global fallback. Local entries take precedence over global ones
with the same `name`.

The Swift structs in `Sources/ProgramaConfig.swift` (`ProgramaConfigFile`,
`ProgramaCommandDefinition`, `ProgramaRecipeDefinition`, `ProgramaParameterDefinition`, ...) are
the authoritative schema; this file is a human-readable summary. Comments (`//`, `/* */`) and
trailing commas are accepted (JSONC).

```jsonc
{
  "commands": [ /* ... */ ],
  "recipes": [ /* ... */ ]
}
```

## Trust

`programa.json` can arrive by cloning someone else's repo, so it is treated as untrusted input
until the user explicitly trusts the directory it came from (the "Always trust commands from
this folder" checkbox on the confirmation dialog). Until then, every command and every recipe
is confirmed before it runs or sends anything, regardless of what the file itself says. See
`ProgramaConfigExecutor.requiresConfirmation` for the exact rule.

## `commands`

Each entry is either a `workspace` command (opens/recreates a named workspace with a saved
layout) or a `command` command (types a shell command into the focused terminal and submits it).

```jsonc
{
  "name": "Run tests",
  "description": "Shown as the palette subtitle",
  "keywords": ["test", "ci"],
  "command": "npm test",
  "confirm": false
}
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | required, non-blank |
| `description` | string? | palette subtitle; falls back to `"programa.json"` |
| `keywords` | string[]? | extra palette search terms |
| `command` | string? | shell text, submitted with a trailing newline. Mutually exclusive with `workspace` -- exactly one of the two is required |
| `workspace` | object? | `{name?, cwd?, color?, layout?}` -- opens a workspace, optionally with a saved pane/split layout |
| `restart` | `"recreate" \| "ignore" \| "confirm"`? | what to do if a workspace with the same name already exists (workspace commands only) |
| `confirm` | bool? | forces the confirmation dialog even in a trusted directory ("ask me anyway") |
| `parameters` | array? | see below; substituted into `command` before it runs |

## `recipes`

A recipe fills a text prompt template and delivers it into the focused terminal for the user to
review and send themselves -- it never runs anything and never auto-submits. This is the
mechanism for a shared, git-tracked library of prompts to hand a coding agent, without letting a
cloned repo fire attacker-chosen text straight at that agent.

```jsonc
{
  "name": "Fix a bug",
  "description": "Ask the agent to fix a specific bug",
  "keywords": ["bug", "fix"],
  "prompt": "Please fix the bug in {{file}}: {{description}}",
  "parameters": [
    { "name": "file", "prompt": "File path" },
    { "name": "description", "prompt": "What's wrong", "default": "it crashes" }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | required, non-blank |
| `description` | string? | palette subtitle; falls back to `"programa.json"` |
| `keywords` | string[]? | extra palette search terms |
| `prompt` | string | required, non-blank. May contain `{{name}}` placeholders |
| `parameters` | array? | see below |

Selecting a recipe: collects any declared parameter values, substitutes them into `prompt`, goes
through the same confirmation gate as a command (showing the **fully substituted** prompt, never
the raw template), then types the result into the focused terminal **without** a trailing
newline. Nothing is sent until the user presses Return themselves.

## `parameters` (commands and recipes)

```jsonc
{ "name": "branch", "prompt": "Branch name", "default": "main" }
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | referenced in the template as `{{name}}` |
| `prompt` | string? | label shown when asking for a value; defaults to `name` |
| `default` | string? | pre-filled value |

Selecting a command or recipe with `parameters` prompts once per declared parameter, in
declaration order, via a simple text-field dialog. Canceling any prompt aborts the whole thing --
nothing runs or is sent.

Substitution replaces every `{{name}}` occurrence with the collected value. A `{{...}}` that
matches no declared parameter is left **literal** (including its braces) -- it is never an error
and never stripped. Substituted values are **not** shell-quoted in `command` templates: the user
typed them, and quoting would break legitimate uses like passing flags. The confirmation dialog
showing the final substituted string is the control here, not escaping.

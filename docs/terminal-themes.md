# Terminal themes

Programa reads the themes installed with its embedded Ghostty, Ghostty's standard user theme directories, and any directories configured through `GHOSTTY_RESOURCES_DIR` or `XDG_DATA_DIRS`.

Choose separate light and dark themes in **Settings → Appearance → Terminal**. Changes apply to every open terminal without relaunching Programa. Choosing **Use Ghostty Configuration** removes Programa's managed override and returns theme selection to your Ghostty config.

The same selection is available from the CLI:

```bash
programa themes list
programa themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
programa themes clear
```

Both surfaces write the managed block in `~/Library/Application Support/com.darkroom.programa/config.ghostty`, preserving unrelated directives in that file.

## settings.json

Set `app.terminalTheme` in `~/.config/programa/settings.json` to manage the selection as configuration:

```jsonc
{
  "app": {
    "terminalTheme": {
      "light": "Catppuccin Latte",
      "dark": "Catppuccin Mocha"
    }
  }
}
```

While this key is present, the Settings pickers are read-only. Removing the key restores the theme selection that was active before `settings.json` took ownership. Set the value to `null` (or set both variants to `null`) to explicitly inherit your Ghostty configuration while keeping the setting file-managed.

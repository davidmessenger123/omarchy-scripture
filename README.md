# Scripture

A random Bible verse shown on a full-screen dark scrim — the same layer-shell
surface Omarchy's speed tests use, with no card or border behind the text.

Click the book icon in the Omarchy bar to open the overlay. Esc, clicking the
scrim, or clicking the icon again closes it. **Right-click** the icon to open a
small key panel where you can paste, save, remove, or fetch an ESV API key.

## Install

```sh
omarchy plugin add https://github.com/davidmessenger123/omarchy-scripture.git --enable
```

The bar asks where to place the book icon; `omarchy bar move davidjm.scripture -s right`
moves it afterwards if you change your mind.

## Remove

```sh
omarchy plugin remove davidjm.scripture
```

The saved API key (if any) lives in `esv.key` inside the plugin directory and
is removed automatically. No other files are touched.

---

While the overlay is open, treat
it like the speed test overlay:

- **Enter / Return** — another random verse
- **Another Verse** button — another random verse
- **Open on esv.org / Open in browser** — read the passage online

## Translation

The default text source is the **English Standard Version** via Crossway's
[api.esv.org](https://api.esv.org). ESV is a copyrighted text, so fetching it
requires a free API key:

1. Create a Crossway account and an API application at
   https://api.esv.org/account/create-application/ (the "Get a key" button in
   the right-click panel opens this page for you).
2. **Right-click the bar icon → paste the key → Save.** The key lands in a
   `esv.key` file beside this plugin with `umask 077`, so the token never has to
   appear in shell.json or any visible config. Or, alternatively, set it in the
   widget's inline `settings.apiKey` entry in
   `~/.config/omarchy/shell.json` (this also unlocks the schema field shown by
   the plugin manager). A key in `shell.json` takes precedence over the file.
3. "Remove" deletes the saved key and falls back to keyless World English Bible
   verses immediately.

Without a key the plugin falls back to a **keyless random World English Bible**
verse from bible-api.com and labels the caption accordingly, so the button keeps
working before you configure anything.

## Notes

- Each pick shows a **short centered passage** — the anchor verse with the two
  verses before and after it — so brief verses never appear without context.
  The anchor verse is bright with the surrounding verses dimmed, and `[n]`
  verse markers keep the numbering visible. (A couple of references, like
  "1 John", can't be fetched as a range by the keyless fallback; the widget
  then falls back to the plain single verse.)
- Anchors are picked at random from a curated list of ~220 well-known,
  always-valid references, so a request can never throw a nonexistent
  chapter:verse.
- The ESV API is rate limited (60/min, 1k/hour, 5k/day); each icon click
  fetches at most one passage.
- Section quoting of ESV text must include cross references to the ESV terms of
  use; see the ESV copyright notice for redistribution rules.
# Scripture

A Bible verse shown on a full-screen dark scrim — the same layer-shell
surface Omarchy's speed tests use, with no card or border behind the text.

Click the book icon in the Omarchy bar to open the overlay. Esc, clicking the
scrim, or clicking the icon again closes it. **Right-click** the icon to open a
settings panel with two sections: the ESV API key manager (paste, save, remove,
or fetch a key) and a **Verse & Schedule** editor for the translation, the
fixed verse of the day, and the daily auto-open time.

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
is removed automatically. Saved favorite references live in `favorites.json`;
remove the whole plugin directory to delete those too.

---

While the overlay is open, treat it like the speed test overlay:

- **Enter / Return** — another random verse
- **◀ / ▶** — step back / forward through this session's history
- **Another Verse** button — another random verse (shows **Repeat** when a
  fixed verse is configured)
- **☆ / ★** — save or remove the current reference from favorites
- **JUMP TO** field — open any reference directly, e.g. `John 3:16`
- Favorite chips — one click opens a saved reference again
- **Open on esv.org / Open in browser** — read the current passage online

The bar icon's hover tooltip always shows the most recently read reference.

## Translation

The widget's **Translation** setting selects **ESV** (English Standard
Version), **WEB** (World English Bible), or **KJV** (King James Version):

- **ESV** is a copyrighted text, fetched through Crossway's
  [api.esv.org](https://api.esv.org); it requires a free API key:
  1. Create a Crossway account and an API application at
     https://api.esv.org/account/create-application/ (the "Get a key" button
     in the right-click panel opens this page for you).
  2. **Right-click the bar icon → paste the key → Save.** The key lands in a
     `esv.key` file beside this plugin with `umask 077`, so the token never has
     to appear in shell.json or any visible config. Or, alternatively, set it
     in the widget's inline `settings.apiKey` entry in
     `~/.config/omarchy/shell.json` (this also unlocks the schema field shown
     by the plugin manager). A key in `shell.json` takes precedence over the
     file.
  3. "Remove" deletes the saved key; the ESV then falls back to WEB/KJV.
  Without a key and with ESV selected, the widget shows the World English Bible
  and notes why.
- **WEB** and **KJV** are public-domain translations served keylessly by
  bible-api.com, so the button works before you configure anything.

## Verse of the day / auto-open

Configure these from **right-click → Verse & Schedule → Apply** (they persist
to the widget's `settings` in shell.json and apply live), or edit shell.json
directly:

- **Fixed verse (overrides random)** — a reference like `John 3:16` pins the
  verse of the day: the overlay always opens to it, the main button becomes
  **Repeat**, and the bar tooltip quotes it.
- **Auto-open daily at (HH:MM)** — e.g. `07:30`; the overlay opens by itself at
  that time each day (using the fixed verse if one is set).

## Notes

- Each pick shows a **short centered passage** — the anchor verse with the two
  verses before and after it — so brief verses never appear without context.
  The anchor verse is bright with the surrounding verses dimmed, and `[n]`
  verse markers keep the numbering visible. (A couple of references, like
  "1 John", can't be fetched as a range by the keyless fallback; the widget
  then falls back to the plain single verse.)
- Random picks rotate through a **no-repeat deck** built from a curated list of
  ~220 well-known, always-valid references, so a request can never throw a
  nonexistent chapter:verse and no verse repeats until the whole deck is seen.
- Session history (◀/▶) and favorites are separate: back/forward works while
  the widget runs; favorites persist in `favorites.json` beside the plugin
  (written atomically and symlink-safe, like the key file).
- The ESV API is rate limited (60/min, 1k/hour, 5k/day); each icon click
  fetches at most one passage.
- Section quoting of ESV text must include cross references to the ESV terms of
  use; see the ESV copyright notice for redistribution rules.
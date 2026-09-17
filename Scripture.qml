import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Scripture.js" as Scripture

// Scripture — a Bible verse on the same full-screen dark scrim Omarchy's speed
// tests use, with no card behind it. One bar icon toggles the overlay; Esc, the
// scrim, or the icon again closes it. Verses rotate through the curated no-repeat
// deck (ESV with an api.esv.org key; keyless WEB/KJV via bible-api.com), take
// jumps to any reference, keep session history (Back/Forward), and can be saved
// as favorites. A fixedReference pins the verse of the day, and autoOpenAt pops
// the overlay open at a configured time each day.
BarWidget {
  id: root

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property bool overlayOpen: false
  property bool keyPanelOpen: false
  property bool loading: false
  property string errorText: ""
  property string contextBefore: ""
  property string contextAfter: ""
  property string verseText: ""
  property string verseReference: ""
  property string translationId: ""
  property string translationName: "English Standard Version"
  property string keyFromFile: ""
  property string keyNotice: ""
  property bool keyNoticeError: false
  property string verseAnchor: ""
  property string pendingReference: ""
  property string pendingAnchor: ""
  property int pendingFocal: 0
  property bool webRetried: false
  property bool esvRetried: false
  property string pendingKey: ""
  property string fetchNotice: ""
  property string liveTooltip: "Scripture — a random verse (right-click: ESV API key)"
  property var history: []
  property int histPos: -1
  property var favorites: []
  property var favoritesChipsModel: []
  property string pendingFav: ""
  property string currentWebTranslation: "web"
  property string lastAutoOpenDay: ""
  // Right-click panel verse & schedule editor state (seeded from settings
  // every time the panel opens, then written back via updateEntryInline).
  property string panelTranslation: ""
  property string panelFixedReference: ""
  property string panelAutoOpenAt: ""
  property string versionNotice: ""
  property bool versionNoticeError: false
  // Bumped whenever panel settings are seeded or saved; the key-panel status
  // text references it so it re-evaluates after a live settings patch (QML
  // cannot track dependencies through function bodies like keyStatusText()).
  property int settingsRev: 0

  // QML bindings cannot see into function bodies, so keep a tracked copy of
  // the (at most 8) favorite chips for the Repeater and refresh it whenever
  // the list changes.
  onFavoritesChanged: root.favoritesChipsModel = root.favoriteChips()

  // Absolute path to this plugin's folder (trailing slash), resolved from the
  // QML file itself so keyctl.py is found wherever the plugin lives.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  readonly property bool hasContent: contextBefore !== "" || verseText !== "" || contextAfter !== ""
  readonly property bool hasKeyFile: root.keyFromFile.trim() !== ""
  readonly property bool hasInlineKey: root.setting("apiKey", "") !== ""
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The scrim below is a fixed near-black regardless of theme, so text on it
  // needs a fixed light palette, not the themed bar.foreground.
  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  readonly property color onScrimUrgent: "#ff6b6b"
  // Decorative monospace flanks for the verse, drawn with the same full-block
  // `█` characters the Omarchy screensaver logo uses. The art is symmetric,
  // so one string serves both sides and stays on the fixed overlay palette.
  readonly property string crossArt: "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "  ███████████\n" +
    "  ███████████\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███\n" +
    "      ███"
  readonly property int crossFontSize: Math.round(Style.font.displayLarge * 1.5)
  // Typewriter reveal: once a verse lands its characters stream in over
  // ~revealDurationMs instead of the whole passage snapping on. `revealedChars`
  // -1 means "show it all".
  property int revealedChars: -1
  property int revealTotal: 0
  property int revealStep: 1
  readonly property int revealIntervalMs: 16
  readonly property int revealDurationMs: 2200
  readonly property real revealProgress: root.revealedChars < 0 ? 1
    : root.revealTotal > 0 ? Math.min(1, root.revealedChars / root.revealTotal) : 1
  readonly property string composedHtml: ""
  readonly property real verseMaxWidth: Math.min(
    keyCatcher.width - Style.space(96),
    Style.space(760))

  function startReveal() {
    root.composedHtml = Scripture.composeRichText(root.contextBefore, root.verseText, root.contextAfter)
    root.revealTotal = (root.contextBefore + root.verseText + root.contextAfter).length
    root.revealStep = Math.max(1, Math.ceil(root.revealTotal * root.revealIntervalMs / root.revealDurationMs))
    root.revealedChars = 0
    revealTimer.restart()
  }

  // In-session passage cache: a successful fetch is reused within cacheTtlMs,
  // so re-opening the verse of the day or walking Back/Forward never re-hits
  // the API (and the ESV quota).
  property var passageCache: ({})
  readonly property int cacheTtlMs: 4 * 60 * 60 * 1000

  function passageCacheKey() {
    return root.providerChoice() + "|" + root.pendingReference
  }

  function cachedPassage() {
    var entry = root.passageCache[root.passageCacheKey()]
    if (!entry || Date.now() - entry.at > root.cacheTtlMs) return null
    return entry
  }

  function applyCached(entry) {
    root.translationId = entry.translationId
    root.translationName = entry.translationName
    root.verseReference = entry.reference
    root.contextBefore = entry.before
    root.verseText = entry.focal
    root.contextAfter = entry.after
    root.loading = false
    fetchTimeout.stop()
    root.startReveal()
  }

  function rememberPassage() {
    root.passageCache[root.passageCacheKey()] = {
      at: Date.now(),
      translationId: root.translationId,
      translationName: root.translationName,
      reference: root.verseReference,
      before: root.contextBefore,
      focal: root.verseText,
      after: root.contextAfter
    }
  }

  // Preferred key source: the widget's inline shell.json entry, then an
  // optional `esv.key` file beside the plugin so the token never has to live
  // in visible config text.
  function apiKey() {
    var value = root.setting("apiKey", "")
    if (value && String(value).trim()) return String(value).trim()
    if (root.keyFromFile) return root.keyFromFile.trim()
    return ""
  }

  // The configured translation, one of "esv" / "web" / "kjv" — folded to
  // lowercase so a verbatim schema enum value ("ESV") matches either way.
  function providerChoice() {
    var choice = String(root.setting("translation", "esv")).trim().toLowerCase()
    if (choice === "kjv") return "kjv"
    if (choice === "web") return "web"
    return "esv"
  }

  // Pull a short centered passage around `anchor` so a tiny verse is never
  // shown without its neighbors. `recordHistory` adds the anchor to session
  // history; skip it for Back/Forward replays.
  function fetchAnchor(anchor, recordHistory) {
    root.errorText = ""
    root.fetchNotice = ""
    root.pendingReference = Scripture.rangeQuery(anchor)
    root.pendingAnchor = anchor
    root.pendingFocal = Scripture.focalVerse(anchor)

    var cached = root.cachedPassage()
    if (cached) {
      if (recordHistory) root.recordHistory(anchor)
      root.applyCached(cached)
      return
    }

    root.loading = true
    fetchTimeout.restart()
    root.webRetried = false
    root.esvRetried = false
    if (recordHistory) root.recordHistory(anchor)

    var key = root.apiKey()
    var choice = root.providerChoice()
    if (choice === "esv" && key) {
      Scripture.runEsv(esvProcess, root.pendingReference, root.pluginDir)
      esvProcess.write(key + "\n")
      return
    }
    if (choice === "esv") {
      root.fetchNotice = "Set an ESV API key in the widget options to read the ESV — showing the World English Bible."
    }
    root.currentWebTranslation = choice === "kjv" ? "kjv" : "web"
    Scripture.runWeb(randomProcess, root.pendingReference, root.currentWebTranslation)
  }

  function refresh() {
    if (root.loading) return
    // A fixedReference pins the verse of the day: every open and every press
    // of the main button shows that reference instead of rotating.
    var fixed = String(root.setting("fixedReference", "")).trim()
    if (fixed) {
      root.verseAnchor = fixed
      root.fetchAnchor(fixed, true)
      return
    }
    // No-repeat rotation: never repeat a reference until the whole curated
    // deck has been shown.
    var anchor = Scripture.randomReference(root.verseAnchor)
    root.verseAnchor = anchor
    root.fetchAnchor(anchor, true)
  }

  // Jump to any reference the user types, e.g. "John 3:16". It feeds the same
  // pipeline as a rotation draw and is recorded in history. A jump still
  // respects the fixedReference for future draws (the pinned verse stays the
  // verse of the day, but the user can browse around it).
  function loadReference(reference) {
    var ref = String(reference === null || reference === undefined ? "" : reference).trim()
    if (!ref) return
    root.overlayOpen = true
    root.verseAnchor = ref
    root.fetchAnchor(ref, true)
  }

  // Session history: every fetched anchor is appended and `histPos` points at
  // the current verse; Back/Forward walk the list. Capped at 200 entries so a
  // long session cannot grow without bound.
  function recordHistory(anchor) {
    var list = root.history.slice()
    if (list.length > 0 && list[list.length - 1] === anchor) return
    root.history = list.concat(anchor).slice(-200)
    root.histPos = root.history.length - 1
  }

  function back() {
    if (root.histPos <= 0) return
    root.histPos--
    root.fetchAnchor(root.history[root.histPos], false)
  }

  function forward() {
    if (root.histPos < 0 || root.histPos >= root.history.length - 1) return
    root.histPos++
    root.fetchAnchor(root.history[root.histPos], false)
  }

  function isFavorite(anchor) {
    var target = String(anchor === null || anchor === undefined ? "" : anchor)
    for (var i = 0; i < root.favorites.length; i++) {
      if (root.favorites[i] === target) return true
    }
    return false
  }

  // Toggle the current verse's favorite status. Persisted to .favorites.json
  // beside the plugin by favorites.py (non-secret, atomic, symlink-safe). On
  // success the list is re-read so the star and chips update.
  function toggleFavorite() {
    var anchor = root.verseAnchor || root.pendingAnchor
    if (!anchor) return
    root.pendingFav = anchor
    favoritesWriteProcess.command = [
      "python3", root.pluginDir + "favorites.py",
      root.isFavorite(anchor) ? "remove" : "add", anchor
    ]
    favoritesWriteProcess.running = true
  }

  // At most 8 favorite chips in the overlay; more can live in .favorites.json.
  function favoriteChips() {
    var chips = []
    var n = Math.min(8, root.favorites.length)
    for (var i = 0; i < n; i++) chips.push(root.favorites[i])
    return chips
  }

  function removeFavorite(anchor) {
    favoritesWriteProcess.command = [
      "python3", root.pluginDir + "favorites.py",
      "remove", anchor
    ]
    favoritesWriteProcess.running = true
  }

  // Right-click panel status, reflecting the chosen translation.
  function keyStatusText() {
    var choice = root.providerChoice()
    var live = choice === "esv"
      ? "the ESV"
      : choice === "kjv" ? "the King James Version" : "the World English Bible"
    if (root.hasInlineKey || root.hasKeyFile) {
      if (root.hasInlineKey) return "Key set in shell.json — showing " + live + "."
      return "Key saved (…" + root.keyFromFile.slice(-4) + ") — showing " + live + "."
    }
    if (choice === "esv") return "No key — set one for the ESV, or choose WEB/KJV in the widget options."
    return "No key — verses come keyless from " + live + "."
  }

  // Daily auto-open: at the configured HH:MM the overlay pops open (and shows
  // the fixedReference if one is set). Fires at most once per day, so the
  // timer keeps polling without re-opening mid-minute.
  function checkAutoOpen() {
    var target = String(root.setting("autoOpenAt", "")).trim()
    if (!target) return
    var date = new Date()
    var hh = ("0" + date.getHours()).slice(-2)
    var mm = ("0" + date.getMinutes()).slice(-2)
    var now = hh + ":" + mm
    var day = String(date.getFullYear()) + "-" + String(date.getMonth() + 1) + "-" + date.getDate()
    if (now !== target || root.lastAutoOpenDay === day) return
    root.lastAutoOpenDay = day
    root.keyPanelOpen = false
    root.overlayOpen = true
    // onVisibleChanged below refreshes the verse once the surface is mapped.
  }

  Component.onCompleted: {
    root.favoritesChipsModel = root.favoriteChips()
    var fixed = String(root.setting("fixedReference", "")).trim()
    if (fixed) root.liveTooltip = "Scripture — daily verse: " + fixed
  }

  // Fail-safe: never leave the overlay stuck on the loading dots if a fetch
  // process is lost or dies silently.
  Timer {
    id: fetchTimeout
    interval: 25000
    onTriggered: {
      if (!root.loading) return
      esvProcess.running = false
      randomProcess.running = false
      root.loading = false
      root.errorText = "The verse fetch timed out. Try again."
    }
  }

  // Advances the typewriter reveal until the whole passage is on screen.
  Timer {
    id: revealTimer
    interval: root.revealIntervalMs
    repeat: true
    onTriggered: {
      root.revealedChars = Math.min(root.revealTotal, root.revealedChars + root.revealStep)
      if (root.revealedChars >= root.revealTotal) {
        root.revealedChars = root.revealTotal
        revealTimer.running = false
      }
    }
  }

  // Polls once every 30 s for the configured daily auto-open time. Only armed
  // when a time is actually configured, so an unset schedule costs no polling.
  Timer {
    id: autoOpenTimer
    interval: 30000
    repeat: true
    running: String(root.setting("autoOpenAt", "")).trim() !== ""
    onTriggered: root.checkAutoOpen()
  }

  function toggle() {
    root.keyPanelOpen = false
    root.overlayOpen = !root.overlayOpen
  }

  function toggleKeyPanel() {
    root.overlayOpen = false
    root.keyPanelOpen = !root.keyPanelOpen
    if (root.keyPanelOpen) {
      root.keyNotice = ""
      root.keyNoticeError = false
      root.versionNotice = ""
      root.versionNoticeError = false
      root.seedPanel()
    }
  }

  // Refresh the translation / fixed verse / auto-open fields from the live
  // settings every time the panel opens (and after a save).
  function seedPanel() {
    root.panelTranslation = String(root.setting("translation", "ESV")).trim() || "ESV"
    root.panelFixedReference = String(root.setting("fixedReference", "")).trim()
    root.panelAutoOpenAt = String(root.setting("autoOpenAt", "")).trim()
    root.settingsRev++
  }

  // Persist the verse & schedule fields to this widget's shell.json entry and
  // let the live shell patch the running widget. Merges with the existing
  // settings object so unrelated keys (like an inline apiKey) survive.
  function savePanelSettings() {
    var translation = String(root.panelTranslation || "ESV").trim().toUpperCase()
    if (translation !== "ESV" && translation !== "WEB" && translation !== "KJV") translation = "ESV"
    var fixed = String(root.panelFixedReference || "").trim()
    var auto = String(root.panelAutoOpenAt || "").trim()
    if (auto && !/^([01]\d|2[0-3]):[0-5]\d$/.test(auto)) {
      root.versionNotice = "Auto-open must be a 24-hour time like 07:30."
      root.versionNoticeError = true
      return
    }

    var merged = {}
    var cur = root.settings || {}
    for (var k in cur) merged[k] = cur[k]
    merged.translation = translation
    merged.fixedReference = fixed
    merged.autoOpenAt = auto

    root.versionNotice = ""
    root.versionNoticeError = false
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") {
      root.versionNotice = "The shell isn't offering settings saving for this widget."
      root.versionNoticeError = true
      return
    }
    var changed = root.bar.shell.updateEntryInline(root.moduleName, merged)
    root.seedPanel()
    if (changed) {
      root.versionNotice = "Saved — applied immediately."
    } else {
      root.versionNotice = "No changes to save."
    }
    root.versionNoticeError = false
  }

  function closeKeyPanel() {
    root.keyPanelOpen = false
  }

  // The KeyboardPanel routes its outside-click/close through `owner`. Bar popout
  // coordination (another panel opening while ours is open) uses the same two
  // entry points, so both funnel here.
  function close() {
    root.closeKeyPanel()
  }
  function closeForPopoutSwitch() {
    root.closeKeyPanel()
  }

  function saveKey() {
    var value = keyInput.text.trim()
    if (!value) {
      root.keyNotice = "Paste a key first."
      root.keyNoticeError = true
      return
    }
    root.pendingKey = value
    keyWriteProcess.command = ["python3", root.pluginDir + "keyctl.py", "save"]
    keyWriteProcess.running = true
    keyWriteProcess.write(value + "\n")
    keyInput.text = ""
    root.keyNotice = "Saving the ESV key…"
    root.keyNoticeError = false
  }

  function removeKey() {
    keyRemoveProcess.command = ["python3", root.pluginDir + "keyctl.py", "remove"]
    keyRemoveProcess.running = true
    root.keyNotice = "Removing the key…"
    root.keyNoticeError = false
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf02d"
    tooltipText: root.liveTooltip
    horizontalMargin: 8.25
    verticalPadding: 7.5

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.toggleKeyPanel()
      else root.toggle()
    }
  }

  // Right-click key manager. A free ESV key from Crossway unlocks the ESV
  // translation; without one the plugin serves a keyless translation (WEB or
  // KJV, per the `translation` option). The file lives beside the plugin
  // (esv.key), while a key pasted into shell.json's `apiKey` schema field
  // takes precedence over the file.
  KeyboardPanel {
    id: keyPanel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.keyPanelOpen
    focusTarget: keyInput
    contentWidth: keyPanel.fittedContentWidth(Style.space(352))
    contentHeight: keyPanel.fittedContentHeight(form.implicitHeight)

    PanelKeyCatcher {
      id: panelKeys
      anchors.fill: parent
      blocked: keyInput.activeFocus || fixedInput.activeFocus || autoInput.activeFocus
      onCloseRequested: root.closeKeyPanel()
      onActivateRequested: root.saveKey()
      onReturnRequested: root.saveKey()

      ColumnLayout {
        id: form
        anchors.fill: parent
        spacing: Style.space(10)

        Text {
          text: "ESV API KEY"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
        }

        RowLayout {
          spacing: Style.space(8)
          Layout.fillWidth: true

          Rectangle {
            id: statusDot
            width: 8
            height: 8
            radius: 4
            color: root.hasInlineKey || root.hasKeyFile ? "#3fb950" : Qt.darker(Color.foreground, 1.5)
          }

          Text {
            textFormat: Text.PlainText
            text: root.settingsRev >= 0 ? root.keyStatusText() : ""
            color: root.hasInlineKey || root.hasKeyFile ? Color.foreground : Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }
        }

        Text {
          visible: root.hasInlineKey
          text: "A key in shell.json takes precedence over the file below."
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        TextField {
          id: keyInput
          Layout.fillWidth: true
          font.pixelSize: Style.font.bodySmall
          placeholderText: "Paste your ESV API key (optional)"
          selectByMouse: true
          onAccepted: root.saveKey()
          Keys.onEscapePressed: root.closeKeyPanel()
          onActiveFocusChanged: if (activeFocus) selectAll()
        }

        RowLayout {
          spacing: Style.space(8)
          Layout.fillWidth: true

          Button {
            text: "Save"
            tooltipText: "Keep the key in the plugin's esv.key file"
            bordered: true
            selected: true
            enabled: keyInput.text.trim() !== ""
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(12)
            verticalPadding: Style.space(3)
            Layout.fillWidth: true
            onClicked: root.saveKey()
          }

          Button {
            text: "Remove"
            tooltipText: "Delete the saved key; ESV falls back to WEB/KJV"
            bordered: true
            visible: root.hasKeyFile
            enabled: root.hasKeyFile
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(12)
            verticalPadding: Style.space(3)
            onClicked: root.removeKey()
          }

          Button {
            text: "Get a key"
            tooltipText: "Free key from Crossway: api.esv.org/account/create-application/"
            bordered: true
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(12)
            verticalPadding: Style.space(3)
            Layout.fillWidth: true
            onClicked: {
              browseProcess.command = ["omarchy-launch-browser", "https://api.esv.org/account/create-application/"]
              browseProcess.running = true
              root.closeKeyPanel()
            }
          }
        }

        Text {
          text: root.keyNotice
          visible: root.keyNotice !== ""
          color: root.keyNoticeError ? Color.urgent : Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          height: 1
          color: Qt.darker(Color.foreground, 1.5)
        }

        Text {
          text: "VERSE & SCHEDULE"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
        }

        RowLayout {
          spacing: Style.space(6)
          Layout.fillWidth: true

          Text {
            text: "Translation"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            Layout.fillWidth: true
          }

          Button {
            text: "ESV"
            tooltipText: "English Standard Version (needs the ESV key)"
            bordered: true
            selected: root.panelTranslation.toUpperCase() === "ESV"
            fontFamily: Style.font.family
            fontSize: Style.font.caption
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onClicked: root.panelTranslation = "ESV"
          }

          Button {
            text: "WEB"
            tooltipText: "World English Bible (keyless)"
            bordered: true
            selected: root.panelTranslation.toUpperCase() === "WEB"
            fontFamily: Style.font.family
            fontSize: Style.font.caption
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onClicked: root.panelTranslation = "WEB"
          }

          Button {
            text: "KJV"
            tooltipText: "King James Version (keyless)"
            bordered: true
            selected: root.panelTranslation.toUpperCase() === "KJV"
            fontFamily: Style.font.family
            fontSize: Style.font.caption
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onClicked: root.panelTranslation = "KJV"
          }
        }

        RowLayout {
          spacing: Style.space(8)
          Layout.fillWidth: true

          Text {
            text: "Fixed verse"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            Layout.fillWidth: true
          }

          TextField {
            id: fixedInput
            Layout.preferredWidth: Style.space(150)
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.space(3)
            placeholderText: "e.g. John 3:16"
            text: root.panelFixedReference
            selectByMouse: true
            onEditingFinished: root.panelFixedReference = text.trim()
            onAccepted: root.panelFixedReference = text.trim()
          }
        }

        RowLayout {
          spacing: Style.space(8)
          Layout.fillWidth: true

          Text {
            text: "Auto-open"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            Layout.fillWidth: true
          }

          TextField {
            id: autoInput
            Layout.preferredWidth: Style.space(110)
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.space(3)
            placeholderText: "07:30"
            text: root.panelAutoOpenAt
            maximumLength: 5
            selectByMouse: true
            onEditingFinished: root.panelAutoOpenAt = text.trim()
            onAccepted: root.panelAutoOpenAt = text.trim()
          }
        }

        Button {
          text: "Apply"
          tooltipText: "Save the translation, fixed verse, and auto-open settings for this widget"
          bordered: true
          selected: true
          fontFamily: Style.font.family
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(12)
          verticalPadding: Style.space(3)
          Layout.fillWidth: true
          onClicked: root.savePanelSettings()
        }

        Text {
          text: root.versionNotice
          visible: root.versionNotice !== ""
          color: root.versionNoticeError ? Color.urgent : Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          height: 1
          color: Qt.darker(Color.foreground, 1.5)
        }

        Text {
          text: "FAVORITES"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
        }

        Text {
          visible: root.favorites.length === 0
          text: "No favorites yet — tap \u2606 on any verse to save it."
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        Rectangle {
          visible: root.favorites.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(root.favorites.length * 36, 180)
          color: "transparent"
          clip: true

          Flickable {
            anchors.fill: parent
            contentHeight: favColumn.implicitHeight
            contentWidth: parent.width
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
              id: favColumn
              width: parent.width
              spacing: 0

              Repeater {
                model: root.favorites

                RowLayout {
                  spacing: Style.space(6)
                  Layout.fillWidth: true
                  Layout.preferredHeight: 36

                  Text {
                    text: modelData
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }

                  Button {
                    text: "\u25B6"
                    tooltipText: "Load " + modelData
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(3)
                    onClicked: {
                      root.loadReference(modelData)
                      root.closeKeyPanel()
                    }
                  }

                  Button {
                    text: "\u00D7"
                    tooltipText: "Remove " + modelData + " from favorites"
                    bordered: true
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(3)
                    onClicked: root.removeFavorite(modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Optional key fallback source; runs once at startup and is a no-op when the
  // file isn't there. keyctl.py refuses symlinks, so a pre-positioned link can
  // never make this plugin read a file from somewhere else.
  Process {
    id: keyProcess
    command: ["python3", root.pluginDir + "keyctl.py", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      id: keyOutput
    }
    running: true
    onExited: {
      var value = keyOutput.text.trim()
      if (value) root.keyFromFile = value
    }
  }

  // Favorites are stored beside the plugin by favorites.py (atomic,
  // symlink-safe, non-secret). The list is read at startup and re-read after
  // every add/remove so the star and chips stay in sync.
  Process {
    id: favoritesLoadProcess
    command: ["python3", root.pluginDir + "favorites.py", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      id: favoritesOutput
    }
    running: true
    onExited: {
      try {
        var parsed = JSON.parse(favoritesOutput.text)
        root.favorites = Array.isArray(parsed) ? parsed : []
      } catch (e) {
        root.favorites = []
      }
    }
  }

  Process {
    id: favoritesWriteProcess
    running: false
    onExited: function(exitCode) {
      root.pendingFav = ""
      if (exitCode === 0) favoritesLoadProcess.running = true
    }
  }

  PanelWindow {
    id: overlay
    visible: root.overlayOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: Scripture.nextNamespace()
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // The window starts hidden, so re-acquire focus and draw a fresh verse
    // after the surface is actually mapped.
    onVisibleChanged: {
      if (visible) Qt.callLater(function() {
        if (!root.overlayOpen) return
        keyCatcher.forceActiveFocus()
        root.refresh()
      })
    }

    // Deep scrim: with no card behind the verse, the backdrop carries the
    // contrast on any wallpaper, exactly like the speed test overlays.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)

      MouseArea {
        anchors.fill: parent
        onClicked: root.overlayOpen = false
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.overlayOpen = false
      Keys.onReturnPressed: if (!root.loading) root.refresh()
      Keys.onEnterPressed: if (!root.loading) root.refresh()

      // The crosses hug the display edges rather than the scripture, so the
      // verse stays centered with the ornaments at fixed screen positions.
      Text {
        textFormat: Text.PlainText
        text: root.crossArt
        color: root.onScrimDim
        font.family: "monospace"
        font.pixelSize: root.crossFontSize
        lineHeight: 1.0
        anchors.left: keyCatcher.left
        anchors.leftMargin: Style.space(64)
        anchors.verticalCenter: keyCatcher.verticalCenter
        opacity: root.loading ? 0.45 : 1

        Behavior on opacity {
          NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: root.crossArt
        color: root.onScrimDim
        font.family: "monospace"
        font.pixelSize: root.crossFontSize
        lineHeight: 1.0
        anchors.right: keyCatcher.right
        anchors.rightMargin: Style.space(64)
        anchors.verticalCenter: keyCatcher.verticalCenter
        opacity: root.loading ? 0.45 : 1

        Behavior on opacity {
          NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
        }
      }

      Item {
        id: cluster
        anchors.centerIn: parent
        width: content.implicitWidth
        height: content.implicitHeight
        // Small or heavily scaled outputs: shrink the whole cluster rather
        // than clipping it at the screen edge.
        scale: Math.min(1,
          (keyCatcher.width - Style.space(32)) / Math.max(1, width),
          (keyCatcher.height - Style.space(32)) / Math.max(1, height))

        // Swallow clicks so only the scrim outside the cluster dismisses.
        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          id: content
          anchors.fill: parent
          spacing: Style.space(18)

          Text {
            textFormat: Text.PlainText
            visible: root.translationId !== ""
            text: root.translationName.toUpperCase()
            color: root.onScrimDim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 2
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: root.verseMaxWidth
            implicitWidth: verseTextItem.implicitWidth
            implicitHeight: verseTextItem.implicitHeight
            width: Math.min(verseTextItem.implicitWidth, root.verseMaxWidth)
            // The typewriter reveal is a growing clip over one statically
            // composed passage, so the rich text is parsed exactly once per
            // verse instead of being re-escaped and re-laid-out every tick.
            clip: true
            height: root.revealProgress * verseTextItem.implicitHeight

            Text {
              id: verseTextItem
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: root.verseMaxWidth
              textFormat: Text.RichText
              text: root.composedHtml !== "" ? root.composedHtml
                : (root.loading ? "…" : "")
              color: root.onScrim
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.weight: Font.Light
              lineHeight: 1.55
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
              // Keep the previous verse on screen (dimmed) while a refresh is
              // in flight, so the cluster never shifts or blanks.
              opacity: root.loading ? 0.45 : 1

              Behavior on opacity {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.verseReference !== ""
            text: root.verseReference
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.5
            Layout.alignment: Qt.AlignHCenter
          }

          RowLayout {
            spacing: Style.space(8)
            Layout.alignment: Qt.AlignHCenter

            Button {
              text: "◀"
              tooltipText: "Previous verse in this session"
              bordered: true
              enabled: root.histPos > 0 && !root.loading
              opacity: enabled ? 1 : 0.25
              foreground: root.onScrim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.back()
            }

            Button {
              text: "▶"
              tooltipText: "Next verse in this session"
              bordered: true
              enabled: root.histPos >= 0 && root.histPos < root.history.length - 1 && !root.loading
              opacity: enabled ? 1 : 0.25
              foreground: root.onScrim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.forward()
            }

            Button {
              text: root.setting("fixedReference", "") !== "" ? "Repeat" : "Another Verse"
              tooltipText: root.setting("fixedReference", "") !== "" ? "Show the fixed verse again" : "Get a different random verse"
              bordered: true
              enabled: !root.loading
              opacity: root.loading ? 0 : 1
              foreground: root.onScrim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(14)
              verticalPadding: Style.space(4)
              onClicked: root.refresh()

              Behavior on opacity {
                NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
              }
            }

            Button {
              id: favoriteButton
              text: root.favorites.indexOf(root.verseAnchor || root.pendingAnchor) !== -1 ? "★" : "☆"
              tooltipText: root.favorites.indexOf(root.verseAnchor || root.pendingAnchor) !== -1 ? "Remove from favorites" : "Save to favorites"
              bordered: true
              enabled: (root.verseAnchor || root.pendingAnchor) !== "" && !root.loading
              opacity: enabled ? 1 : 0.25
              foreground: root.favorites.indexOf(root.verseAnchor || root.pendingAnchor) !== -1 ? "#f5c542" : root.onScrimDim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.toggleFavorite()
            }

            Button {
              text: root.translationId === "esv" ? "Open on esv.org" : "Open in browser"
              tooltipText: "Read the passage online"
              bordered: true
              foreground: root.onScrimDim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(14)
              verticalPadding: Style.space(4)
              enabled: root.verseReference !== ""
              opacity: root.verseReference === "" ? 0.25 : 1
              onClicked: {
                if (root.verseReference === "") return
                browseProcess.command = [
                  "omarchy-launch-browser",
                  Scripture.browserUrl(root.verseReference, root.translationId)
                ]
                browseProcess.running = true
              }
            }
          }

          RowLayout {
            id: favoritesRow
            visible: root.favorites.length > 0
            spacing: Style.space(6)
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: keyCatcher.width - Style.space(96)

            Repeater {
              model: root.favoritesChipsModel
              Button {
                text: modelData
                tooltipText: "Open " + modelData
                bordered: true
                foreground: modelData === (root.verseAnchor || root.pendingAnchor) ? root.onScrim : root.onScrimDim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(2)
                onClicked: root.loadReference(modelData)
              }
            }

            Text {
              visible: root.favorites.length > 8
              text: "+" + (root.favorites.length - 8) + " more"
              color: root.onScrimDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          RowLayout {
            id: jumpRow
            spacing: Style.space(8)
            Layout.alignment: Qt.AlignHCenter

            Text {
              text: "JUMP TO"
              color: root.onScrimDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2
            }

            Rectangle {
              width: Style.space(240)
              height: 34
              radius: 6
              color: Qt.rgba(1, 1, 1, 0.12)
              border.color: Qt.rgba(1, 1, 1, 0.35)

              TextInput {
                id: jumpInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                color: root.onScrim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                selectByMouse: true
                onAccepted: root.loadReference(text)
              }

              // Faded hint shown only while the field is empty (this Qt
              // revision's TextInput lacks a placeholderText property, and a
              // plain Text overlays without stealing clicks from the input).
              Text {
                anchors.fill: jumpInput
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                visible: jumpInput.text === ""
                text: "e.g. John 3:16"
                color: Qt.rgba(1, 1, 1, 0.25)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                verticalAlignment: Text.AlignVCenter
              }
            }

            Button {
              text: "Go"
              tooltipText: "Jump to that reference"
              bordered: true
              foreground: root.onScrimDim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(12)
              verticalPadding: Style.space(4)
              onClicked: root.loadReference(jumpInput.text)
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.fetchNotice !== ""
            text: root.fetchNotice
            color: root.onScrimDim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.maximumWidth: Style.space(440)
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            text: root.errorText
            color: root.onScrimUrgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.maximumWidth: Style.space(440)
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Process {
    id: esvProcess
    property string requestedPassage: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      id: esvOutput
    }
    running: false
    onExited: function(exitCode) {
      if (!root.loading) return

      var payload = null
      try { payload = JSON.parse(esvOutput.text) } catch (e) {}

      if (exitCode === 3) {
        fetchTimeout.stop()
        root.errorText = "The ESV API limited the request. Wait a moment, then try again."
        root.loading = false
        return
      }

      // Some providers don't answer range queries for a few books (bible-api
      // chokes on "1 John 1:7-11"); fall back to the plain anchor verse once.
      if (exitCode !== 0 || !payload || !Array.isArray(payload.passages) || payload.passages.length === 0) {
        if (root.pendingAnchor && root.pendingAnchor !== root.pendingReference && !root.esvRetried) {
          root.esvRetried = true
          Scripture.runEsv(esvProcess, root.pendingAnchor, root.pluginDir)
          esvProcess.write(root.apiKey() + "\n")
          return
        }
        fetchTimeout.stop()
        root.errorText = "Could not load from the ESV API. Check your key and connection."
        root.loading = false
        return
      }

      var reference = String(payload.canonical || root.pendingReference || "").trim()
      var parts = Scripture.parseNumberedPassage(payload.passages[0], root.pendingFocal)
      root.translationId = "esv"
      root.translationName = "English Standard Version"
      root.verseReference = reference
      root.contextBefore = parts.before
      root.verseText = parts.focal
      root.contextAfter = parts.after
      root.esvRetried = false
      root.loading = false
      fetchTimeout.stop()
      root.rememberPassage()
      root.liveTooltip = "Scripture — " + reference + " (ESV)"
      root.startReveal()
    }
  }

  Process {
    id: randomProcess
    stdout: StdioCollector {
      waitForEnd: true
      id: randomOutput
    }
    running: false
    onExited: function(exitCode) {
      if (!root.loading) return

      var payload = null
      try { payload = JSON.parse(randomOutput.text) } catch (e) {}

      var bad = exitCode !== 0 || !payload || payload.error ||
        !Array.isArray(payload.verses) || payload.verses.length === 0
      if (bad) {
        if (root.pendingAnchor && root.pendingAnchor !== root.pendingReference && !root.webRetried) {
          root.webRetried = true
          Scripture.runWeb(randomProcess, root.pendingAnchor, root.currentWebTranslation)
          return
        }
        fetchTimeout.stop()
        root.errorText = "Could not load that passage. Try again."
        root.loading = false
        return
      }

      var versionId = root.currentWebTranslation === "kjv" ? "kjv" : "web"
      var versionName = Scripture.translationText(payload) ||
        (versionId === "kjv" ? "King James Version" : "World English Bible")
      var parts = Scripture.parseWebPassage(payload, root.pendingFocal)
      root.translationId = versionId
      root.translationName = versionName
      root.verseReference = Scripture.referenceText(payload) || root.pendingReference
      root.contextBefore = parts.before
      root.verseText = parts.focal
      root.contextAfter = parts.after
      root.webRetried = false
      root.loading = false
      fetchTimeout.stop()
      root.rememberPassage()
      root.liveTooltip = "Scripture — " + root.verseReference + " (" + versionName + ")"
      root.startReveal()
    }
  }

  Process {
    id: browseProcess
    running: false
  }

  // Key-file write/remove; result-aware so a refused (e.g. symlink) write
  // never reports a save. The file is re-read at next startup regardless.
  Process {
    id: keyWriteProcess
    stdinEnabled: true
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keyFromFile = root.pendingKey
        root.pendingKey = ""
        root.keyNotice = "Key saved — the next verse loads from the ESV."
        root.keyNoticeError = false
      } else {
        root.keyNotice = "Could not save the key."
        root.keyNoticeError = true
      }
    }
  }

  Process {
    id: keyRemoveProcess
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keyFromFile = ""
        root.keyNotice = "Key removed — ESV falls back to WEB/KJV."
        root.keyNoticeError = false
      } else {
        root.keyNotice = "Could not remove the key."
        root.keyNoticeError = true
      }
    }
  }
}
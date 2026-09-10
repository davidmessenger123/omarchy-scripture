import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Scripture.js" as Scripture

// Scripture — a random Bible verse on the same full-screen dark scrim Omarchy's
// speed tests use, with no card behind it. One bar icon toggles the overlay;
// Esc, the scrim, or the icon again closes it. Verses come from the ESV when
// an api.esv.org key is configured; otherwise the plugin falls back to a
// keyless random World English Bible verse from bible-api.com and labels it.
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

  readonly property bool hasContent: contextBefore !== "" || verseText !== "" || contextAfter !== ""
  readonly property bool hasKeyFile: root.keyFromFile.trim() !== ""
  readonly property bool hasInlineKey: root.setting("apiKey", "") !== ""
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The scrim below is a fixed near-black regardless of theme, so text on it
  // needs a fixed light palette, not the themed bar.foreground.
  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  readonly property color onScrimUrgent: "#ff6b6b"

  // Preferred key source: the widget's inline shell.json entry, then an
  // optional `esv.key` file beside the plugin so the token never has to live
  // in visible config text.
  function apiKey() {
    var value = root.setting("apiKey", "")
    if (value && String(value).trim()) return String(value).trim()
    if (root.keyFromFile) return root.keyFromFile.trim()
    return ""
  }

  function refresh() {
    if (root.loading) return
    root.loading = true
    root.errorText = ""
    fetchTimeout.restart()

    // Pull a short centered passage around a fresh anchor so a tiny verse is
    // never shown without its neighbors.
    var anchor = Scripture.randomReference(root.verseAnchor)
    root.verseAnchor = anchor
    root.pendingReference = Scripture.rangeQuery(anchor)
    root.pendingAnchor = anchor
    root.pendingFocal = Scripture.focalVerse(anchor)
    root.webRetried = false
    root.esvRetried = false

    var key = root.apiKey()
    if (key) Scripture.runEsv(esvProcess, root.pendingReference, key)
    else Scripture.runWeb(randomProcess, root.pendingReference)
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
    }
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
    keyWriteProcess.command = [
      "sh", "-c",
      'mkdir -p "$HOME/.config/omarchy/plugins/davidjm.scripture" && umask 077 && printf "%s" "$1" > "$HOME/.config/omarchy/plugins/davidjm.scripture/esv.key"',
      "scripture", value
    ]
    keyWriteProcess.running = true
    root.keyFromFile = value
    keyInput.text = ""
    root.keyNotice = "Key saved — the next verse loads from the ESV."
    root.keyNoticeError = false
  }

  function removeKey() {
    keyRemoveProcess.command = ["sh", "-c", 'rm -f "$HOME/.config/omarchy/plugins/davidjm.scripture/esv.key"']
    keyRemoveProcess.running = true
    root.keyFromFile = ""
    root.keyNotice = "Key removed — verses now come from the World English Bible."
    root.keyNoticeError = false
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf02d"
    tooltipText: "Scripture — a random verse (right-click: ESV API key)"
    horizontalMargin: 8.25
    verticalPadding: 7.5

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.toggleKeyPanel()
      else root.toggle()
    }
  }

  // Right-click key manager. A free ESV key from Crossway unlocks the ESV
  // translation; without one the plugin serves keyless World English Bible
  // verses. The file lives beside the plugin (esv.key), while a key pasted
  // into shell.json's `apiKey` schema field takes precedence over the file.
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
      blocked: keyInput.activeFocus
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
            text: root.hasInlineKey
              ? "Key set in shell.json — the ESV is live."
              : root.hasKeyFile
                ? "Key saved (…" + root.keyFromFile.slice(-4) + ") — the ESV is live."
                : "No key — verses come keyless from the World English Bible."
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
            tooltipText: "Delete the saved key and fall back to the World English Bible"
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
      }
    }
  }

  // Optional key fallback source; runs once at startup and is a no-op when the
  // file isn't there.
  Process {
    id: keyProcess
    command: ["sh", "-c", 'key="$HOME/.config/omarchy/plugins/davidjm.scripture/esv.key"; if [ -f "$key" ]; then tr -d "[:space:]" < "$key"; fi']
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

          Text {
            textFormat: Text.RichText
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: Math.min(
              keyCatcher.width - Style.space(96),
              Style.space(760))
            text: root.loading && !root.hasContent ? "…"
              : root.hasContent
                ? Scripture.composeRichText(root.contextBefore, root.verseText, root.contextAfter)
                : ""
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
            spacing: Style.space(12)
            Layout.alignment: Qt.AlignHCenter

            Button {
              text: "Another Verse"
              tooltipText: "Get a different random verse"
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
              text: root.translationId === "esv" ? "Open on esv.org" : "Open in browser"
              tooltipText: "Read the passage online"
              bordered: true
              foreground: root.onScrimDim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(14)
              verticalPadding: Style.space(4)
              enabled: root.verseReference !== ""
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
    stdout: StdioCollector {
      waitForEnd: true
      id: esvOutput
    }
    running: false
    onExited: function(exitCode) {
      if (!root.loading) return

      var payload = null
      try { payload = JSON.parse(esvOutput.text) } catch (e) {}

      // Some providers don't answer range queries for a few books (bible-api
      // chokes on "1 John 1:7-11"); fall back to the plain anchor verse once.
      if (exitCode !== 0 || !payload || !Array.isArray(payload.passages) || payload.passages.length === 0) {
        if (root.pendingAnchor && root.pendingAnchor !== root.pendingReference && !root.esvRetried) {
          root.esvRetried = true
          Scripture.runEsv(esvProcess, root.pendingAnchor, root.apiKey())
          return
        }
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
          Scripture.runWeb(randomProcess, root.pendingAnchor)
          return
        }
        root.errorText = "Could not load a random verse. Try again."
        root.loading = false
        return
      }

      var parts = Scripture.parseWebPassage(payload, root.pendingFocal)
      root.translationId = "web"
      root.translationName = Scripture.translationText(payload) || "World English Bible"
      root.verseReference = Scripture.referenceText(payload) || root.pendingReference
      root.contextBefore = parts.before
      root.verseText = parts.focal
      root.contextAfter = parts.after
      root.webRetried = false
      root.loading = false
    }
  }

  Process {
    id: browseProcess
    running: false
  }

  // Key-file write/remove; quiet by design — the notice text already reflects
  // the outcome, and the file is re-read at next startup if this crashes too
  // early to matter.
  Process {
    id: keyWriteProcess
    running: false
  }

  Process {
    id: keyRemoveProcess
    running: false
  }
}
.pragma library

// Scripture verse handling for the Scripture bar widget. Picking references
// from a curated list means "random" can never produce a nonexistent
// chapter:verse, and the request stays light even before a key is installed.

// Well-known, always-valid references drawn across the whole Bible. With an
// ESV key these feed api.esv.org verbatim (via esv_fetch.py, key on stdin so
// it never appears in argv); without one the plugin asks bible-api.com for a
// random World English Bible verse instead.
// Hard cap on any upstream response. A single short passage is a few KB, so
// 256 KiB leaves huge headroom while bounding how much a misbehaving or
// compromised endpoint can make the shared shell buffer. The keyless web
// curl aborts with exit 63 the moment its byte budget is spent; esv_fetch.py
// enforces the same ceiling inside the process.
var MAX_RESPONSE_BYTES = 262144

var SCRIPTURE = [
  "Genesis 1:1", "Genesis 1:27", "Genesis 2:18", "Genesis 12:2", "Genesis 28:15",
  "Exodus 14:14", "Exodus 15:2", "Exodus 20:12", "Exodus 33:14",
  "Leviticus 19:18", "Leviticus 26:12",
  "Numbers 6:24", "Numbers 23:19",
  "Deuteronomy 6:5", "Deuteronomy 31:6", "Deuteronomy 33:27",
  "Joshua 1:9", "Joshua 24:15",
  "Judges 6:24",
  "Ruth 1:16",
  "1 Samuel 16:7", "1 Samuel 12:24",
  "2 Samuel 22:31",
  "1 Kings 8:61",
  "2 Kings 19:19",
  "1 Chronicles 16:11",
  "2 Chronicles 7:14",
  "Ezra 7:10",
  "Nehemiah 8:10",
  "Job 1:21", "Job 19:25", "Job 42:2",
  "Psalm 1:1", "Psalm 16:11", "Psalm 19:1", "Psalm 23:1", "Psalm 23:4",
  "Psalm 27:1", "Psalm 30:5", "Psalm 32:8", "Psalm 34:8", "Psalm 37:4",
  "Psalm 37:5", "Psalm 46:1", "Psalm 46:10", "Psalm 55:22", "Psalm 62:8",
  "Psalm 91:1", "Psalm 103:12", "Psalm 118:24", "Psalm 119:105", "Psalm 127:1",
  "Psalm 133:1", "Psalm 139:14", "Psalm 145:18", "Psalm 150:6",
  "Proverbs 3:5", "Proverbs 3:6", "Proverbs 16:3", "Proverbs 17:17",
  "Proverbs 18:10", "Proverbs 27:17",
  "Ecclesiastes 3:1", "Ecclesiastes 12:13",
  "Song of Solomon 4:7",
  "Isaiah 40:8", "Isaiah 40:31", "Isaiah 41:10", "Isaiah 41:13", "Isaiah 43:2",
  "Isaiah 53:5", "Isaiah 55:8", "Isaiah 58:11",
  "Jeremiah 29:11", "Jeremiah 33:3", "Lamentations 3:22", "Ezekiel 34:15",
  "Daniel 2:20", "Hosea 6:6", "Joel 2:13", "Amos 5:24", "Jonah 2:2",
  "Micah 6:8", "Nahum 1:7", "Habakkuk 3:19", "Zephaniah 3:17", "Haggai 2:4",
  "Zechariah 4:6", "Malachi 3:10",
  "Matthew 5:14", "Matthew 6:33", "Matthew 6:34", "Matthew 7:7", "Matthew 11:28",
  "Matthew 28:20",
  "Mark 9:23", "Mark 11:24",
  "Luke 1:37", "Luke 6:38", "Luke 10:27", "Luke 12:32", "Luke 15:10",
  "John 1:29", "John 3:16", "John 6:35", "John 8:32", "John 10:10", "John 10:27",
  "John 11:25", "John 13:34", "John 14:6", "John 14:27", "John 15:5", "John 16:33",
  "Acts 1:8", "Acts 4:12", "Acts 16:31",
  "Romans 3:23", "Romans 5:8", "Romans 8:28", "Romans 8:38", "Romans 10:9",
  "Romans 12:2", "Romans 12:12", "Romans 15:13",
  "1 Corinthians 10:13", "1 Corinthians 13:4", "1 Corinthians 15:58",
  "1 Corinthians 16:14",
  "2 Corinthians 5:17", "2 Corinthians 5:18", "2 Corinthians 12:9",
  "Galatians 5:22", "Galatians 6:9",
  "Ephesians 2:8", "Ephesians 2:10", "Ephesians 3:20", "Ephesians 4:32",
  "Ephesians 6:10",
  "Philippians 4:4", "Philippians 4:6", "Philippians 4:8", "Philippians 4:13",
  "Philippians 4:19",
  "Colossians 3:2", "Colossians 3:23",
  "1 Thessalonians 5:16", "1 Thessalonians 5:18",
  "2 Thessalonians 3:3",
  "1 Timothy 2:5", "1 Timothy 4:12", "1 Timothy 6:12",
  "2 Timothy 1:7", "2 Timothy 2:15", "2 Timothy 3:16", "2 Timothy 4:7",
  "Titus 2:11", "Philemon 1:6",
  "Hebrews 10:35", "Hebrews 11:1", "Hebrews 11:6", "Hebrews 12:1", "Hebrews 12:2",
  "Hebrews 13:5", "Hebrews 13:8",
  "James 1:5", "James 1:17", "James 2:17", "James 4:8", "James 4:10", "James 5:16",
  "1 Peter 2:9", "1 Peter 5:7",
  "2 Peter 1:4", "2 Peter 3:9",
  "1 John 1:9", "1 John 4:7", "1 John 4:19", "1 John 5:14",
  "2 John 1:6",
  "3 John 1:2",
  "Jude 1:21",
  "Revelation 3:20", "Revelation 21:4", "Revelation 22:20"
]

// Each bar surface gets its own overlay window, so give each a unique layer
// namespace rather than risking a duplicate across monitors.
var _namespaceCounter = 0

function nextNamespace() {
  return "omarchy-scripture-" + (++_namespaceCounter)
}

function randomReference(avoid) {
  var reference = avoid
  for (var guard = 0; guard < 8 && reference === avoid; guard++) {
    reference = SCRIPTURE[Math.floor(Math.random() * SCRIPTURE.length)]
  }
  return reference
}

// api.esv.org returns a single passage string; collapse its line breaks into
// single spaces and drop any residual reference line or copyright suffix.
function cleanEsvText(raw, reference) {
  var text = String(raw === null || raw === undefined ? "" : raw)
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+/g, " ")
    .trim()

  if (reference) {
    var line = text.split("\n")[0].trim()
    if (line.toLowerCase() === String(reference).trim().toLowerCase()) {
      text = text.slice(line.length).replace(/^[\s\n]+/, "")
    }
  }

  text = text
    .replace(/\s*\(ESV\)\s*$/, "")
    .replace(/^\s*\[\d+\]\s*/gm, "")   // residual verse markers, if any
    .replace(/\n{2,}/g, "\n")
    .trim()

  return text
}

// bible-api.com's random response (or a generic one) collapses into display
// text. The random endpoint returns `random_verse.text`; older paths returned
// per-verse objects, so handle both.
function cleanWebText(payload) {
  var random = payload && payload.random_verse && payload.random_verse.text
  if (random) return String(random).replace(/\s{2,}/g, " ").trim()

  var verses = payload && Array.isArray(payload.verses) ? payload.verses : []
  if (verses.length === 0) {
    return String(payload && payload.text ? payload.text : "").trim()
  }

  var parts = []
  for (var i = 0; i < verses.length; i++) {
    var text = String(verses[i] && verses[i].text ? verses[i].text : "").trim()
    if (text) parts.push(text)
  }

  return parts.join(" ").replace(/\s{2,}/g, " ").trim()
}

// bible-api.com random responses aren't keyed by a `reference` field; build
// one from the verse object when present, otherwise use `reference` as-is.
function referenceText(payload) {
  if (payload && payload.random_verse) {
    var verse = payload.random_verse
    if (verse.book && verse.chapter && verse.verse) {
      return String(verse.book + " " + verse.chapter + ":" + verse.verse).trim()
    }
  }
  return String(payload && payload.reference ? payload.reference : "").trim()
}

function translationText(payload) {
  if (payload && payload.translation && payload.translation.name) {
    return String(payload.translation.name).trim()
  }
  return String(payload && payload.translation_name ? payload.translation_name : "")
}

function encodeReference(reference) {
  return encodeURIComponent(String(reference || "").trim())
}

// A single curated anchor reference ("John 3:16") becomes a short centered
// passage ("John 3:14-18") so a tiny verse is never shown without context.
function rangeQuery(reference, margin) {
  margin = margin === undefined ? 2 : margin
  var match = /^(.*?)\s+(\d+):(\d+)$/.exec(String(reference || "").trim())
  if (!match) return String(reference || "").trim()
  var book = match[1]
  var chapter = parseInt(match[2], 10)
  var verse = parseInt(match[3], 10)
  var start = Math.max(1, verse - margin)
  var end = verse + margin
  if (start === end) return book + " " + chapter + ":" + verse
  return book + " " + chapter + ":" + start + "-" + end
}

// Which verse number inside the fetched range is the curated anchor (the one
// to brighten)? 0 means "not derivable" -> treat the whole passage as focal.
function focalVerse(reference) {
  var match = /^.*?\s+\d+:(\d+)$/.exec(String(reference || "").trim())
  return match ? parseInt(match[1], 10) : 0
}

// Split a fetched passage into before / focal / after around an anchor verse
// number. Verse markers (`[n]`) carry the numbering into the display.
function parseNumberedPassage(text, focal) {
  var normalized = String(text || "")
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+/g, " ")
    .trim()

  var marker = /\[(\d+)\]([\s\S]*?)(?=\[\d+\]|$)/g
  var tokens = []
  var match
  while ((match = marker.exec(normalized)) !== null) {
    tokens.push({ n: parseInt(match[1], 10), t: match[2] })
  }

  if (tokens.length === 0) {
    return { before: "", focal: normalized.replace(/\n{2,}/g, "\n").trim(), after: "" }
  }

  var before = []
  var focalText = ""
  var after = []
  var found = false
  for (var i = 0; i < tokens.length; i++) {
    var verseText = tokens[i].t.replace(/\s+/g, " ").trim()
    if (verseText === "") continue
    if (tokens[i].n === focal && !found) {
      focalText = "[" + tokens[i].n + "] " + verseText
      found = true
    } else if (!found) {
      before.push("[" + tokens[i].n + "] " + verseText)
    } else {
      after.push("[" + tokens[i].n + "] " + verseText)
    }
  }

  if (!focalText) {
    var whole = []
    for (var j = 0; j < tokens.length; j++) {
      var vt = tokens[j].t.replace(/\s+/g, " ").trim()
      if (vt) whole.push("[" + tokens[j].n + "] " + vt)
    }
    return { before: "", focal: whole.join(" "), after: "" }
  }

  return { before: before.join(" "), focal: focalText, after: after.join(" ") }
}

// bible-api.com range responses carry `verses: [{number, text}]`; split them
// around the anchor the same way as the ESV response.
function parseWebPassage(payload, focal) {
  var verses = payload && Array.isArray(payload.verses) ? payload.verses : []
  var before = []
  var focalText = ""
  var after = []
  var found = false

  for (var i = 0; i < verses.length; i++) {
    var number = Number(verses[i] && (verses[i].verse || verses[i].number))
    var text = String(verses[i] && verses[i].text ? verses[i].text : "")
      .replace(/\s+/g, " ").trim()
    if (!text && !number) continue

    if (number === focal && !found) {
      focalText = "[" + number + "] " + text
      found = true
    } else if (!found) {
      before.push("[" + number + "] " + text)
    } else {
      after.push("[" + number + "] " + text)
    }
  }

  if (!focalText) {
    var whole = []
    for (var j = 0; j < verses.length; j++) {
      var vt = String(verses[j] && verses[j].text ? verses[j].text : "")
        .replace(/\s+/g, " ").trim()
      if (vt) whole.push(vt)
    }
    return { before: "", focal: whole.join(" "), after: "" }
  }

  return { before: before.join(" "), focal: focalText, after: after.join(" ") }
}

// One rich-text string: the leading context and trailing context dimmed, the
// anchor verse bright. All spans inherit the Text element's font size, so
// lines stay even. Falls back to a plain merge if HTML is undesirable later.
// `maxChars` optionally truncates reveal progress (chars across before →
// focal → after) for the typewriter effect; omit it (or -1) to show it all.
function composeRichText(before, focal, after, maxChars) {
  function span(color, content) {
    return content === "" ? "" : '<span style="color:' + color + ';">' + content + '</span>'
  }

  function escape(content) {
    return String(content)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br/>")
  }

  var b = String(before === null || before === undefined ? "" : before)
  var f = String(focal === null || focal === undefined ? "" : focal)
  var a = String(after === null || after === undefined ? "" : after)

  if (maxChars !== undefined && maxChars >= 0) {
    var bl = b.length
    var fl = f.length
    if (maxChars <= bl) {
      b = b.slice(0, maxChars)
      f = ""
      a = ""
    } else if (maxChars <= bl + fl) {
      f = f.slice(0, maxChars - bl)
      a = ""
    } else {
      a = a.slice(0, maxChars - bl - fl)
    }
  }

  return span("rgba(255,255,255,0.55)", escape(b)) +
    span("#ffffff", escape(f)) +
    span("rgba(255,255,255,0.55)", escape(a))
}

// Kick off an ESV fetch for one short passage. The caller owns the Process
// and its onExited handler. The API key is never placed in argv: the caller
// feeds it to this process's stdin after starting, and esv_fetch.py reads it
// there (the reference travels in argv, which contains no secret). The
// response cap from MAX_RESPONSE_BYTES is enforced inside esv_fetch.py.
function runEsv(process, reference, scriptDir) {
  process.requestedPassage = reference
  process.command = [
    "python3", String(scriptDir || "") + "esv_fetch.py",
    encodeReference(reference)
  ]
  process.running = true
}

// Kick off curl against bible-api.com for a keyless WEB passage range.
function runWeb(process, reference) {
  process.command = [
    "curl", "-s", "--max-time", "15", "--max-filesize", String(MAX_RESPONSE_BYTES),
    "https://bible-api.com/" + String(reference || "").trim().replace(/\s+/g, "+") +
      "?translation=web"
  ]
  process.running = true
}

function browserUrl(reference, translationId) {
  var slug = String(reference || "").replace(/\s+/g, "+")
  if (translationId === "esv") return "https://www.esv.org/" + slug + "/"
  return "https://www.biblegateway.com/passage/?search=" + slug + "&version=WEB"
}
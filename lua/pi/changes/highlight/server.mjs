#!/usr/bin/env node

/**
 * Persistent diff highlighting server for pi.nvim.
 *
 * Accepts JSONL commands on stdin, outputs JSONL responses on stdout.
 *
 * Request:  {"type":"highlight","id":"req-1","patch":"...","path":"src/main.ts"}
 * Response: {"type":"result","id":"req-1","success":true,"file":{...}}
 *
 * Supports two diff formats:
 * 1. Standard unified diff (git diff format) → @pierre/diffs + Shiki syntax highlighting
 * 2. Pi's custom diff format (edit tool) → direct parser + per-line syntax highlighting
 *
 * The server caches Shiki highlighters per language so subsequent
 * requests for the same language are nearly instant.
 */

import { createInterface } from "node:readline";
import {
  parsePatchFiles,
  getHighlighterOptions,
  getSharedHighlighter,
  renderDiffWithHighlighter,
  cleanLastNewline,
} from "@pierre/diffs";
import path from "node:path";

// Force stdout to be unbuffered (no kernel buffering for pipes).
// Without this, writes to a pipe are buffered until 4KB+ or process exit,
// and the Neovim client never sees the responses in real time.
if (process.stdout._handle?.setBlocking) {
  process.stdout._handle.setBlocking(true);
}

// ---------------------------------------------------------------------------
// Language detection – maps file extensions to Shiki language ids
// ---------------------------------------------------------------------------
const EXT_TO_LANG = {
  ".ts": "typescript",
  ".tsx": "tsx",
  ".js": "javascript",
  ".jsx": "jsx",
  ".mjs": "javascript",
  ".cjs": "javascript",
  ".mts": "typescript",
  ".cts": "typescript",
  ".vue": "vue",
  ".svelte": "svelte",
  ".astro": "astro",
  ".css": "css",
  ".scss": "scss",
  ".sass": "sass",
  ".less": "less",
  ".html": "html",
  ".xml": "xml",
  ".json": "json",
  ".jsonc": "jsonc",
  ".yaml": "yaml",
  ".yml": "yaml",
  ".toml": "toml",
  ".md": "markdown",
  ".mdx": "mdx",
  ".py": "python",
  ".rb": "ruby",
  ".rs": "rust",
  ".go": "go",
  ".java": "java",
  ".kt": "kotlin",
  ".swift": "swift",
  ".c": "c",
  ".h": "c",
  ".cpp": "cpp",
  ".hpp": "cpp",
  ".cs": "csharp",
  ".php": "php",
  ".r": "r",
  ".sh": "shellscript",
  ".bash": "shellscript",
  ".zsh": "shellscript",
  ".fish": "shellscript",
  ".lua": "lua",
  ".vim": "vimscript",
  ".sql": "sql",
  ".graphql": "graphql",
  ".gql": "graphql",
  ".proto": "protobuf",
  ".zig": "zig",
  ".dart": "dart",
  ".ex": "elixir",
  ".exs": "elixir",
  ".clj": "clojure",
  ".cljs": "clojure",
  ".scala": "scala",
  ".hs": "haskell",
  ".ml": "ocaml",
  ".sml": "sml",
  ".erl": "erlang",
  ".elm": "elm",
  ".nix": "nix",
  ".dockerfile": "dockerfile",
  ".tf": "terraform",
  ".env": "dotenv",
  ".diff": "diff",
  ".patch": "diff",
  ".txt": "text",
  ".gitignore": "gitignore",
};

function detectLanguage(filePath) {
  if (!filePath) return "text";
  const basename = path.basename(filePath).toLowerCase();
  if (basename === "dockerfile") return "dockerfile";
  if (basename === "makefile") return "makefile";
  if (basename === "gemfile") return "ruby";
  const ext = path.extname(basename);
  return EXT_TO_LANG[ext] || "text";
}

// ---------------------------------------------------------------------------
// Pierre config – pierre-dark theme colors mapped to semantic highlights
// ---------------------------------------------------------------------------
const PIERRE_THEME = "pierre-dark";
const RENDER_OPTIONS = {
  theme: PIERRE_THEME,
  useTokenTransformer: false,
  tokenizeMaxLineLength: 1_000,
  lineDiffType: "word-alt",
  maxLineDiffLength: 10_000,
};

/**
 * Map Pierre/Shiki hex colors (from the pierre-dark theme) to semantic
 * highlight types. The Lua side maps these to Neovim highlight groups.
 */
const COLOR_TO_HIGHLIGHT = {
  "#d568ea": "keyword",     // purple – keywords (const, function), type names
  "#ffca00": "identifier",  // yellow – variable/function/parameter names
  "#08c0ef": "type",        // cyan – type annotations, operators (=)
  "#68cdf2": "variable",    // light blue – values, parameters
  "#79797f": "punctuation", // gray – punctuation, operators, delimiters
  "#9d6afb": "keyword",     // purple-blue – entity names, keywords
  "#adadb1": "variable",    // light gray – identifiers, default text
  "#ff678d": "keyword",     // pink – keywords (export, import, from)
  "#5ecc71": "string",      // green – string literals
  "#ffa359": "number",      // orange – numeric literals
  "#84848a": "comment",     // gray-green – line and block comments
};

/**
 * Parse an inline CSS style string into a map.
 */
function parseStyleValue(styleValue) {
  if (typeof styleValue !== "string") return new Map();
  const styles = new Map();
  for (const segment of styleValue.split(";")) {
    const sep = segment.indexOf(":");
    if (sep <= 0) continue;
    styles.set(segment.slice(0, sep).trim(), segment.slice(sep + 1).trim());
  }
  return styles;
}

/**
 * Map a hex color string to a semantic highlight name.
 */
function mapColorToHighlight(color) {
  if (!color) return null;
  const key = color.trim().toLowerCase();
  return COLOR_TO_HIGHLIGHT[key] || null;
}

function normalizeHexColor(color) {
  if (typeof color !== "string") return null;
  const trimmed = color.trim().toLowerCase();
  const match = trimmed.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/);
  if (!match) return null;
  const hex = match[1];
  if (hex.length === 3) {
    return "#" + hex
      .split("")
      .map((ch) => ch + ch)
      .join("");
  }
  return "#" + hex;
}

/**
 * Walk a Pierre HAST node tree and collect flat text+highlight tokens.
 * Returns an array of { t: string, h: string|null } objects.
 */
function flattenLineTokens(node) {
  if (!node) return [];

  const tokens = [];

  function visit(n) {
    if (!n) return;

    if (n.type === "text") {
      const text = cleanLastNewline(n.value);
      if (text.length > 0) {
        tokens.push({ t: text, h: null });
      }
      return;
    }

    if (n.type === "element") {
      let currentHl = null;
      if (n.properties?.style) {
        const styles = parseStyleValue(n.properties.style);
        const color = styles.get("color");
        if (color) {
          currentHl = normalizeHexColor(color) || mapColorToHighlight(color);
        }
      }

      if (n.children && n.children.length > 0) {
        for (const child of n.children) {
          if (child.type === "text") {
            const text = cleanLastNewline(child.value);
            if (text.length > 0) {
              tokens.push({ t: text, h: currentHl });
            }
          } else {
            visit(child);
          }
        }
      }
    }
  }

  visit(node);
  return tokens;
}

// ---------------------------------------------------------------------------
// Highlighter cache – one Shiki highlighter per language, reused across calls
// ---------------------------------------------------------------------------
const highlighterCache = new Map();
const highlighterOptsCache = new Map();

async function getHighlighterForLanguage(lang) {
  if (highlighterCache.has(lang)) return highlighterCache.get(lang);
  if (!highlighterOptsCache.has(lang)) {
    const opts = getHighlighterOptions(lang, { theme: PIERRE_THEME });
    highlighterOptsCache.set(lang, opts);
  }
  const highlighter = await getSharedHighlighter({
    ...highlighterOptsCache.get(lang),
    preferredHighlighter: "shiki-wasm",
  });
  highlighterCache.set(lang, highlighter);
  return highlighter;
}

function flattenThemedTokens(lineTokens) {
  const tokens = [];
  for (const token of lineTokens || []) {
    const text = token?.content ?? "";
    if (text.length === 0) continue;
    tokens.push({
      t: text,
      h: normalizeHexColor(token.color) || mapColorToHighlight(token.color),
    });
  }
  return tokens;
}

async function tokenizeLine(highlighter, language, line) {
  if (!highlighter || typeof line !== "string" || line.length === 0) {
    return [];
  }

  try {
    const rendered = await highlighter.codeToTokens(line, {
      lang: language,
      theme: PIERRE_THEME,
    });
    const lineTokens = rendered?.tokens?.[0] || [];
    return flattenThemedTokens(lineTokens);
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Pi custom diff format parser
// ---------------------------------------------------------------------------

/**
 * Parse pi's custom diff format directly.
 *
 * Pi format (from the edit tool's generateDiffString):
 *   +1   const x = 1;    // addition (new file line 1)
 *   -2   const y = 2;    // deletion  (old file line 2)
 *    3   const z = 3;    // context   (line 3 in both)
 *      ...                // skipped context
 */
function looksLikePiDiff(text) {
  if (!text || typeof text !== "string") return false;
  const lines = text.split("\n");
  let piLineCount = 0;
  let stdDiffHints = 0;

  // Heuristic: edit-tool diffs often contain metadata/ellipsis lines before the
  // numbered payload; detect by scanning multiple lines instead of line 1 only.
  for (let i = 0; i < Math.min(lines.length, 200); i++) {
    const line = lines[i] || "";
    const trimmed = line.trim();
    if (trimmed.startsWith("diff ") || trimmed.startsWith("---") || trimmed.startsWith("+++")
      || trimmed.startsWith("@@")) {
      stdDiffHints++;
      continue;
    }
    if (/^[+\- ]\s*\d+\s/.test(line)) {
      piLineCount++;
    }
  }

  if (stdDiffHints > 0 && piLineCount == 0) return false;
  return piLineCount >= 2;
}

function parsePiDiff(text, filePath) {
  const lines = text.split("\n");
  const name = filePath || "file";

  // Collect all parsed lines, including "..." markers as hunk separators
  const allLines = [];
  for (const line of lines) {
    // Preserve indentation: consume exactly one separator whitespace after the
    // line number; keep all remaining leading spaces/tabs as part of code text.
    const m = line.match(/^([+\- ])\s*(\d+)(\s.*)$/);
    if (m) {
      allLines.push({
        type: m[1] === " " ? "context" : m[1] === "-" ? "deletion" : "addition",
        oldLineNum: m[1] === "+" ? null : parseInt(m[2], 10),
        newLineNum: m[1] === "-" ? null : parseInt(m[2], 10),
        text: m[3].slice(1),
        isSkipMarker: false,
      });
    } else if (/^\s*\.\.\.\s*$/.test(line)) {
      // "..." line: acts as a hunk separator
      allLines.push({ type: "skip", isSkipMarker: true });
    }
  }

  const stats = { additions: 0, deletions: 0 };
  const deletionLines = [];
  const additionLines = [];
  const hunks = [];

  let i = 0;
  while (i < allLines.length) {
    // Skip over any skip markers ("...")
    while (i < allLines.length && allLines[i].isSkipMarker) { i++; }
    if (i >= allLines.length) break;

    // Buffer leading context (lines before a change block)
    const leadingCtx = [];
    while (i < allLines.length && allLines[i].type === "context") {
      leadingCtx.push(allLines[i]);
      i++;
    }

    // Collect change lines (must have at least one to form a hunk)
    const changes = [];
    while (i < allLines.length && allLines[i].type !== "context" && !allLines[i].isSkipMarker) {
      changes.push(allLines[i]);
      i++;
    }

    // If no changes, the remaining context is meaningless
    if (changes.length === 0) break;

    // Collect trailing context (belongs to this hunk)
    const trailingCtx = [];
    while (i < allLines.length && allLines[i].type === "context" && !allLines[i].isSkipMarker) {
      trailingCtx.push(allLines[i]);
      i++;
    }

    // Combine into one hunk
    const hunkLines = [...leadingCtx, ...changes, ...trailingCtx];
    let firstOld = null, firstNew = null;
    for (const l of hunkLines) {
      if (firstOld === null) { firstOld = l.oldLineNum; firstNew = l.newLineNum; }
      if (l.type === "deletion") stats.deletions++;
      if (l.type === "addition") stats.additions++;
    }

    if (hunkLines.length === 0) continue;
    firstOld = firstOld ?? 1;
    firstNew = firstNew ?? 1;

    // Build hunk content
    const hunkContent = [];
    let delBuf = 0, addBuf = 0;
    const hunkDelStart = deletionLines.length;
    const hunkAddStart = additionLines.length;

    for (const hl of hunkLines) {
      if (hl.type === "context") {
        if (delBuf > 0 || addBuf > 0) {
          hunkContent.push({
            type: "change",
            deletions: delBuf, additions: addBuf,
            deletionLineIndex: deletionLines.length - delBuf,
            additionLineIndex: additionLines.length - addBuf,
          });
          delBuf = 0; addBuf = 0;
        }
        hunkContent.push({
          type: "context", lines: 1,
          deletionLineIndex: deletionLines.length,
          additionLineIndex: additionLines.length,
        });
        deletionLines.push(hl.text);
        additionLines.push(hl.text);
      } else if (hl.type === "deletion") {
        delBuf++;
        deletionLines.push(hl.text);
      } else {
        addBuf++;
        additionLines.push(hl.text);
      }
    }
    if (delBuf > 0 || addBuf > 0) {
      hunkContent.push({
        type: "change",
        deletions: delBuf, additions: addBuf,
        deletionLineIndex: deletionLines.length - delBuf,
        additionLineIndex: additionLines.length - addBuf,
      });
    }

    let oldCnt = 0, newCnt = 0;
    for (const hl of hunkLines) {
      if (hl.type !== "addition") oldCnt++;
      if (hl.type !== "deletion") newCnt++;
    }

    hunks.push({
      deletionStart: firstOld,
      deletionCount: oldCnt,
      additionStart: firstNew,
      additionCount: newCnt,
      deletionLineIndex: hunkDelStart,
      additionLineIndex: hunkAddStart,
      deletionLines: oldCnt,
      additionLines: newCnt,
      collapsedBefore: 0,
      hunkContent,
      hunkSpecs: `@@ -${firstOld},${oldCnt} +${firstNew},${newCnt} @@`,
      splitLineStart: 0,
      splitLineCount: 0,
      unifiedLineStart: 0,
      unifiedLineCount: 0,
      noEOFCRDeletions: false,
      noEOFCRAdditions: false,
    });
  }

  return {
    name,
    prevName: undefined,
    lang: detectLanguage(name),
    hunks,
    isPartial: true,
    deletionLines,
    additionLines,
    type: "change",
    splitLineCount: 0,
    unifiedLineCount: 0,
  };
}

/** Build structured output for a pi-format diff. */
async function buildPiDiffResult(metadata, filePath) {
  const result = {
    path: metadata.name,
    prevPath: metadata.prevName,
    language: metadata.lang,
    hunks: [],
    stats: { additions: 0, deletions: 0 },
  };

  let highlighter = null;
  try {
    highlighter = await getHighlighterForLanguage(metadata.lang);
  } catch {
    highlighter = null;
  }

  for (const hunk of metadata.hunks) {
    const hunkInfo = {
      oldStart: hunk.deletionStart,
      oldLines: hunk.deletionCount,
      newStart: hunk.additionStart,
      newLines: hunk.additionCount,
      header: hunk.hunkSpecs || "",
      lines: [],
    };

    let delIdx = hunk.deletionLineIndex;
    let addIdx = hunk.additionLineIndex;

    for (const content of hunk.hunkContent) {
      if (content.type === "context") {
        for (let j = 0; j < content.lines; j++) {
          const raw = metadata.deletionLines[delIdx++] || "";
          const tokens = await tokenizeLine(highlighter, metadata.lang, raw);
          const lineNum = hunkInfo.lines.length > 0
            ? hunkInfo.lines[hunkInfo.lines.length - 1].newLineNum
            : hunk.additionStart;
          hunkInfo.lines.push({
            type: "context",
            oldLineNum: lineNum,
            newLineNum: lineNum,
            tokens: tokens.length > 0 ? tokens : raw.length > 0 ? [{ t: raw, h: null }] : [],
          });
          addIdx++;
        }
      } else {
        for (let j = 0; j < content.deletions; j++) {
          const raw = metadata.deletionLines[delIdx++] || "";
          const tokens = await tokenizeLine(highlighter, metadata.lang, raw);
          hunkInfo.lines.push({
            type: "deletion",
            oldLineNum: null,
            newLineNum: null,
            tokens: tokens.length > 0 ? tokens : raw.length > 0 ? [{ t: raw, h: null }] : [],
          });
          result.stats.deletions++;
        }
        for (let j = 0; j < content.additions; j++) {
          const raw = metadata.additionLines[addIdx++] || "";
          const tokens = await tokenizeLine(highlighter, metadata.lang, raw);
          hunkInfo.lines.push({
            type: "addition",
            oldLineNum: null,
            newLineNum: null,
            tokens: tokens.length > 0 ? tokens : raw.length > 0 ? [{ t: raw, h: null }] : [],
          });
          result.stats.additions++;
        }
      }
    }

    result.hunks.push(hunkInfo);
  }

  return result;
}

// ---------------------------------------------------------------------------
// Standard unified diff handling (using @pierre/diffs)
// ---------------------------------------------------------------------------

/**
 * Parse a standard unified diff patch.
 */
function parseStandardPatch(patch, filePath) {
  try {
    const parsedPatches = parsePatchFiles(patch, "pi:changes", false);
    const files = parsedPatches.flatMap((entry) => entry.files);

    if (files.length === 0) {
      return { success: false, error: "No diff files found in patch" };
    }

    let targetFile = files[0];
    if (filePath) {
      const normPath = filePath.replace(/\\/g, "/");
      const matched = files.find(
        (f) =>
          f.name === normPath ||
          f.prevName === normPath ||
          f.name?.endsWith(path.basename(normPath)),
      );
      if (matched) targetFile = matched;
    }

    const language = detectLanguage(targetFile.name || filePath);
    return { success: true, file: targetFile, language };
  } catch (err) {
    return { success: false, error: String(err) };
  }
}

/**
 * Apply syntax highlighting to a parsed diff file and build the
 * structured response with per-line tokens.
 */
async function highlightStandardFile(fileMetadata, language) {
  const result = {
    path: fileMetadata.name,
    prevPath: fileMetadata.prevName,
    language,
    hunks: [],
    stats: { additions: 0, deletions: 0 },
  };

  if (!fileMetadata.hunks || fileMetadata.hunks.length === 0) {
    return result;
  }

  let deletionLines = [];
  let additionLines = [];

  try {
    const highlighter = await getHighlighterForLanguage(language);
    const rendered = renderDiffWithHighlighter(
      fileMetadata,
      highlighter,
      RENDER_OPTIONS,
    );
    deletionLines = rendered.code.deletionLines;
    additionLines = rendered.code.additionLines;
  } catch {
    deletionLines = fileMetadata.deletionLines.map(() => undefined);
    additionLines = fileMetadata.additionLines.map(() => undefined);
  }

  for (const hunk of fileMetadata.hunks) {
    const hunkInfo = {
      oldStart: hunk.deletionStart,
      oldLines: hunk.deletionCount,
      newStart: hunk.additionStart,
      newLines: hunk.additionCount,
      header: hunk.hunkSpecs || `@@ -${hunk.deletionStart},${hunk.deletionCount} +${hunk.additionStart},${hunk.additionCount} @@`,
      lines: [],
    };

    let delIdx = hunk.deletionLineIndex;
    let addIdx = hunk.additionLineIndex;
    let delNum = hunk.deletionStart;
    let addNum = hunk.additionStart;

    for (const content of hunk.hunkContent) {
      if (content.type === "context") {
        for (let j = 0; j < content.lines; j++) {
          const raw = fileMetadata.deletionLines[delIdx] || fileMetadata.additionLines[addIdx] || "";
          const node = deletionLines[delIdx] || additionLines[addIdx];
          const tokens = flattenLineTokens(node);
          hunkInfo.lines.push({
            type: "context",
            oldLineNum: delNum,
            newLineNum: addNum,
            tokens: tokens.length > 0 ? tokens : [{ t: raw.replace(/\r?\n$/, ""), h: null }],
          });
          delIdx++; addIdx++; delNum++; addNum++;
        }
      } else if (content.type === "change") {
        for (let j = 0; j < content.deletions; j++) {
          const raw = fileMetadata.deletionLines[delIdx] || "";
          const node = deletionLines[delIdx];
          const tokens = flattenLineTokens(node);
          hunkInfo.lines.push({
            type: "deletion",
            oldLineNum: delNum,
            newLineNum: null,
            tokens: tokens.length > 0 ? tokens : [{ t: raw.replace(/\r?\n$/, ""), h: null }],
          });
          delIdx++; delNum++;
          result.stats.deletions++;
        }
        for (let j = 0; j < content.additions; j++) {
          const raw = fileMetadata.additionLines[addIdx] || "";
          const node = additionLines[addIdx];
          const tokens = flattenLineTokens(node);
          hunkInfo.lines.push({
            type: "addition",
            oldLineNum: null,
            newLineNum: addNum,
            tokens: tokens.length > 0 ? tokens : [{ t: raw.replace(/\r?\n$/, ""), h: null }],
          });
          addIdx++; addNum++;
          result.stats.additions++;
        }
      }
    }

    result.hunks.push(hunkInfo);
  }

  return result;
}

// ---------------------------------------------------------------------------
// Request handling / I/O
// ---------------------------------------------------------------------------

const rl = createInterface({ input: process.stdin });

async function handleRequest(request) {
  if (!request || request.type !== "highlight") {
    return {
      type: "result",
      id: request?.id || "unknown",
      success: false,
      error: "Invalid request. Expected {type:'highlight', patch:'...', path:'...'}",
    };
  }

  if (typeof request.patch !== "string" || request.patch.length === 0) {
    return {
      type: "result",
      id: request.id,
      success: false,
      error: "Missing or empty 'patch' field",
    };
  }

  const patch = request.patch;
  const filePath = request.path || "";

  // Detect format and parse
  if (looksLikePiDiff(patch)) {
    // Pi custom format — parse directly and syntax highlight per line.
    const metadata = parsePiDiff(patch, filePath);
    const fileResult = await buildPiDiffResult(metadata, filePath);
    return {
      type: "result",
      id: request.id,
      success: true,
      file: fileResult,
    };
  }

  // Standard unified diff — use @pierre/diffs with Shiki
  const parsed = parseStandardPatch(patch, filePath);
  if (!parsed.success) {
    return {
      type: "result",
      id: request.id,
      success: false,
      error: parsed.error,
    };
  }

  const fileResult = await highlightStandardFile(parsed.file, parsed.language);
  return {
    type: "result",
    id: request.id,
    success: true,
    file: fileResult,
  };
}

rl.on("line", async (line) => {
  line = line.trim();
  if (!line) return;

  let request = null;
  try {
    request = JSON.parse(line);
    const response = await handleRequest(request);
    process.stdout.write(JSON.stringify(response) + "\n");
  } catch (err) {
    process.stdout.write(
      JSON.stringify({
        type: "result",
        id: request?.id || "error",
        success: false,
        error: String(err),
      }) + "\n",
    );
  }
});

process.stderr.write("diff-server: ready\n");

#!/usr/bin/env node
//
// Documentation cross-reference checker (ported from the sothis repo).
//
// Documents here point at each other's sections constantly. Sections get renamed and removed; the
// references pointing at them do not follow on their own, and the next reader is sent somewhere
// that no longer exists. Nothing about that is a judgment call, so nothing about catching it needs
// one. The checker knows nothing about what any section says, only whether the section a reference
// names is still in the file it names.
//
// WHY LINKS AND NOT PROSE
//
// A prose reference ("see `FOO.md`'s Bar section") can only be recognized by guessing from
// substrings, and such a guess is bound to one language and one phrasing. Parts of this corpus are
// written in German, so a prose-based checker would silently miss exactly the references it was
// meant to catch.
//
// A Markdown link needs no guessing. `[Release flow](AGENTS.md#release-flow-cross-repo-at-a-glance)` names its target
// mechanically, in a syntax that is the same in every language, and it is the only form for which
// "this reference works" is decidable at all. So references are written as links, and this script
// resolves them:
//
//   * the path must resolve to a file that exists, and
//   * the fragment, if there is one, must name a section of that file.
//
// The prose forms are not merely unsupported afterwards — they are rejected, so the corpus cannot
// drift back one sentence at a time. That guard is a migration lint, not a second resolution
// mechanism: it never decides whether a reference is live, only that it is not written as a link.
//
// WHAT COUNTS AS A SECTION
//
// A `#` heading, and — as a fallback — a paragraph-opening bold lead-in. Several documents here carry
// structure in lead-ins like "**Version is pipeline-owned.** …", and somebody naming one expects the
// name to keep meaning something. Where a link resolves on the strength of a lead-in it lands a
// browser at the top of the file: still better than prose, and a signal that the section it names is
// a heading waiting to be written.
//
// Usage:
//   node .claude/scripts/check-doc-section-refs.mjs [--root <dir>] [file ...]
//   node .claude/scripts/check-doc-section-refs.mjs --anchors <file>    # list a file's link targets
//
// With no files given it scans every Markdown file under the documentation roots below. Exits 0 when
// every reference resolves and no prose reference is left, 1 otherwise (printing each offender with
// a file:line anchor plus the closest real section, so the fix is usually visible without opening
// anything).

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";

// Where references are looked for: the toolchain under .claude/ (skills, templates, scripts), the
// human-facing folder, plus the root documents themselves. Sub-repos under plugins/, libs/, apps/,
// extensions/ and agent-marketplace/ are separate git repositories and out of scope — a hook in this
// repo never sees their commits.
const SCAN_DIRS = [".claude", "human"];

const SKIP_DIRS = new Set(["node_modules", ".git"]);

// Subtrees deliberately outside the gate (none at present). Add a relative path here only for text
// no committing role is allowed to repair — a gate over frozen text is a deadlock, not a gate.
const SKIP_REL_DIRS = new Set([]);

// --- What a link target may point at ---------------------------------------------------------
//
// Only Markdown files, and only inside the roots above (plus root-level documents). Two reasons, and
// both are about the pre-commit hook rather than about taste: it materializes exactly this set out
// of the index into a temporary tree, so a link to anything else would resolve against a file that
// is simply not there and be reported dead for a reason that has nothing to do with the link. And a
// link to a non-Markdown asset has no sections to check, so the only thing left to verify is
// existence — which would mean dragging every sub-repo through a temp copy on every commit. Links
// outside this set are left alone, silently and on purpose.
function isCheckable(relPath) {
  if (!relPath.endsWith(".md")) return false;
  if (relPath.startsWith("../") || relPath.startsWith("/")) return false;
  if (!relPath.includes("/")) return true; // a root-level document
  return SCAN_DIRS.some((d) => relPath.startsWith(`${d}/`));
}

// --- Anchors ----------------------------------------------------------------------------------
//
// GitHub's own heading-slug rules, so a link that resolves here is the same link that works in a
// browser: strip formatting, lowercase, drop everything that is not a letter, digit, space, hyphen
// or underscore, then each remaining space becomes a hyphen. Repeats get GitHub's `-1`, `-2`
// suffixes.
//
// Runs of spaces are deliberately *not* collapsed, because GitHub does not collapse them either: a
// dropped character between two spaces leaves both behind, so `## Controls & modes` is reached as
// `#controls--modes` with two hyphens. Collapsing here would produce a slug that resolves in this
// checker and 404s in a browser — the exact gap between "checked" and "works" that writing these as
// links was meant to close.
function slug(text) {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[`*_~]/g, "")
    .replace(/\s/g, " ")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N} _-]/gu, "")
    .replace(/ /g, "-");
}

const anchorCache = new Map();

function anchorsOf(absPath) {
  if (anchorCache.has(absPath)) return anchorCache.get(absPath);
  if (!existsSync(absPath)) {
    anchorCache.set(absPath, null);
    return null;
  }
  // slug -> display name. Headings first and with GitHub's duplicate numbering, so their anchors are
  // byte-identical to the ones a browser would mint; bold lead-ins are added afterwards and never
  // consume a duplicate index a heading would have taken.
  const anchors = new Map();
  const seen = new Map();
  const lines = readFileSync(absPath, "utf8").split("\n");
  let fenced = false;
  const bold = [];
  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    const heading = /^(#{1,6})\s+(.+?)\s*$/.exec(line);
    if (heading) {
      const base = slug(heading[2]);
      const n = seen.get(base) ?? 0;
      seen.set(base, n + 1);
      anchors.set(n === 0 ? base : `${base}-${n}`, heading[2]);
      continue;
    }
    const lead = /^\s*(?:[-*]\s+)?\*\*(.+?)\*\*/.exec(line);
    if (lead) bold.push(lead[1].replace(/[.,:;!?]+$/, ""));
  }
  for (const name of bold) {
    const s = slug(name);
    if (s && !anchors.has(s)) anchors.set(s, name);
  }
  anchorCache.set(absPath, anchors);
  return anchors;
}

function nearest(fragment, anchors) {
  const words = new Set(fragment.split("-").filter(Boolean));
  let best = null;
  let bestScore = 0;
  for (const key of anchors.keys()) {
    const overlap = key.split("-").filter((w) => words.has(w)).length;
    if (overlap > bestScore) {
      bestScore = overlap;
      best = key;
    }
  }
  return bestScore > 0 ? best : null;
}

// --- Reading a file ----------------------------------------------------------------------------
//
// Fenced code blocks are excluded: a reference inside a worked example or a sample prompt is an
// illustration of the form, not a live pointer a reader would follow.
function nonCodeLines(text) {
  let fenced = false;
  return text.split("\n").map((line, i) => {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      return { line: "", n: i + 1, quoted: false };
    }
    return { line: fenced ? "" : line, n: i + 1, quoted: /^\s*>/.test(line) };
  });
}

// Inline links, plus reference-style link definitions. Image links (`![alt](…)`) are matched by the
// same shape and want the same treatment — a dead image path is a dead link.
const LINK_RE = /\[([^\]\n]*)\]\(\s*([^)\s]+?)(?:\s+"[^"]*")?\s*\)/g;
const LINKDEF_RE = /^\s{0,3}\[([^\]\n]+)\]:\s*(\S+)/;

// A code span holds a specimen, not a pointer — `[Branch workflow](#branch-workflow)` written inside
// backticks is somebody explaining the syntax, exactly as a fenced block is, and resolving it would
// report their example as a dead link. Removed before links are read, and only there: the prose guard
// below must still see the backticks around a document name, since that is how the old form is
// written and the whole point of the guard is to catch it.
const CODE_SPAN_RE = /``[^`]*(?:`[^`]+`[^`]*)*``|`[^`\n]*`/g;

// --- The prose guard ---------------------------------------------------------------------------
//
// The three shapes that used to *be* the checker. They now only say "this is not a link yet". Kept
// narrow on purpose: each requires either literal heading syntax or the word `section`, so ordinary
// prose that merely mentions a document does not trip it. It is language-bound and always will be —
// that is precisely why it is not the resolution mechanism any more, only a one-way ratchet keeping
// the migrated corpus migrated.
//
// A double-backtick code span is how Markdown quotes a snippet that itself contains backticks, which
// in practice means one thing: somebody is displaying a reference *as a specimen of its own syntax*. Rewriting a specimen
// into a link destroys the thing it was showing, so these spans are removed before the guard reads
// the line — the same reasoning that already excludes fenced blocks.
const SPECIMEN_RE = /``[^`]*(?:`[^`]+`[^`]*)*``/g;

// Three exemptions, all because the alternative would be to falsify text. Blockquoted lines: a
// blockquote is a verbatim citation of somebody else's wording, and rewriting a quotation to satisfy
// a lint changes what it claims was written. And link text: the migration wraps the existing prose
// phrase in a link rather than rewording the sentence around it, so `[`AGENTS.md`'s Release flow
// section](\u2026#release-flow-cross-repo-at-a-glance)` still *contains* the shape below. Links are therefore removed from the
// line before the guard reads it \u2014 a reference that already carries a target has nothing left to
// prove here, and it has been resolved above in any case.
const DOC = "`?([A-Za-z0-9_./-]+\\.md)`?(?:'s|\u2019s|s)?";
const PROSE_PATTERNS = [
  // The name has to start on a word character, or `` `AGENTS.md`'s `## ` headings `` — prose about
  // heading syntax rather than a pointer at any one heading — reads as a reference to a section
  // called "#".
  { kind: "heading", re: new RegExp(`${DOC}\\s+\`#{1,6}\\s*([A-Za-z0-9][^\`]{1,79})\``, "g") },
  { kind: "quoted", re: new RegExp(`${DOC}[^\u201c\u201d\u201e"\\n]{0,40}?[\u201c\u201e"]([^\u201c\u201d"]{2,80})[\u201d"]\\s+section\\b`, "g") },
  { kind: "bare", re: new RegExp(`${DOC}\\s+([A-Za-z][^,.;:()\\[\\]\`"\u201d]{1,60}?)\\s+section\\b`, "g") },
];

function markdownFilesUnder(dir, root) {
  const out = [];
  const walk = (d) => {
    for (const entry of readdirSync(d)) {
      if (SKIP_DIRS.has(entry)) continue;
      const p = join(d, entry);
      if (statSync(p).isDirectory()) {
        if (SKIP_REL_DIRS.has(relative(root, p).split(sep).join("/"))) continue;
        walk(p);
      } else if (entry.endsWith(".md")) out.push(p);
    }
  };
  if (existsSync(dir)) walk(dir);
  return out;
}

function rootFiles(root) {
  return readdirSync(root)
    .filter((e) => e.endsWith(".md"))
    .map((e) => join(root, e))
    .filter((p) => statSync(p).isFile());
}

function checkLink(target, file, root) {
  // Anything with a scheme, a protocol-relative host, or a bare mail address is somebody else's.
  if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith("//")) return null;

  const hash = target.indexOf("#");
  const rawPath = hash === -1 ? target : target.slice(0, hash);
  const fragment = hash === -1 ? "" : decodeURIComponent(target.slice(hash + 1));

  const abs = rawPath === "" ? file : resolve(dirname(file), decodeURIComponent(rawPath));
  const rel = relative(root, abs).split(sep).join("/");

  if (rawPath !== "" && !isCheckable(rel)) return null;

  if (!existsSync(abs)) {
    return { problem: "no such file", detail: rel };
  }
  if (!fragment) return null;

  const anchors = anchorsOf(abs);
  if (!anchors) return null;
  if (anchors.has(fragment.toLowerCase())) return null;

  return {
    problem: "no such section",
    detail: `${rel}#${fragment}`,
    nearest: nearest(fragment.toLowerCase(), anchors),
  };
}

function main(argv) {
  let root = process.cwd();
  const explicit = [];
  let anchorsFor = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--root") root = resolve(argv[++i]);
    else if (argv[i] === "--anchors") anchorsFor = argv[++i];
    else explicit.push(argv[i]);
  }

  if (anchorsFor) {
    const anchors = anchorsOf(resolve(root, anchorsFor));
    if (!anchors) {
      console.error(`no such file: ${anchorsFor}`);
      return 1;
    }
    for (const [s, name] of anchors) console.log(`#${s}\t${name}`);
    return 0;
  }

  let files;
  if (explicit.length) {
    files = explicit.map((f) => resolve(root, f)).filter((f) => f.endsWith(".md") && existsSync(f));
  } else {
    files = [...SCAN_DIRS.flatMap((d) => markdownFilesUnder(join(root, d), root)), ...rootFiles(root)];
  }

  const dead = [];
  const prose = [];
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const where = relative(root, file).split(sep).join("/");
    for (const { line, n, quoted } of nonCodeLines(text)) {
      if (!line) continue;

      const targets = [];
      const linkable = line.replace(CODE_SPAN_RE, " ");
      LINK_RE.lastIndex = 0;
      let m;
      while ((m = LINK_RE.exec(linkable)) !== null) targets.push(m[2]);
      const def = LINKDEF_RE.exec(linkable);
      if (def) targets.push(def[2]);

      for (const target of targets) {
        const bad = checkLink(target, file, root);
        if (bad) dead.push({ file: where, line: n, target, ...bad });
      }

      if (quoted) continue;
      const unlinked = line.replace(SPECIMEN_RE, " ").replace(LINK_RE, " ").replace(LINKDEF_RE, " ");
      for (const { kind, re } of PROSE_PATTERNS) {
        re.lastIndex = 0;
        let p;
        while ((p = re.exec(unlinked)) !== null) {
          prose.push({ file: where, line: n, kind, doc: p[1], name: p[2].trim() });
        }
      }
    }
  }

  if (dead.length === 0 && prose.length === 0) {
    if (!process.env.DOC_REF_CHECK_QUIET) {
      console.log(`doc-section-refs: OK (${files.length} files scanned, every reference resolves)`);
    }
    return 0;
  }

  if (dead.length) {
    console.error(`doc-section-refs: ${dead.length} dead reference(s)\n`);
    for (const d of dead) {
      console.error(`  ${d.file}:${d.line}`);
      console.error(`    (${d.target}) — ${d.problem}: ${d.detail}`);
      if (d.nearest) console.error(`    closest section there: #${d.nearest}`);
      console.error("");
    }
    console.error("Fix the link to name a file and section that exist, or restore what it names.");
    console.error("`--anchors <file>` lists every section of a file and the fragment that reaches it.\n");
  }

  if (prose.length) {
    console.error(`doc-section-refs: ${prose.length} prose section reference(s) — write these as Markdown links\n`);
    for (const p of prose) {
      console.error(`  ${p.file}:${p.line}`);
      console.error(`    ${p.doc} "${p.name}" is named in prose, not linked`);
      console.error(`    write it as [${p.name}](<relative path to ${p.doc}>#${slug(p.name)})`);
      console.error("");
    }
    console.error("Prose references cannot be resolved mechanically and are not checked in any");
    console.error("language but the one the pattern above happens to be written in — which is why");
    console.error("they were replaced. Use a link.\n");
  }

  return 1;
}

process.exit(main(process.argv.slice(2)));

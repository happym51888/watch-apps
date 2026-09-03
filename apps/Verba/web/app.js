import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { CONFIG } from "./config.js";

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

const PAGE_SIZE = 25;

const el = (id) => document.getElementById(id);
const ui = {
  configError: el("config-error"),
  auth: el("auth"),
  signInForm: el("sign-in-form"),
  signIn: el("sign-in"),
  authError: el("auth-error"),
  sessionBar: el("session-bar"),
  sessionEmail: el("session-email"),
  signOut: el("sign-out"),
  library: el("library"),
  search: el("search"),
  resultCount: el("result-count"),
  empty: el("empty"),
  memos: el("memos"),
  loadMore: el("load-more"),
};

if (!CONFIG.url || CONFIG.url.includes("YOUR-PROJECT-REF")) {
  show(ui.configError, "config.js has not been filled in. Copy config.example.js to config.js and put your project URL and anon key in it.");
  throw new Error("unconfigured");
}

const supabase = createClient(CONFIG.url, CONFIG.anonKey, {
  auth: { persistSession: true, autoRefreshToken: true },
});

// Paging cursor. Keyset rather than offset: `started_at` is unique enough in
// practice and, unlike OFFSET, it does not skip or repeat a row when something
// syncs while you are scrolling.
let cursor = null;
let query = "";
let loading = false;

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

ui.signInForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  hide(ui.authError);
  ui.signIn.disabled = true;
  ui.signIn.textContent = "Signing in…";

  const { error } = await supabase.auth.signInWithPassword({
    email: el("email").value.trim(),
    password: el("password").value,
  });

  ui.signIn.disabled = false;
  ui.signIn.textContent = "Sign in";
  if (error) show(ui.authError, error.message);
});

ui.signOut.addEventListener("click", () => supabase.auth.signOut());

supabase.auth.onAuthStateChange((_event, session) => {
  if (session) {
    ui.sessionEmail.textContent = session.user.email ?? "";
    ui.sessionBar.hidden = false;
    ui.auth.hidden = true;
    ui.library.hidden = false;
    reload();
  } else {
    ui.sessionBar.hidden = true;
    ui.auth.hidden = false;
    ui.library.hidden = true;
    ui.memos.replaceChildren();
  }
});

// Restore an existing session before deciding what to show, so a refresh does
// not flash the sign-in form at someone who is already signed in.
const { data: { session } } = await supabase.auth.getSession();
if (!session) ui.auth.hidden = false;

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

// Debounced so typing does not fire a request per keystroke.
let searchTimer;
ui.search.addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    query = ui.search.value.trim();
    reload();
  }, 250);
});

function reload() {
  cursor = null;
  ui.memos.replaceChildren();
  load();
}

async function load() {
  if (loading) return;
  loading = true;
  ui.loadMore.disabled = true;

  let request = supabase
    .from("memos")
    .select("*")
    .order("started_at", { ascending: false })
    .limit(PAGE_SIZE);

  if (cursor) request = request.lt("started_at", cursor);

  // `ilike` rather than full-text search, deliberately. Postgres has no
  // Chinese segmenter, so `to_tsvector` turns a whole Chinese sentence into a
  // single token and full-text search over Chinese transcripts silently
  // matches nothing. Substring search works for every language; the trigram
  // index in schema.sql is what keeps it fast.
  if (query) request = request.ilike("transcript", `%${escapeLike(query)}%`);

  const { data, error } = await request;
  loading = false;
  ui.loadMore.disabled = false;

  if (error) {
    show(ui.empty, `Couldn't load recordings. ${error.message}`);
    return;
  }

  hide(ui.empty);
  for (const memo of data) ui.memos.append(renderMemo(memo));

  if (data.length > 0) cursor = data[data.length - 1].started_at;
  ui.loadMore.hidden = data.length < PAGE_SIZE;

  const shown = ui.memos.children.length;
  if (shown === 0) {
    show(ui.empty, query
      ? `Nothing matches “${query}”.`
      : "No recordings yet. Record something on your Watch and it will appear here.");
    ui.resultCount.textContent = "";
  } else {
    ui.resultCount.textContent = query
      ? `${shown} match${shown === 1 ? "" : "es"}`
      : `${shown} recording${shown === 1 ? "" : "s"}`;
  }
}

ui.loadMore.addEventListener("click", load);

// `%` and `_` are wildcards in LIKE. Searching for a literal underscore
// without escaping it matches any character, which looks like a bug in the
// search box rather than in the query.
function escapeLike(text) {
  return text.replace(/[\\%_]/g, (match) => `\\${match}`);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function renderMemo(memo) {
  const item = document.createElement("li");
  item.className = "memo";

  const head = document.createElement("div");
  head.className = "memo-head";

  const when = document.createElement("time");
  when.dateTime = memo.started_at;
  when.textContent = formatWhen(memo.started_at);

  const meta = document.createElement("span");
  meta.className = "hint";
  meta.textContent = [
    formatDuration(memo.duration_seconds),
    memo.source_device,
    engineLabel(memo.transcript_engine),
  ].filter(Boolean).join(" · ");

  head.append(when, meta);

  // Transcript, editable in place. `contenteditable` rather than a textarea so
  // the row does not change height or lose its place when editing starts.
  const text = document.createElement("div");
  text.className = "memo-text";
  text.contentEditable = "plaintext-only";
  text.spellcheck = false;
  text.textContent = memo.transcript ?? "";
  if (!memo.transcript) {
    text.dataset.placeholder = "No transcript. Type one, or retry on your iPhone.";
  }

  const status = document.createElement("span");
  status.className = "memo-status hint";

  let original = memo.transcript ?? "";
  text.addEventListener("blur", async () => {
    const edited = text.textContent.trim();
    if (edited === original) return;

    status.textContent = "Saving…";
    const { error } = await supabase
      .from("memos")
      .update({
        transcript: edited,
        // A human correction outranks any machine result and must never be
        // silently replaced by a re-run of the recogniser.
        transcript_engine: "manual",
        transcript_confidence: null,
        title: edited.split("\n")[0].slice(0, 40),
      })
      .eq("id", memo.id);

    if (error) {
      status.textContent = `Not saved: ${error.message}`;
      status.classList.add("error");
    } else {
      original = edited;
      status.textContent = "Saved";
      status.classList.remove("error");
      meta.textContent = [
        formatDuration(memo.duration_seconds),
        memo.source_device,
        engineLabel("manual"),
      ].filter(Boolean).join(" · ");
      setTimeout(() => { status.textContent = ""; }, 2000);
    }
  });

  const actions = document.createElement("div");
  actions.className = "memo-actions";

  if (memo.audio_path) {
    const play = document.createElement("button");
    play.className = "ghost";
    play.textContent = "▶ Play";
    play.addEventListener("click", async () => {
      play.disabled = true;
      play.textContent = "Loading…";

      // The bucket is private, so playback needs a short-lived signed URL.
      // Minting it on demand rather than at list time means a page left open
      // does not hold a hundred URLs that all expire together.
      const { data, error } = await supabase.storage
        .from(CONFIG.bucket)
        .createSignedUrl(memo.audio_path, 3600);

      if (error) {
        play.disabled = false;
        play.textContent = "▶ Play";
        status.textContent = `Couldn't load audio: ${error.message}`;
        status.classList.add("error");
        return;
      }

      const audio = document.createElement("audio");
      audio.controls = true;
      audio.preload = "none";
      audio.src = data.signedUrl;
      play.replaceWith(audio);
      audio.play().catch(() => { /* autoplay refused; the controls still work */ });
    });
    actions.append(play);
  } else {
    const pending = document.createElement("span");
    pending.className = "hint";
    pending.textContent = "audio not uploaded yet";
    actions.append(pending);
  }

  const copy = document.createElement("button");
  copy.className = "ghost";
  copy.textContent = "Copy text";
  copy.addEventListener("click", async () => {
    await navigator.clipboard.writeText(text.textContent);
    copy.textContent = "Copied";
    setTimeout(() => { copy.textContent = "Copy text"; }, 1500);
  });
  actions.append(copy, status);

  item.append(head, text, actions);
  return item;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function formatWhen(iso) {
  const date = new Date(iso);
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  return sameDay
    ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    : date.toLocaleString([], {
        month: "short", day: "numeric",
        hour: "2-digit", minute: "2-digit",
      });
}

function formatDuration(seconds) {
  const total = Math.round(seconds ?? 0);
  if (total <= 0) return "";
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, "0")}`;
}

function engineLabel(engine) {
  return {
    appleOnDevice: "on-device",
    appleLegacy: "on-device",
    cloud: "cloud",
    manual: "edited by you",
  }[engine] ?? "";
}

function show(node, message) {
  node.textContent = message;
  node.hidden = false;
}

function hide(node) {
  node.hidden = true;
}

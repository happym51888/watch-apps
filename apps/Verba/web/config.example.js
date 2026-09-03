// Copy this file to config.js and fill it in. config.js is gitignored.
//
// The anon key is meant to be public and shipping it in a browser is the
// intended design — but only because Row Level Security enforces ownership.
// Apply supabase/schema.sql before pointing a real key at this, or the anon
// key becomes a world-readable, world-writable database.
//
// Never put the service_role key here. It bypasses RLS completely, and in a
// browser it is visible to anyone who opens the network tab.

export const CONFIG = {
  url: "https://YOUR-PROJECT-REF.supabase.co",
  anonKey: "YOUR-ANON-KEY",
  bucket: "memo-audio",
};

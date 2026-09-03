-- Verba schema.
--
-- Run this once against your Supabase project:
--   supabase db push
-- or paste it into the SQL editor.
--
-- Design notes, because a few of these choices are load-bearing:
--
-- * The primary key is the recording id minted on the watch, not a generated
--   uuid. Every delivery path is therefore idempotent: the same recording
--   arriving twice (phone relay and direct upload both landing) is a primary
--   key conflict, which `on conflict do update` turns into a harmless no-op
--   instead of a duplicate row.
--
-- * Audio lives in Storage, not in a bytea column. Postgres will happily store
--   a 15 MB blob and then make every `select *` miserable.
--
-- * Row Level Security is on and the policies are owner-only. This is the
--   difference between "my recordings" and "everyone's recordings", and the
--   default when you forget is the second one.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- memos
-- ---------------------------------------------------------------------------

create table if not exists public.memos (
    -- Watch-minted, sortable by construction: "<unix seconds>-<entropy>".
    id                    text primary key,
    user_id               uuid not null references auth.users (id) on delete cascade,

    started_at            timestamptz not null,
    duration_seconds      double precision not null default 0
                              check (duration_seconds >= 0),
    byte_count            integer not null default 0 check (byte_count >= 0),

    -- 'watch' | 'iphone' | 'mac'. Free text rather than an enum so a new
    -- capture device does not need a migration to start writing.
    source_device         text not null,

    -- Path inside the storage bucket. Null while the row exists but the audio
    -- upload has not finished, which is a real and temporary state.
    audio_path            text,

    transcript            text,
    transcript_locale     text,
    -- Which engine produced it. Mixing on-device and cloud results without a
    -- label makes the corpus impossible to reason about later.
    transcript_engine     text check (
                              transcript_engine is null or
                              transcript_engine in
                                  ('appleOnDevice', 'appleLegacy', 'cloud', 'manual')
                          ),
    transcript_confidence double precision check (
                              transcript_confidence is null or
                              transcript_confidence between 0 and 1
                          ),

    title                 text,

    created_at            timestamptz not null default now(),
    updated_at            timestamptz not null default now()
);

-- Newest first, per user. The only query the apps actually run.
create index if not exists memos_user_started_idx
    on public.memos (user_id, started_at desc);

-- Full-text search over transcripts. Generated rather than maintained by a
-- trigger so it cannot drift out of sync with the column it indexes.
alter table public.memos
    add column if not exists transcript_search tsvector
    generated always as (to_tsvector('simple', coalesce(transcript, ''))) stored;

create index if not exists memos_search_idx
    on public.memos using gin (transcript_search);

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists memos_touch_updated_at on public.memos;
create trigger memos_touch_updated_at
    before update on public.memos
    for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.memos enable row level security;

drop policy if exists "own memos are readable" on public.memos;
create policy "own memos are readable"
    on public.memos for select
    using (auth.uid() = user_id);

drop policy if exists "own memos are insertable" on public.memos;
create policy "own memos are insertable"
    on public.memos for insert
    with check (auth.uid() = user_id);

-- Update is needed because a row is written when the audio arrives and updated
-- when transcription finishes. The `with check` clause is what stops a client
-- reassigning a row to another user on update, which the `using` clause alone
-- does not prevent.
drop policy if exists "own memos are updatable" on public.memos;
create policy "own memos are updatable"
    on public.memos for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "own memos are deletable" on public.memos;
create policy "own memos are deletable"
    on public.memos for delete
    using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Storage bucket for the audio
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'memo-audio',
    'memo-audio',
    false,                       -- never public; served via signed URLs only
    104857600,                   -- 100 MB, comfortably above an hour at 32 kbps
    array['audio/mp4', 'audio/m4a', 'audio/aac', 'audio/wav']
)
on conflict (id) do nothing;

-- Objects are stored at `<user_id>/<memo_id>.m4a`, so the first path segment
-- is the owner and the policies below are a string comparison rather than a
-- join. `storage.foldername(name)` returns the path segments as an array.

drop policy if exists "own audio is readable" on storage.objects;
create policy "own audio is readable"
    on storage.objects for select
    using (
        bucket_id = 'memo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "own audio is writable" on storage.objects;
create policy "own audio is writable"
    on storage.objects for insert
    with check (
        bucket_id = 'memo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "own audio is replaceable" on storage.objects;
create policy "own audio is replaceable"
    on storage.objects for update
    using (
        bucket_id = 'memo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "own audio is deletable" on storage.objects;
create policy "own audio is deletable"
    on storage.objects for delete
    using (
        bucket_id = 'memo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

-- ---------------------------------------------------------------------------
-- Upsert helper
-- ---------------------------------------------------------------------------

-- The clients call this instead of a raw insert. It makes redelivery a no-op
-- and, critically, it never overwrites a transcript with null: the audio row
-- can arrive after the transcript when the watch uploads directly and the
-- phone transcribes a copy it already had.
create or replace function public.upsert_memo(
    p_id                    text,
    p_started_at            timestamptz,
    p_duration_seconds      double precision,
    p_byte_count            integer,
    p_source_device         text,
    p_audio_path            text default null,
    p_transcript            text default null,
    p_transcript_locale     text default null,
    p_transcript_engine     text default null,
    p_transcript_confidence double precision default null,
    p_title                 text default null
)
returns public.memos
language plpgsql
security invoker           -- runs as the caller, so RLS still applies
set search_path = public
as $$
declare
    result public.memos;
begin
    insert into public.memos as m (
        id, user_id, started_at, duration_seconds, byte_count, source_device,
        audio_path, transcript, transcript_locale, transcript_engine,
        transcript_confidence, title
    )
    values (
        p_id, auth.uid(), p_started_at, p_duration_seconds, p_byte_count,
        p_source_device, p_audio_path, p_transcript, p_transcript_locale,
        p_transcript_engine, p_transcript_confidence, p_title
    )
    on conflict (id) do update set
        -- coalesce(new, old): a later write may fill in a missing field but
        -- never blanks one that is already populated.
        audio_path            = coalesce(excluded.audio_path, m.audio_path),
        transcript            = coalesce(excluded.transcript, m.transcript),
        transcript_locale     = coalesce(excluded.transcript_locale, m.transcript_locale),
        transcript_engine     = coalesce(excluded.transcript_engine, m.transcript_engine),
        transcript_confidence = coalesce(excluded.transcript_confidence, m.transcript_confidence),
        title                 = coalesce(excluded.title, m.title),
        duration_seconds      = greatest(excluded.duration_seconds, m.duration_seconds),
        byte_count            = greatest(excluded.byte_count, m.byte_count)
    returning * into result;

    return result;
end;
$$;

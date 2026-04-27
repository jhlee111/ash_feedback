# Audio core promotion

**Status**: proposed
**Est**: 1–2 hours of code + README + smoke
**Supersedes**: [ADR-0001 Question B](../decisions/0001-audio-narration-via-ash-storage.md#question-b--optional-or-required-dependency) — see addendum 2026-04-26 in that ADR

## Motivation

Audio narration is the load-bearing differentiator of ash_feedback
over "a thin Ash wrapper around phoenix_replay." Today it ships as
an optional, gated feature: `:ash_storage` is `optional: true`,
audio is enabled only when both the dep is loadable and
`config :ash_feedback, audio_enabled: true` is set. This
under-states what the library is for and adds friction to adopters
who came specifically for the voice-context feature.

Adopting AshStorage as a hard dep also signals reference adoption of
a new Ash core extension — fits ash_feedback's role as a showcase
for Ash community patterns.

ADR-0001's Question B addendum (2026-04-26) accepts the promotion to
core. This plan tracks the execution.

## Scope

1. **`mix.exs`** — drop `optional: true` from the `:ash_storage`
   entry. Hosts pulling in `ash_feedback` automatically get
   `ash_storage` transitively.
2. **`AshFeedback.Resources.Feedback.Setup.audio_enabled?/0`** —
   delete. All call sites that gate on it inline the always-true
   path.
3. **`AshFeedback.Resources.Feedback.__using__/1`** — always declare
   `has_one_attached :audio_clip`; always emit the audio submit-arg
   wiring; `:audio_blob_resource` and `:audio_attachment_resource`
   become **required** opts. `Setup.validate_audio_opts!/2` keeps
   its guided ArgumentError but is no longer conditional on the flag.
4. **`AshFeedback.Storage.submit/3`** — drop the silent-drop branch
   that ignored `audio_clip_blob_id` when audio was disabled. With
   audio always on, the field always lands.
5. **`AshFeedback.Config`** — strip the `:audio_enabled` reference
   from the docstring. Keep the runtime tuning keys
   (`:audio_attachment_resource`, `:audio_max_seconds`,
   `:audio_download_url_ttl_seconds`).
6. **README** — restructure:
   - Move "Audio narration" out of "Optional features."
   - Inline AshStorage `Blob`/`Attachment` setup + service config
     into Installation as a numbered step (likely between current
     step 3 and step 4, or as a sub-step of step 5).
   - Drop the "default: off" framing; drop the `audio_enabled` flag
     mention.
   - Keep the "host owns Blob/Attachment because storage backend is
     host-specific" note (still true).
   - Add `audio_default={:on}` to the step 9 widget snippet.
7. **`docs/guides/audio-narration.md`** — remove the toggle section;
   the guide becomes "wire AshStorage Blob/Attachment for
   ash_feedback, plus admin playback wiring." Update title to
   reflect that audio is core.
8. **`CHANGELOG`** — note the breaking change. Hosts that didn't
   add `:ash_storage` will fail to compile until they do; hosts
   relying on `audio_enabled: false` will get the audio surface
   they didn't ask for. Per memory
   `project_library_breaking_changes_ok.md`, the demo is the sole
   consumer; we can break cleanly.

## Tests

- Existing audio round-trip test (`test/ash_feedback/audio_round_trip_test.exs`)
  still passes — it already runs with audio enabled.
- Add a compile-time test: a fixture resource that omits the audio
  opts must raise the new required-opt error with the same
  actionable message `Setup.validate_audio_opts!/2` produces today.
- Smoke: rebuild the demo against the new lib and confirm audio
  records + uploads + plays back without code changes (the demo
  already enables audio).

## Definition of Done

- Audio can no longer be turned off via config; the only way to opt
  out is "don't use ash_feedback."
- Demo still works without code changes (its config already sets
  `audio_enabled: true` and provides Blob/Attachment).
- README installation flow has zero "(optional)" markers around
  audio.
- ADR-0001 status reflects that Question B is superseded; this plan
  is referenced from the addendum.

## Out of scope

- Provided default `Blob`/`Attachment` templates for the `Disk` data
  layer (dev convenience). Followup if hosts ask; for now the
  audio-narration guide is the reference. The user's own
  `S3`/`Disk`/`MinIO` choice is still theirs.
- Phase 5f admin generator integration — tracked separately in
  [`5f-igniter-installer.md`](5f-igniter-installer.md).
- Renaming `AshFeedback.Storage` → `AshFeedback.Adapters.PhoenixReplay`
  (collision with `AshStorage`). Discussed and deferred — the
  callout in README step 3 plus full module disambiguation in the
  text is judged sufficient for now.

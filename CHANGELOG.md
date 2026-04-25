# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Audio narration — Phase 1 (ADR-0001). Optional `:ash_storage`
  dependency wired into the `Feedback` resource macro behind a
  compile-time gate.
  - New optional dep: `{:ash_storage, "~> 0.1", optional: true}`.
  - Gate: `config :ash_feedback, audio_enabled: true` (default
    `false`) AND `Code.ensure_loaded?(AshStorage)` at compile time.
    Both must be true for the resource to extend with AshStorage.
  - When enabled, the macro emits `storage do has_one_attached
    :audio_clip do dependent :purge end end` on the host's concrete
    `Feedback` resource. Cascade-on-purge means the blob + S3 object
    follow the parent feedback row's lifecycle (ADR-0001 Question E).
  - Default behavior unchanged for hosts that don't enable audio —
    no extra extension surface, no FK column, no AshStorage dep
    pulled in.
  - Recorder JS, presigned-upload flow, and `audio_start_offset_ms`
    persistence land in Phase 2; admin playback synced to
    phoenix_replay's timeline event bus (ADR-0005) lands in Phase 3.
- Phase 0 scaffold: repo, Hex metadata, CI, module stubs. Depends on
  `phoenix_replay` via path dep during incubation.

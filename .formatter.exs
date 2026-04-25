# Used by "mix format"
#
# `import_deps` pulls `locals_without_parens` from each dep's exported
# .formatter.exs (Spark/Ash convention). Some deps (notably ash_storage)
# don't export their DSL macros yet, so they're listed below explicitly.
[
  import_deps: [
    :phoenix,
    :phoenix_live_view,
    :ash,
    :ash_postgres,
    :ash_paper_trail,
    :ash_state_machine,
    :spark,
    :reactor
  ],
  locals_without_parens: [
    # ash_storage DSL — not yet exported by ash_storage/.formatter.exs.
    blob_resource: 1,
    attachment_resource: 1,
    has_one_attached: 1,
    has_one_attached: 2,
    has_many_attached: 1,
    has_many_attached: 2
  ],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]

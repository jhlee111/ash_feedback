# Rules for working with AshPrefixedId

AshPrefixedId (formerly AshObjectIds) adds prefixed UUID identifiers to Ash resources. IDs appear as `"prefix_Base58EncodedUUID"` in the application layer but are stored as native PostgreSQL UUID binary (16 bytes) in the database.

## Resource Setup

```elixir
defmodule MyApp.Members.Member do
  use Ash.Resource,
    extensions: [AshPrefixedId]

  prefixed_id do
    prefix "mbr"              # 2-4 character prefix (required)
    migration_default? true   # Adds uuid_generate_v7() as DB default
  end

  attributes do
    uuid_v7_primary_key :id   # Required: single UUID primary key
  end
end
```

This generates `MyApp.Members.Member.ObjectId` — the Ash.Type for this resource's ID. FK attributes for `belongs_to` relationships are auto-set to the destination's ObjectId type.

## The Three Layers

| Layer | Format | Example |
|-------|--------|---------|
| **Database** | UUID binary (16 bytes) | `<<1, 157, 58, 187, ...>>` |
| **Ash Application** | Prefixed string | `"mbr_CZXoPFPpJrmAAczvWZs3s"` |
| **Raw SQL / Ecto** | UUID binary or string | `"019d3abb-e112-7417-bf67-..."` |

## Inside Ash — Automatic (No Action Needed)

```elixir
# All of these just work — type conversion is automatic
Ash.get!(Member, "mbr_CZXoPFPpJrmAAczvWZs3s", scope: scope)
Ash.Query.filter(Member, id == ^"mbr_CZXoPFPpJrmAAczvWZs3s")
Member |> Ash.Query.filter(home_center_id == ^some_prefixed_id) |> Ash.read!(scope: scope)
```

## Crossing the Boundary — MUST Use Helpers

When dropping below the Ash layer into raw SQL fragments or `Repo.query`, prefixed IDs must be explicitly converted. **Never pass a prefixed string directly to a raw SQL parameter.**

### Ash → Raw SQL (decode)

```elixir
# One-liner: prefixed ID → 16-byte UUID binary
uuid_bin = AshPrefixedId.to_uuid!("tnt_CZXoPFPpJrmAAczvWZs3s")

# If you need the UUID string format (e.g., for logging)
uuid_str = AshPrefixedId.to_uuid_string!("tnt_CZXoPFPpJrmAAczvWZs3s")
# => "019d3abb-e112-7417-bf67-6e3e82b31a5e"
```

### Raw SQL → Ash (encode)

```elixir
# 16-byte binary or UUID string → prefixed ID
prefixed = AshPrefixedId.to_prefixed_id(<<1, 157, ...>>, "tnt")
# => "tnt_CZXoPFPpJrmAAczvWZs3s"

# Get prefix from a resource module
prefix = AshPrefixedId.Info.prefixed_id_prefix!(MyApp.Tenants.Tenant)
```

### In Ash Fragments

```elixir
# WRONG — Postgrex cannot encode prefixed string as UUID
fragment("... WHERE tenant_id = ?", ^tenant_id)

# CORRECT — decode to binary first
tenant_uuid = AshPrefixedId.to_uuid!(tenant_id)
fragment("... WHERE tenant_id = ?", ^tenant_uuid)

# Ash attribute references (no ^) are auto-handled
fragment("? IN (SELECT ...)", contact_id)  # contact_id resolved by Ash
```

### In Raw Ecto Queries

```elixir
uuid_bin = AshPrefixedId.to_uuid!(user_id)
Repo.query!("DELETE FROM user_org_roles WHERE user_id = $1", [uuid_bin])
```

### Error-Handling Pattern (when input may be invalid)

```elixir
case AshPrefixedId.Type.decode_object_id(input) do
  {:ok, _prefix, uuid_bin} -> Ecto.UUID.cast!(uuid_bin)
  _ -> input  # fallback
end
```

Use `to_uuid!/1` when the ID is known-valid (from Ash). Use `Type.decode_object_id/1` when the ID comes from external input and may be invalid.

## DO NOT Use `type(^id, :uuid)` in Fragments

`type(^id, :uuid)` is unreliable — it sometimes works, sometimes produces `NULL::uuid::uuid::uuid`. Always use explicit `AshPrefixedId.to_uuid!/1` instead.

## Config

```elixir
# config/config.exs — makes all :uuid fields accept prefixed IDs
config :ash,
  custom_types: [uuid: AshPrefixedId.AnyPrefixedId]
```

```elixir
# lib/my_app/repo.ex — installs uuid_generate_v7() PostgreSQL function
def installed_extensions do
  ["ash-functions", AshPrefixedId.PostgresExtension, ...]
end
```

## AshPaperTrail Compatibility

AshPaperTrail creates version resources before AshPrefixedId generates ObjectId types (transformer vs persister ordering). Use the GsNet workaround:

```elixir
paper_trail do
  version_extensions extensions: [GsNet.PaperTrail.PrefixedIdExtension],
                     authorizers: [Ash.Policy.Authorizer]
end
```

## Encoding

- **Base58** (Bitcoin alphabet, excludes `0/O/I/l`) via `erl_base58`
- NOT Base62, NOT Crockford Base32
- DB storage: native `uuid` (16-byte binary), NOT varchar

## Common Mistakes

1. **Passing prefixed ID to raw SQL** — Always use `to_uuid!/1` first
2. **Using `type(^id, :uuid)` in fragments** — Unreliable, use `to_uuid!/1`
3. **Hardcoding IDs from old sessions** — Base58 encoding changed; always read from DB
4. **Circular `belongs_to` between two AshPrefixedId resources** — Use plain `:uuid` for the optional side
5. **Forgetting `require Ash.Query`** — Needed in `prepare` callbacks that use `Ash.Query.filter`

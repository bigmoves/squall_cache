# squall_cache

[![Package Version](https://img.shields.io/hexpm/v/squall_cache)](https://hex.pm/packages/squall_cache)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/squall_cache/)

A normalized GraphQL cache for Lustre applications with optimistic mutation support. Built to work with the [Squall](https://github.com/bigmoves/squall) GraphQL client.

## Features

- **Relay-style Normalized Caching** - Entities are stored by global ID and referenced throughout the cache, preventing data duplication and ensuring consistency
- **Optimistic Mutations** - Update the UI immediately with optimistic data, then commit on success or rollback on failure
- **Automatic Query Batching** - Multiple simultaneous queries are automatically batched and deduplicated
- **Type-Safe Integration** - Works with Squall's generated types and decoders for compile-time safety
- **Lustre Effects** - Returns Lustre effects for seamless integration with the Elm Architecture

## Installation

```sh
gleam add squall_cache@1
```

## Basic Usage

### 1. Initialize the Cache

```gleam
import squall_cache

// Create a new cache with your GraphQL endpoint
let cache = squall_cache.new("https://api.example.com/graphql")

// Or with custom headers (e.g., for authentication)
let cache = squall_cache.new_with_headers(
  "https://api.example.com/graphql",
  fn() {
    [#("Authorization", "Bearer " <> get_token())]
  }
)
```

### 2. Query Data

```gleam
import gleam/json
import squall_cache

// Look up a query - returns the current state and potentially updated cache
let #(updated_cache, result) = squall_cache.lookup(
  cache,
  "GetUser",
  json.object([#("id", json.string("123"))]),
  parse_user_response,
)

// Handle the result
case result {
  squall_cache.Loading -> html.text("Loading...")
  squall_cache.Failed(err) -> html.text("Error: " <> err)
  squall_cache.Data(user) -> html.text("Hello, " <> user.name)
}
```

### 3. Process Pending Fetches

After calling `lookup`, you need to process any pending fetches to actually make the network requests:

```gleam
// Process all pending fetches and get effects
let #(final_cache, effects) = squall_cache.process_pending(
  updated_cache,
  registry,
  HandleQueryResponse,
  fn() { timestamp() },
)

// Return the effects to Lustre
#(Model(..model, cache: final_cache), effect.batch(effects))
```

### 4. Handle Query Responses

```gleam
pub type Msg {
  HandleQueryResponse(String, Json, Result(String, String))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    HandleQueryResponse(query_name, variables, Ok(response_body)) -> {
      // Store the response in the cache
      let cache_with_data = squall_cache.store_query(
        model.cache,
        query_name,
        variables,
        response_body,
        timestamp(),
      )

      // Process any new pending fetches
      let #(final_cache, effects) = squall_cache.process_pending(
        cache_with_data,
        model.registry,
        HandleQueryResponse,
        fn() { timestamp() },
      )

      #(Model(..model, cache: final_cache), effect.batch(effects))
    }

    HandleQueryResponse(_, _, Error(err)) -> {
      // Handle error...
      #(model, effect.none())
    }
  }
}
```

## Optimistic Mutations

Optimistic mutations update the UI immediately, then commit or rollback based on the server response:

```gleam
pub type Msg {
  HandleMutationResponse(String, Result(UpdateUserResponse, String), String)
  UpdateUserName(String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateUserName(new_name) -> {
      // Variables for the mutation
      let variables = json.object([#("name", json.string(new_name))])

      // Optimistic entity update
      let optimistic_updater = fn(_current) {
        json.object([
          #("id", json.string("User:123")),
          #("name", json.string(new_name)),
        ])
      }

      // Execute optimistic mutation
      let #(updated_cache, mutation_id, mutation_effect) =
        squall_cache.execute_optimistic_mutation(
          model.cache,
          model.registry,
          "UpdateUser",
          variables,
          "User:123",
          optimistic_updater,
          parse_update_user_response,
          HandleMutationResponse,
        )

      #(Model(..model, cache: updated_cache), mutation_effect)
    }

    HandleMutationResponse(mutation_id, Ok(_data), response_body) -> {
      // Success - commit the optimistic update with the response
      let cache = squall_cache.commit_optimistic(model.cache, mutation_id, response_body)
      #(Model(..model, cache: cache), effect.none())
    }

    HandleMutationResponse(mutation_id, Error(_err), _response_body) -> {
      // Failure - rollback the optimistic update
      let cache = squall_cache.rollback_optimistic(model.cache, mutation_id)
      #(Model(..model, cache: cache), effect.none())
    }
  }
}
```

### Check Pending Mutations

You can check if there are any pending optimistic mutations (useful for showing loading states):

```gleam
let is_saving = squall_cache.has_pending_mutations(cache)

case is_saving {
  True -> html.button([attribute.disabled(True)], [html.text("Saving...")])
  False -> html.button([event.on_click(Submit)], [html.text("Save")])
}
```

## Complete Example

```gleam
import gleam/json
import lustre
import lustre/effect.{type Effect}
import squall_cache
import squall/registry

pub type Model {
  Model(cache: squall_cache.Cache, registry: registry.Registry)
}

pub type Msg {
  HandleQueryResponse(String, json.Json, Result(String, String))
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let cache = squall_cache.new("https://api.example.com/graphql")
  let registry = init_registry()

  // Fetch initial data
  let #(cache_with_lookup, _) = squall_cache.lookup(
    cache,
    "GetUser",
    json.object([#("id", json.string("123"))]),
    parse_user_response,
  )

  let #(final_cache, effects) = squall_cache.process_pending(
    cache_with_lookup,
    registry,
    HandleQueryResponse,
    fn() { 0 },
  )

  #(Model(cache: final_cache, registry: registry), effect.batch(effects))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    HandleQueryResponse(query_name, variables, Ok(response_body)) -> {
      let cache = squall_cache.store_query(
        model.cache,
        query_name,
        variables,
        response_body,
        0,
      )

      let #(final_cache, effects) = squall_cache.process_pending(
        cache,
        model.registry,
        HandleQueryResponse,
        fn() { 0 },
      )

      #(Model(..model, cache: final_cache), effect.batch(effects))
    }

    HandleQueryResponse(_, _, Error(_)) -> #(model, effect.none())
  }
}

fn view(model: Model) -> element.Element(Msg) {
  let #(_, result) = squall_cache.lookup(
    model.cache,
    "GetUser",
    json.object([#("id", json.string("123"))]),
    parse_user_response,
  )

  case result {
    squall_cache.Loading -> html.text("Loading...")
    squall_cache.Failed(err) -> html.text("Error: " <> err)
    squall_cache.Data(user) -> html.text("Hello, " <> user.name)
  }
}
```

## How It Works

### Entity Normalization

When query results are stored, entities with an `id` field are extracted and stored separately in the cache. References to these entities are replaced with `{"__ref": "EntityID"}` objects. This ensures that:

1. Entities are stored once, not duplicated across queries
2. Updates to an entity are reflected everywhere it's used
3. Cache size is minimized

### Optimistic Updates

Optimistic mutations work by:

1. Creating an "optimistic entity" that overlays the real entity
2. Immediately updating the UI with this optimistic data
3. Sending the mutation to the server
4. On success: removing the optimistic entity (real data from response is now in cache)
5. On failure: removing the optimistic entity (real data is restored)

This provides instant feedback while maintaining data consistency.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam build # Build the project
```

## License

Apache License 2.0.

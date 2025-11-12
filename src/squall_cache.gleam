import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/javascript/promise
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lustre/effect.{type Effect}
import squall
import squall/registry.{type Registry}

/// Result of a query lookup - Loading, Failed, or Data
pub type QueryResult(data) {
  Loading
  Failed(String)
  Data(data)
}

/// Cache status indicating freshness of data
pub type CacheStatus {
  Fresh
  Stale
  CacheLoading
}

/// A cached entry with data, timestamp, and status
pub type CacheEntry {
  CacheEntry(data: String, timestamp: Int, status: CacheStatus)
}

/// Normalized cache storing entities and query results
pub type Cache {
  Cache(
    /// Normalized entities: global_id -> entity
    entities: Dict(String, Json),
    /// Optimistic entity updates: global_id -> entity (checked first during denormalization)
    optimistic_entities: Dict(String, Json),
    /// Track pending optimistic mutations: mutation_id -> entity_id
    optimistic_mutations: Dict(String, String),
    /// Query results: query_key -> entry
    queries: Dict(String, CacheEntry),
    /// Queries that need to be fetched
    pending_fetches: Set(String),
    /// Function to get headers for requests (called at fetch time)
    get_headers: fn() -> List(#(String, String)),
    /// Counter for generating unique mutation IDs
    mutation_counter: Int,
    /// Global GraphQL endpoint for all queries
    endpoint: String,
  )
}

/// Create a new empty cache with an endpoint and no headers
pub fn new(endpoint: String) -> Cache {
  Cache(
    entities: dict.new(),
    optimistic_entities: dict.new(),
    optimistic_mutations: dict.new(),
    queries: dict.new(),
    pending_fetches: set.new(),
    get_headers: fn() { [] },
    mutation_counter: 0,
    endpoint: endpoint,
  )
}

/// Create a new empty cache with an endpoint and a function to provide headers
pub fn new_with_headers(
  endpoint: String,
  get_headers: fn() -> List(#(String, String)),
) -> Cache {
  Cache(
    entities: dict.new(),
    optimistic_entities: dict.new(),
    optimistic_mutations: dict.new(),
    queries: dict.new(),
    pending_fetches: set.new(),
    get_headers: get_headers,
    mutation_counter: 0,
    endpoint: endpoint,
  )
}

/// Generate a cache key from query name and variables
pub fn make_query_key(query_name: String, variables: Json) -> String {
  query_name <> ":" <> json.to_string(variables)
}

/// Get a query result from the cache
pub fn get_query(
  cache: Cache,
  query_name: String,
  variables: Json,
) -> Option(CacheEntry) {
  let key = make_query_key(query_name, variables)
  dict.get(cache.queries, key) |> option.from_result
}

/// Store a query result in the cache with entity normalization
pub fn store_query(
  cache: Cache,
  query_name: String,
  variables: Json,
  data: String,
  timestamp: Int,
) -> Cache {
  let key = make_query_key(query_name, variables)

  // Parse the response and extract entities
  case json.parse(data, decode.dynamic) {
    Ok(parsed_data) -> {
      // Extract entities from the response
      let #(entities_dict, normalized_data) = extract_entities(parsed_data)

      // Merge extracted entities into cache
      let updated_entities = merge_entities(cache.entities, entities_dict)

      // Store the normalized data (with entity references)
      let normalized_data_str = json.to_string(normalized_data)
      let entry = CacheEntry(data: normalized_data_str, timestamp: timestamp, status: Fresh)
      let new_queries = dict.insert(cache.queries, key, entry)

      Cache(..cache, queries: new_queries, entities: updated_entities)
    }
    Error(_) -> {
      // If parsing fails, store as-is
      let entry = CacheEntry(data: data, timestamp: timestamp, status: Fresh)
      let new_queries = dict.insert(cache.queries, key, entry)
      Cache(..cache, queries: new_queries)
    }
  }
}

/// Extract entities from a dynamic value
/// Returns a dict of global_id -> Json
fn extract_entities(value: decode.Dynamic) -> #(Dict(String, Json), Json) {
  extract_entities_with_path(value, [])
}

/// Extract entities from a dynamic value with path tracking for unique keys
/// Path is built as we traverse (e.g., ["data", "episodes", "results"])
fn extract_entities_with_path(
  value: decode.Dynamic,
  path: List(String),
) -> #(Dict(String, Json), Json) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(obj) -> {
      // Check if this is an entity (has "id" field)
      case dict.get(obj, "id") {
        Ok(id_value) -> {
          case decode.run(id_value, decode.string) {
            Ok(id) -> {
              // Try to get __typename for proper cache keying (Relay-style)
              let typename = case dict.get(obj, "__typename") {
                Ok(typename_value) -> case decode.run(typename_value, decode.string) {
                  Ok(t) -> t
                  Error(_) -> infer_typename_from_path(path)
                }
                Error(_) -> infer_typename_from_path(path)
              }

              // Create a globally unique ID: typename:id (Relay-style)
              let global_id = typename <> ":" <> id

              // This is an entity - extract it and recursively extract nested entities
              let field_results = dict.to_list(obj)
                |> list.map(fn(pair) {
                  let #(k, v) = pair
                  let field_path = list.append(path, [k])
                  let #(nested_entities, normalized_value) = extract_entities_with_path(v, field_path)
                  #(k, nested_entities, normalized_value)
                })

              // Collect all nested entities
              let all_nested_entities = list.fold(field_results, dict.new(), fn(acc, result) {
                let #(_, entities, _) = result
                merge_entities(acc, entities)
              })

              // Build the entity with normalized field values
              let entity_json = list.map(field_results, fn(result) {
                let #(k, _, normalized) = result
                #(k, normalized)
              })
              |> json.object

              // Merge this entity with all nested entities using the global_id
              let entities_dict = dict.insert(all_nested_entities, global_id, entity_json)

              // Return reference with the global_id
              #(entities_dict, json.object([#("__ref", json.string(global_id))]))
            }
            Error(_) -> {
              // Has id but not a string, recurse into fields
              extract_from_object_with_path(obj, path)
            }
          }
        }
        Error(_) -> {
          // No id field, recurse into fields
          extract_from_object_with_path(obj, path)
        }
      }
    }
    Error(_) -> {
      // Try array
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> {
          // Check if this is a connection edges array (items have "node" field)
          let is_edges = is_edges_array(value)

          case is_edges {
            True -> {
              // This is a connection edges array - deduplicate by node ID
              extract_connection_edges(items, path)
            }
            False -> {
              // Regular array - process normally
              let results = list.map(items, fn(item) {
                extract_entities_with_path(item, path)
              })
              let all_entities = list.fold(results, dict.new(), fn(acc, result) {
                let #(entities, _) = result
                merge_entities(acc, entities)
              })
              let normalized_items = list.map(results, fn(result) {
                let #(_, norm) = result
                norm
              })
              #(all_entities, json.array(normalized_items, fn(x) { x }))
            }
          }
        }
        Error(_) -> {
          // Scalar value, return as-is
          #(dict.new(), dynamic_to_json(value))
        }
      }
    }
  }
}

/// Infer typename from path by looking for plural entity names
/// E.g., ["data", "episodes", "results"] -> "Episode"
/// E.g., ["data", "character"] -> "Character"
fn infer_typename_from_path(path: List(String)) -> String {
  // Look through path backwards for the entity type
  path
  |> list.reverse
  |> list.find_map(fn(segment) {
    case segment {
      // Skip common wrapper keys
      "data" | "results" | "edges" | "node" -> Error(Nil)
      // Plurals - try to singularize
      _ -> case string.ends_with(segment, "s") {
        True -> {
          // Remove trailing 's' by taking all but last character
          let len = string.length(segment)
          let singular = string.slice(segment, 0, len - 1)
          // Capitalize first letter
          Ok(capitalize(singular))
        }
        False -> Ok(capitalize(segment))
      }
    }
  })
  |> result.unwrap("Entity")
}

/// Capitalize the first letter of a string
fn capitalize(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> s
  }
}

/// Check if an object looks like a connection edge (has "node" field)
fn is_connection_edge(obj: Dict(String, decode.Dynamic)) -> Bool {
  case dict.get(obj, "node") {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Check if a value is an array of connection edges
fn is_edges_array(value: decode.Dynamic) -> Bool {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) -> {
      // Check if first item is an edge (has "node")
      case items {
        [] -> False
        [first, ..] -> case decode.run(first, decode.dict(decode.string, decode.dynamic)) {
          Ok(obj) -> is_connection_edge(obj)
          Error(_) -> False
        }
      }
    }
    Error(_) -> False
  }
}

/// Extract connection edges with deduplication by node ID (Relay-style)
/// Returns #(entities, normalized_edges_array)
fn extract_connection_edges(
  edges: List(decode.Dynamic),
  path: List(String),
) -> #(Dict(String, Json), Json) {
  // Process edges and track seen node IDs for deduplication
  let #(all_entities, normalized_edges, _seen_node_ids) =
    list.fold(edges, #(dict.new(), [], set.new()), fn(acc, edge_dynamic) {
      let #(entities_acc, edges_acc, seen_ids) = acc

      // Try to extract the edge as an object
      case decode.run(edge_dynamic, decode.dict(decode.string, decode.dynamic)) {
        Ok(edge_obj) -> {
          // Extract the node to check its ID
          case dict.get(edge_obj, "node") {
            Ok(node_value) -> {
              // Check if node has an ID for deduplication
              let node_id = case decode.run(node_value, decode.dict(decode.string, decode.dynamic)) {
                Ok(node_obj) -> case dict.get(node_obj, "id") {
                  Ok(id_value) -> case decode.run(id_value, decode.string) {
                    Ok(id) -> {
                      // Try to get typename for full global ID
                      let typename = case dict.get(node_obj, "__typename") {
                        Ok(typename_value) -> case decode.run(typename_value, decode.string) {
                          Ok(t) -> t
                          Error(_) -> "Node"
                        }
                        Error(_) -> infer_typename_from_path(list.append(path, ["node"]))
                      }
                      option.Some(typename <> ":" <> id)
                    }
                    Error(_) -> option.None
                  }
                  Error(_) -> option.None
                }
                Error(_) -> option.None
              }

              // Check if we've seen this node before
              case node_id {
                option.Some(id) -> {
                  case set.contains(seen_ids, id) {
                    True -> {
                      // Skip duplicate - already seen this node
                      acc
                    }
                    False -> {
                      // New node - process the full edge
                      let #(edge_entities, normalized_edge) = extract_from_object_with_path(edge_obj, path)
                      let merged_entities = merge_entities(entities_acc, edge_entities)
                      #(merged_entities, list.append(edges_acc, [normalized_edge]), set.insert(seen_ids, id))
                    }
                  }
                }
                option.None -> {
                  // No ID - process normally without deduplication
                  let #(edge_entities, normalized_edge) = extract_from_object_with_path(edge_obj, path)
                  let merged_entities = merge_entities(entities_acc, edge_entities)
                  #(merged_entities, list.append(edges_acc, [normalized_edge]), seen_ids)
                }
              }
            }
            Error(_) -> {
              // No node field - process as regular object
              let #(edge_entities, normalized_edge) = extract_from_object_with_path(edge_obj, path)
              let merged_entities = merge_entities(entities_acc, edge_entities)
              #(merged_entities, list.append(edges_acc, [normalized_edge]), seen_ids)
            }
          }
        }
        Error(_) -> {
          // Not an object - process as regular value
          let #(edge_entities, normalized_edge) = extract_entities_with_path(edge_dynamic, path)
          let merged_entities = merge_entities(entities_acc, edge_entities)
          #(merged_entities, list.append(edges_acc, [normalized_edge]), seen_ids)
        }
      }
    })

  #(all_entities, json.array(normalized_edges, fn(x) { x }))
}

/// Extract entities from an object's fields with path tracking
fn extract_from_object_with_path(
  obj: Dict(String, decode.Dynamic),
  path: List(String),
) -> #(Dict(String, Json), Json) {
  let field_results = dict.to_list(obj)
    |> list.map(fn(pair) {
      let #(key, value) = pair
      let field_path = list.append(path, [key])
      let #(entities, normalized) = extract_entities_with_path(value, field_path)
      #(key, entities, normalized)
    })

  // Merge all entities
  let all_entities = list.fold(field_results, dict.new(), fn(acc, result) {
    let #(_, entities, _) = result
    merge_entities(acc, entities)
  })

  // Build normalized object
  let normalized_obj = list.map(field_results, fn(result) {
    let #(key, _, normalized) = result
    #(key, normalized)
  })
  |> json.object

  #(all_entities, normalized_obj)
}

/// Merge two entity dicts
/// When an entity exists in both dicts, merge their fields together
fn merge_entities(
  dict1: Dict(String, Json),
  dict2: Dict(String, Json),
) -> Dict(String, Json) {
  dict.fold(dict2, dict1, fn(acc, key, new_entity) {
    case dict.get(acc, key) {
      Ok(existing_entity) -> {
        // Entity already exists - merge the fields
        let merged = merge_json_objects(existing_entity, new_entity)
        dict.insert(acc, key, merged)
      }
      Error(_) -> {
        // New entity - just insert it
        dict.insert(acc, key, new_entity)
      }
    }
  })
}

/// Merge two JSON objects by decoding fields and rebuilding with json constructors
fn merge_json_objects(existing: Json, new: Json) -> Json {
  let existing_str = json.to_string(existing)
  let new_str = json.to_string(new)

  // Parse both as Dynamic and decode as dicts
  case json.parse(existing_str, decode.dynamic), json.parse(new_str, decode.dynamic) {
    Ok(existing_dyn), Ok(new_dyn) -> {
      case
        decode.run(existing_dyn, decode.dict(decode.string, decode.dynamic)),
        decode.run(new_dyn, decode.dict(decode.string, decode.dynamic))
      {
        Ok(existing_dict), Ok(new_dict) -> {
          // Get all unique keys
          let all_keys =
            list.append(dict.keys(existing_dict), dict.keys(new_dict))
            |> list.unique

          // Merge fields: new overrides existing
          let merged_fields = list.filter_map(all_keys, fn(key) {
            // Prefer new value if present
            let maybe_value = case dict.get(new_dict, key) {
              Ok(v) -> Ok(v)
              Error(_) -> dict.get(existing_dict, key)
            }

            case maybe_value {
              Ok(dynamic_value) -> {
                // Convert Dynamic to Json
                Ok(#(key, dynamic_to_json(dynamic_value)))
              }
              Error(_) -> Error(Nil)
            }
          })

          // Construct merged JSON object
          json.object(merged_fields)
        }
        _, _ -> new
      }
    }
    _, _ -> new
  }
}

/// Mark a query as loading
pub fn mark_loading(
  cache: Cache,
  query_name: String,
  variables: Json,
) -> Cache {
  let key = make_query_key(query_name, variables)

  case dict.get(cache.queries, key) {
    Ok(entry) -> {
      let updated = CacheEntry(..entry, status: CacheLoading)
      let new_queries = dict.insert(cache.queries, key, updated)
      Cache(..cache, queries: new_queries)
    }
    Error(_) -> {
      // Create new loading entry with empty data
      let entry = CacheEntry(data: "", timestamp: 0, status: CacheLoading)
      let new_queries = dict.insert(cache.queries, key, entry)
      Cache(..cache, queries: new_queries)
    }
  }
}

/// Mark a query as stale
pub fn mark_stale(cache: Cache, query_name: String, variables: Json) -> Cache {
  let key = make_query_key(query_name, variables)

  case dict.get(cache.queries, key) {
    Ok(entry) -> {
      let updated = CacheEntry(..entry, status: Stale)
      let new_queries = dict.insert(cache.queries, key, updated)
      Cache(..cache, queries: new_queries)
    }
    Error(_) -> cache
  }
}

/// Invalidate (remove) a query from the cache
pub fn invalidate(cache: Cache, query_name: String, variables: Json) -> Cache {
  let key = make_query_key(query_name, variables)
  let new_queries = dict.delete(cache.queries, key)
  Cache(..cache, queries: new_queries)
}

/// Clear all cached queries
pub fn clear(cache: Cache) -> Cache {
  Cache(..cache, queries: dict.new())
}

/// Apply an optimistic update to an entity
/// The updater function receives the current entity (if it exists) and returns the updated entity
pub fn apply_optimistic_update(
  cache: Cache,
  mutation_id: String,
  entity_id: String,
  updater: fn(option.Option(Json)) -> Json,
) -> Cache {
  // Get the current entity value (checking optimistic first, then regular entities)
  let current = case dict.get(cache.optimistic_entities, entity_id) {
    Ok(entity) -> option.Some(entity)
    Error(_) -> case dict.get(cache.entities, entity_id) {
      Ok(entity) -> option.Some(entity)
      Error(_) -> option.None
    }
  }

  // Apply the updater to get the new optimistic value
  let optimistic_entity = updater(current)

  // Store the optimistic entity and track the mutation
  Cache(
    ..cache,
    optimistic_entities: dict.insert(cache.optimistic_entities, entity_id, optimistic_entity),
    optimistic_mutations: dict.insert(cache.optimistic_mutations, mutation_id, entity_id),
  )
}

/// Rollback an optimistic update (called when mutation fails)
pub fn rollback_optimistic(cache: Cache, mutation_id: String) -> Cache {
  case dict.get(cache.optimistic_mutations, mutation_id) {
    Ok(entity_id) -> {
      Cache(
        ..cache,
        optimistic_entities: dict.delete(cache.optimistic_entities, entity_id),
        optimistic_mutations: dict.delete(cache.optimistic_mutations, mutation_id),
      )
    }
    Error(_) -> cache
  }
}

/// Commit an optimistic update (called when mutation succeeds)
/// The real entity data should already be in the cache from store_query
pub fn commit_optimistic(cache: Cache, mutation_id: String, response_body: String) -> Cache {
  case dict.get(cache.optimistic_mutations, mutation_id) {
    Ok(entity_id) -> {
      // Parse and normalize the mutation response
      case json.parse(response_body, decode.dynamic) {
        Ok(data) -> {
          let #(extracted_entities, _normalized) = extract_entities(data)

          // Merge extracted entities into the main entity store
          let updated_entities = merge_entities(cache.entities, extracted_entities)

          Cache(
            ..cache,
            entities: updated_entities,
            optimistic_entities: dict.delete(cache.optimistic_entities, entity_id),
            optimistic_mutations: dict.delete(cache.optimistic_mutations, mutation_id),
          )
        }
        Error(_) -> {
          // If we can't parse the response, just remove optimistic data
          Cache(
            ..cache,
            optimistic_entities: dict.delete(cache.optimistic_entities, entity_id),
            optimistic_mutations: dict.delete(cache.optimistic_mutations, mutation_id),
          )
        }
      }
    }
    Error(_) -> cache
  }
}

/// Check if there are any pending optimistic mutations
pub fn has_pending_mutations(cache: Cache) -> Bool {
  !dict.is_empty(cache.optimistic_mutations)
}

/// Execute an optimistic mutation with automatic commit/rollback handling
/// This is the high-level API that encapsulates the entire optimistic update flow:
/// 1. Generates a unique mutation ID
/// 2. Applies optimistic update immediately
/// 3. Triggers the mutation
/// 4. Automatically commits on success or rolls back on failure
///
/// Returns:
/// - Updated cache with incremented mutation counter
/// - Mutation ID (for tracking/debugging)
/// - Effect that will trigger the mutation and handle response
pub fn execute_optimistic_mutation(
  cache: Cache,
  registry: Registry,
  query_name: String,
  variables: Json,
  entity_id: String,
  optimistic_updater: fn(option.Option(Json)) -> Json,
  parser: fn(String) -> Result(data, String),
  on_response: fn(String, Result(data, String), String) -> msg,
) -> #(Cache, String, Effect(msg)) {
  // Generate unique mutation ID
  let mutation_id = "mutation-" <> int.to_string(cache.mutation_counter)

  // Apply optimistic update
  let cache_with_optimistic = apply_optimistic_update(
    cache,
    mutation_id,
    entity_id,
    optimistic_updater,
  )

  // Increment mutation counter
  let cache_with_counter = Cache(
    ..cache_with_optimistic,
    mutation_counter: cache.mutation_counter + 1,
  )

  // Create the mutation effect
  let effect = create_mutation_effect(
    cache_with_counter,
    registry,
    query_name,
    variables,
    mutation_id,
    parser,
    on_response,
  )

  #(cache_with_counter, mutation_id, effect)
}

/// Create an effect for an optimistic mutation that handles commit/rollback
fn create_mutation_effect(
  cache: Cache,
  registry: Registry,
  query_name: String,
  variables: Json,
  mutation_id: String,
  parser: fn(String) -> Result(data, String),
  on_response: fn(String, Result(data, String), String) -> msg,
) -> Effect(msg) {
  case registry.get(registry, query_name) {
    Ok(meta) -> {
      effect.from(fn(dispatch) {
        let headers = cache.get_headers()
        let client = squall.new(cache.endpoint, headers)
        let assert Ok(req) = squall.prepare_request(client, meta.query, variables)

        let _promise =
          send_with_credentials(req)
          |> promise.map(fn(fetch_result) {
            case fetch_result {
              Ok(resp) -> {
                fetch.read_text_body(resp)
                |> promise.await(fn(text_result) {
                  case text_result {
                    Ok(text) -> {
                      case parser(text.body) {
                        Ok(data) -> {
                          // Success - dispatch with mutation_id and raw body so app can commit
                          dispatch(on_response(mutation_id, Ok(data), text.body))
                          promise.resolve(Nil)
                        }
                        Error(err) -> {
                          // Parse error - dispatch error so app can rollback
                          dispatch(on_response(mutation_id, Error("Parse error: " <> err), text.body))
                          promise.resolve(Nil)
                        }
                      }
                    }
                    Error(_) -> {
                      // Fetch error - dispatch error so app can rollback
                      dispatch(on_response(mutation_id, Error("Failed to read response"), ""))
                      promise.resolve(Nil)
                    }
                  }
                })
              }
              Error(_) -> {
                // Fetch error - dispatch error so app can rollback
                dispatch(on_response(mutation_id, Error("Failed to fetch"), ""))
                promise.resolve(Nil)
              }
            }
          })

        Nil
      })
    }
    Error(_) -> {
      // Query not found in registry - return error effect
      effect.from(fn(dispatch) {
        dispatch(on_response(mutation_id, Error("Query not found in registry"), ""))
        Nil
      })
    }
  }
}

/// Denormalize query data by replacing entity references with actual entities
/// Checks optimistic_entities first, then falls back to entities
fn denormalize(
  data_str: String,
  optimistic_entities: Dict(String, Json),
  entities: Dict(String, Json),
) -> String {
  case json.parse(data_str, decode.dynamic) {
    Ok(parsed) -> {
      let denormalized = denormalize_value(parsed, optimistic_entities, entities)
      json.to_string(denormalized)
    }
    Error(_) -> data_str
  }
}

/// Recursively denormalize a value by replacing __ref objects with entities
/// Checks optimistic_entities first, then falls back to entities
fn denormalize_value(
  value: decode.Dynamic,
  optimistic_entities: Dict(String, Json),
  entities: Dict(String, Json),
) -> Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(obj) -> {
      // Check if this is a reference object
      case dict.get(obj, "__ref") {
        Ok(ref_value) -> {
          case decode.run(ref_value, decode.string) {
            Ok(entity_id) -> {
              // Look up the entity (optimistic first, then regular)
              case dict.get(optimistic_entities, entity_id) {
                Ok(entity) -> entity
                Error(_) -> case dict.get(entities, entity_id) {
                  Ok(entity) -> entity
                  Error(_) -> {
                    // Entity not found, return the reference as-is
                    json.object([#("__ref", json.string(entity_id))])
                  }
                }
              }
            }
            Error(_) -> {
              // __ref is not a string, process as normal object
              denormalize_object(obj, optimistic_entities, entities)
            }
          }
        }
        Error(_) -> {
          // Not a reference, process as normal object
          denormalize_object(obj, optimistic_entities, entities)
        }
      }
    }
    Error(_) -> {
      // Try array
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> {
          json.array(items, fn(item) { denormalize_value(item, optimistic_entities, entities) })
        }
        Error(_) -> {
          // Scalar value, return as-is
          dynamic_to_json(value)
        }
      }
    }
  }
}

/// Denormalize an object's fields
fn denormalize_object(
  obj: Dict(String, decode.Dynamic),
  optimistic_entities: Dict(String, Json),
  entities: Dict(String, Json),
) -> Json {
  dict.to_list(obj)
  |> list.map(fn(pair) {
    let #(key, value) = pair
    #(key, denormalize_value(value, optimistic_entities, entities))
  })
  |> json.object
}

/// Lookup a query and return its current state
/// If not in cache, adds to pending_fetches
pub fn lookup(
  cache: Cache,
  query_name: String,
  variables: Json,
  parser: fn(String) -> Result(data, String),
) -> #(Cache, QueryResult(data)) {
  let key = make_query_key(query_name, variables)

  case dict.get(cache.queries, key) {
    Ok(entry) ->
      case entry.status {
        CacheLoading -> #(cache, Loading)
        Fresh | Stale -> {
          // Denormalize the data by replacing entity references with actual entities
          // Check optimistic entities first, then regular entities
          let denormalized_data = denormalize(entry.data, cache.optimistic_entities, cache.entities)
          case parser(denormalized_data) {
            Ok(parsed) -> #(cache, Data(parsed))
            Error(parse_err) -> #(cache, Failed("Parse error: " <> parse_err))
          }
        }
      }
    Error(_) -> {
      // Not in cache - add to pending fetches
      let updated_cache = Cache(
        ..cache,
        pending_fetches: set.insert(cache.pending_fetches, key),
      )
      #(updated_cache, Loading)
    }
  }
}

/// Process pending fetches and return effects
/// Call this after every update to trigger fetches
pub fn process_pending(
  cache: Cache,
  registry: Registry,
  on_response: fn(String, Json, Result(String, String)) -> msg,
  _get_timestamp: fn() -> Int,
) -> #(Cache, List(Effect(msg))) {
  let pending_list = set.to_list(cache.pending_fetches)

  // Create effects for each pending query
  let effects = list.filter_map(pending_list, fn(key) {
    // Extract query_name from key (format: "QueryName:{...}")
    case parse_query_key(key) {
      Ok(#(query_name, variables)) ->
        case registry.get(registry, query_name) {
          Ok(meta) -> {
            // Create fetch effect using query string from registry
            Ok(create_fetch_effect(
              cache,
              meta.query,
              query_name,
              variables,
              on_response,
            ))
          }
          Error(_) -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })

  // Mark all pending as loading
  let cache_with_loading = list.fold(pending_list, cache, fn(c, key) {
    case parse_query_key(key) {
      Ok(#(query_name, variables)) ->
        mark_loading(c, query_name, variables)
      Error(_) -> c
    }
  })

  // Clear pending fetches
  let final_cache = Cache(..cache_with_loading, pending_fetches: set.new())

  #(final_cache, effects)
}

/// Parse a cache key back into query_name and variables
fn parse_query_key(key: String) -> Result(#(String, Json), Nil) {
  case string.split_once(key, ":") {
    Ok(#(query_name, json_str)) -> {
      // Parse the JSON string back to a dynamic value, then convert to Json
      case json.parse(json_str, decode.dynamic) {
        Ok(dyn_value) -> {
          // Convert the dynamic value back to Json by going through string encoding
          // This is necessary because Gleam doesn't have a direct dynamic -> Json converter
          // For a proper solution, we should store variables separately in the cache
          Ok(#(query_name, dynamic_to_json(dyn_value)))
        }
        Error(_) -> Ok(#(query_name, json.null()))
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Helper to convert Dynamic to Json (simplified version)
fn dynamic_to_json(dyn: Dynamic) -> Json {
  // Try to decode as common types and re-encode
  case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
    Ok(dict_value) -> {
      // It's an object
      dict_value
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(key, val) = pair
        #(key, dynamic_to_json(val))
      })
      |> json.object
    }
    Error(_) ->
      case decode.run(dyn, decode.list(decode.dynamic)) {
        Ok(list_value) -> {
          // It's a list
          json.array(list_value, dynamic_to_json)
        }
        Error(_) ->
          case decode.run(dyn, decode.string) {
            Ok(str) -> json.string(str)
            Error(_) ->
              case decode.run(dyn, decode.int) {
                Ok(i) -> json.int(i)
                Error(_) ->
                  case decode.run(dyn, decode.float) {
                    Ok(f) -> json.float(f)
                    Error(_) ->
                      case decode.run(dyn, decode.bool) {
                        Ok(b) -> json.bool(b)
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}

/// Create a fetch effect for a GraphQL query
fn create_fetch_effect(
  cache: Cache,
  query: String,
  query_name: String,
  variables: Json,
  on_response: fn(String, Json, Result(String, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let headers = cache.get_headers()
    let client = squall.new(cache.endpoint, headers)
    let assert Ok(req) = squall.prepare_request(client, query, variables)

    let _promise =
      send_with_credentials(req)
      |> promise.map(fn(fetch_result) {
        case fetch_result {
          Ok(resp) -> {
            fetch.read_text_body(resp)
            |> promise.await(fn(text_result) {
              case text_result {
                Ok(text) -> {
                  dispatch(on_response(query_name, variables, Ok(text.body)))
                  promise.resolve(Nil)
                }
                Error(_) -> {
                  dispatch(on_response(
                    query_name,
                    variables,
                    Error("Failed to read response"),
                  ))
                  promise.resolve(Nil)
                }
              }
            })
          }
          Error(_) -> {
            dispatch(on_response(query_name, variables, Error("Failed to fetch")))
            promise.resolve(Nil)
          }
        }
      })

    Nil
  })
}

/// Send an HTTP request with credentials included (for cookies)
@external(javascript, "./squall_cache_ffi.mjs", "sendWithCredentials")
fn send_with_credentials(
  req: request.Request(String),
) -> promise.Promise(Result(response.Response(fetch.FetchBody), fetch.FetchError))

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should
import squall_cache

pub fn main() -> Nil {
  gleeunit.main()
}

// Test that storing a query with an entity extracts and caches the entity
pub fn store_query_extracts_entity_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // GraphQL response with Settings entity
  let response_data =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
              #("oauthClientId", json.string("some-client-id")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  // Store the query
  let updated_cache =
    squall_cache.store_query(
      cache,
      "GetSettings",
      json.object([]),
      response_data,
      0,
    )

  // Verify entity was extracted
  case dict.get(updated_cache.entities, "Settings:singleton") {
    Ok(entity) -> {
      // Entity should exist
      let entity_str = json.to_string(entity)
      // Check for the actual id value and other fields
      string.contains(entity_str, "singleton")
      |> should.be_true
      string.contains(entity_str, "fm.teal")
      |> should.be_true
    }
    Error(_) -> panic as "Expected entity to be extracted"
  }
}

// Test that storing a mutation response updates the entity
pub fn store_mutation_updates_entity_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Initial query response
  let initial_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
              #("oauthClientId", json.null()),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_after_query =
    squall_cache.store_query(cache, "GetSettings", json.object([]), initial_response, 0)

  // Mutation response with updated Settings
  let mutation_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "updateDomainAuthority",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("xyz.statusphere")),
              #("oauthClientId", json.null()),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_after_mutation =
    squall_cache.store_query(
      cache_after_query,
      "UpdateDomainAuthority",
      json.object([#("domainAuthority", json.string("xyz.statusphere"))]),
      mutation_response,
      1,
    )

  // Verify entity was updated
  case dict.get(cache_after_mutation.entities, "Settings:singleton") {
    Ok(entity) -> {
      let entity_str = json.to_string(entity)
      string.contains(entity_str, "xyz.statusphere")
      |> should.be_true
    }
    Error(_) -> panic as "Expected entity to exist after mutation"
  }
}

// Test extraction of multiple entities in an array
pub fn store_query_extracts_multiple_entities_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Response with array of entities
  let response_data =
    json.object([
      #(
        "data",
        json.object([
          #(
            "users",
            json.array(
              [
                json.object([
                  #("__typename", json.string("User")),
                  #("id", json.string("1")),
                  #("name", json.string("Alice")),
                ]),
                json.object([
                  #("__typename", json.string("User")),
                  #("id", json.string("2")),
                  #("name", json.string("Bob")),
                ]),
              ],
              fn(x) { x },
            ),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let updated_cache =
    squall_cache.store_query(cache, "GetUsers", json.object([]), response_data, 0)

  // Verify both entities were extracted
  case dict.get(updated_cache.entities, "User:1") {
    Ok(entity) -> {
      string.contains(json.to_string(entity), "Alice")
      |> should.be_true
    }
    Error(_) -> panic as "Expected User:1 to be extracted"
  }

  case dict.get(updated_cache.entities, "User:2") {
    Ok(entity) -> {
      string.contains(json.to_string(entity), "Bob")
      |> should.be_true
    }
    Error(_) -> panic as "Expected User:2 to be extracted"
  }
}

// Test that responses without entities don't crash
pub fn store_query_without_entities_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Response with no entities (just scalars)
  let response_data =
    json.object([
      #(
        "data",
        json.object([
          #("count", json.int(42)),
          #("message", json.string("success")),
        ]),
      ),
    ])
    |> json.to_string

  let updated_cache =
    squall_cache.store_query(cache, "GetCount", json.object([]), response_data, 0)

  // Entities should be empty
  dict.size(updated_cache.entities)
  |> should.equal(0)
}

// Test nested entities are extracted
pub fn store_query_extracts_nested_entities_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Response with nested entity
  let response_data =
    json.object([
      #(
        "data",
        json.object([
          #(
            "post",
            json.object([
              #("__typename", json.string("Post")),
              #("id", json.string("1")),
              #("title", json.string("Hello World")),
              #(
                "author",
                json.object([
                  #("__typename", json.string("User")),
                  #("id", json.string("1")),
                  #("name", json.string("Alice")),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let updated_cache =
    squall_cache.store_query(cache, "GetPost", json.object([]), response_data, 0)

  // Both entities should be extracted
  case dict.get(updated_cache.entities, "Post:1") {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected Post:1 to be extracted"
  }

  case dict.get(updated_cache.entities, "User:1") {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected User:1 to be extracted"
  }
}

// Test that lookups return denormalized data with latest entity values
pub fn lookup_returns_denormalized_data_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Initial query response
  let initial_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_after_query =
    squall_cache.store_query(cache, "GetSettings", json.object([]), initial_response, 0)

  // Mutation response with updated domain authority
  let mutation_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "updateDomainAuthority",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("xyz.statusphere")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_after_mutation =
    squall_cache.store_query(
      cache_after_query,
      "UpdateDomainAuthority",
      json.object([]),
      mutation_response,
      1,
    )

  // Now lookup the original query - it should return the UPDATED domain authority
  let #(_, result) =
    squall_cache.lookup(
      cache_after_mutation,
      "GetSettings",
      json.object([]),
      fn(response_str) {
        // Parse and return the domain authority
        case json.parse(response_str, decode.dynamic) {
          Ok(dyn) -> {
            case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
              Ok(root) -> {
                case dict.get(root, "data") {
                  Ok(data_dyn) -> {
                    case decode.run(data_dyn, decode.dict(decode.string, decode.dynamic)) {
                      Ok(data_dict) -> {
                        case dict.get(data_dict, "settings") {
                          Ok(settings_dyn) -> {
                            case decode.run(settings_dyn, decode.dict(decode.string, decode.dynamic)) {
                              Ok(settings_dict) -> {
                                case dict.get(settings_dict, "domainAuthority") {
                                  Ok(da_dyn) -> {
                                    case decode.run(da_dyn, decode.string) {
                                      Ok(da) -> Ok(da)
                                      Error(_) -> Error("Failed to parse domainAuthority")
                                    }
                                  }
                                  Error(_) -> Error("No domainAuthority field")
                                }
                              }
                              Error(_) -> Error("Settings not a dict")
                            }
                          }
                          Error(_) -> Error("No settings field")
                        }
                      }
                      Error(_) -> Error("Data not a dict")
                    }
                  }
                  Error(_) -> Error("No data field")
                }
              }
              Error(_) -> Error("Root not a dict")
            }
          }
          Error(_) -> Error("Failed to parse JSON")
        }
      },
    )

  // Verify we got the updated value
  case result {
    squall_cache.Data(domain_authority) -> {
      domain_authority
      |> should.equal("xyz.statusphere")
    }
    squall_cache.Loading -> panic as "Expected data, got Loading"
    squall_cache.Failed(_msg) -> panic as "Expected data, got Failed"
  }
}

// Test that optimistic updates are visible immediately
pub fn optimistic_update_visible_immediately_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Store initial entity
  let initial_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_with_entity =
    squall_cache.store_query(cache, "GetSettings", json.object([]), initial_response, 0)

  // Apply optimistic update (simplified - just create the new entity)
  let optimistic_entity =
    json.object([
      #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
      #("domainAuthority", json.string("xyz.statusphere")),
    ])

  let cache_with_optimistic =
    squall_cache.apply_optimistic_update(
      cache_with_entity,
      "mutation-1",
      "Settings:singleton",
      fn(_) { optimistic_entity },
    )

  // Lookup should return the optimistic value
  let #(_, result) =
    squall_cache.lookup(
      cache_with_optimistic,
      "GetSettings",
      json.object([]),
      fn(response_str) {
        case json.parse(response_str, decode.dynamic) {
          Ok(dyn) -> {
            case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
              Ok(root) -> {
                case dict.get(root, "data") {
                  Ok(data_dyn) -> {
                    case decode.run(data_dyn, decode.dict(decode.string, decode.dynamic)) {
                      Ok(data_dict) -> {
                        case dict.get(data_dict, "settings") {
                          Ok(settings_dyn) -> {
                            case decode.run(settings_dyn, decode.dict(decode.string, decode.dynamic)) {
                              Ok(settings_dict) -> {
                                case dict.get(settings_dict, "domainAuthority") {
                                  Ok(da_dyn) -> {
                                    case decode.run(da_dyn, decode.string) {
                                      Ok(da) -> Ok(da)
                                      Error(_) -> Error("Failed to parse domainAuthority")
                                    }
                                  }
                                  Error(_) -> Error("No domainAuthority field")
                                }
                              }
                              Error(_) -> Error("Settings not a dict")
                            }
                          }
                          Error(_) -> Error("No settings field")
                        }
                      }
                      Error(_) -> Error("Data not a dict")
                    }
                  }
                  Error(_) -> Error("No data field")
                }
              }
              Error(_) -> Error("Root not a dict")
            }
          }
          Error(_) -> Error("Failed to parse JSON")
        }
      },
    )

  case result {
    squall_cache.Data(domain_authority) -> {
      domain_authority
      |> should.equal("xyz.statusphere")
    }
    _ -> panic as "Expected optimistic data"
  }
}

// Test rollback restores original value
pub fn rollback_restores_original_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Store initial entity
  let initial_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_with_entity =
    squall_cache.store_query(cache, "GetSettings", json.object([]), initial_response, 0)

  // Apply optimistic update (simplified for test)
  let optimistic_entity =
    json.object([
      #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
      #("domainAuthority", json.string("xyz.statusphere")),
    ])

  let cache_with_optimistic =
    squall_cache.apply_optimistic_update(
      cache_with_entity,
      "mutation-1",
      "Settings:singleton",
      fn(_) { optimistic_entity },
    )

  // Rollback the optimistic update
  let cache_after_rollback =
    squall_cache.rollback_optimistic(cache_with_optimistic, "mutation-1")

  // Lookup should return the original value
  let #(_, result) =
    squall_cache.lookup(
      cache_after_rollback,
      "GetSettings",
      json.object([]),
      fn(response_str) {
        case json.parse(response_str, decode.dynamic) {
          Ok(dyn) -> {
            case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
              Ok(root) -> {
                case dict.get(root, "data") {
                  Ok(data_dyn) -> {
                    case decode.run(data_dyn, decode.dict(decode.string, decode.dynamic)) {
                      Ok(data_dict) -> {
                        case dict.get(data_dict, "settings") {
                          Ok(settings_dyn) -> {
                            case decode.run(settings_dyn, decode.dict(decode.string, decode.dynamic)) {
                              Ok(settings_dict) -> {
                                case dict.get(settings_dict, "domainAuthority") {
                                  Ok(da_dyn) -> {
                                    case decode.run(da_dyn, decode.string) {
                                      Ok(da) -> Ok(da)
                                      Error(_) -> Error("Failed to parse domainAuthority")
                                    }
                                  }
                                  Error(_) -> Error("No domainAuthority field")
                                }
                              }
                              Error(_) -> Error("Settings not a dict")
                            }
                          }
                          Error(_) -> Error("No settings field")
                        }
                      }
                      Error(_) -> Error("Data not a dict")
                    }
                  }
                  Error(_) -> Error("No data field")
                }
              }
              Error(_) -> Error("Root not a dict")
            }
          }
          Error(_) -> Error("Failed to parse JSON")
        }
      },
    )

  case result {
    squall_cache.Data(domain_authority) -> {
      domain_authority
      |> should.equal("fm.teal")
    }
    _ -> panic as "Expected original data after rollback"
  }
}

// Test commit removes optimistic layer
pub fn commit_removes_optimistic_layer_test() {
  let cache = squall_cache.new("https://api.example.com/graphql")

  // Store initial entity
  let initial_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "settings",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("fm.teal")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_with_entity =
    squall_cache.store_query(cache, "GetSettings", json.object([]), initial_response, 0)

  // Apply optimistic update
  let optimistic_entity =
    json.object([
      #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
      #("domainAuthority", json.string("xyz.statusphere")),
    ])

  let cache_with_optimistic =
    squall_cache.apply_optimistic_update(
      cache_with_entity,
      "mutation-1",
      "Settings:singleton",
      fn(_) { optimistic_entity },
    )

  // Store the real mutation response
  let mutation_response =
    json.object([
      #(
        "data",
        json.object([
          #(
            "updateDomainAuthority",
            json.object([
              #("__typename", json.string("Settings")),
              #("id", json.string("singleton")),
              #("domainAuthority", json.string("xyz.statusphere")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let cache_with_real_data =
    squall_cache.store_query(
      cache_with_optimistic,
      "UpdateDomainAuthority",
      json.object([]),
      mutation_response,
      1,
    )

  // Commit the optimistic update
  let cache_after_commit =
    squall_cache.commit_optimistic(cache_with_real_data, "mutation-1", "{}")

  // Verify the optimistic_entities dict is empty
  dict.size(cache_after_commit.optimistic_entities)
  |> should.equal(0)

  // Verify the optimistic_mutations dict is empty
  dict.size(cache_after_commit.optimistic_mutations)
  |> should.equal(0)
}

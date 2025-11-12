import { Ok, Error as GleamError } from "./gleam.mjs";
import { NetworkError } from "../gleam_fetch/gleam/fetch.mjs";
import { to_fetch_request, from_fetch_response } from "../gleam_fetch/gleam_fetch_ffi.mjs";

/**
 * Send an HTTP request with credentials included
 * This adds `credentials: "include"` to the fetch options so cookies are sent
 */
export async function sendWithCredentials(request) {
  try {
    // Convert Gleam request to browser Request object using gleam_fetch helper
    const fetchRequest = to_fetch_request(request);

    // Clone the request with credentials: "include"
    // We need to pass the fetchRequest to the Request constructor to properly clone it
    const requestWithCredentials = new Request(fetchRequest, {
      credentials: "include",
    });

    // Send the request
    const response = await fetch(requestWithCredentials);

    // Convert browser Response to Gleam Response using gleam_fetch helper
    const gleamResponse = from_fetch_response(response);
    return new Ok(gleamResponse);
  } catch (error) {
    return new GleamError(new NetworkError(error.toString()));
  }
}

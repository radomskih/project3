import gleam/otp/actor
import types

// receives user messages
// translates to http
// sends to server
// receives from server
// translates to user messages
// sends to user

// keeps track of subject for each actor for sending replies

pub fn account_message_handler(state: Int, message: types.EngineMessage) {
  todo
}

fn http_handler(req: wisp.Request) -> wisp.Response {
  let path = parse_path(req.path)
  let method = req.method
  let query = req.query

  case method, path {
    http.Post, ["users", "join"] -> {
      todo
      // join reddit message
    }

    _, _ -> {
      todo
    }
  }
}

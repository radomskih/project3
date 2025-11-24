import gleam/dynamic/decode
import gleam/erlang/process.{type Subject, receive}
import gleam/http
import gleam/io
import gleam/json
import gleam/otp/actor
import gleam/string
import mist
import types
import wisp
import wisp/wisp_mist

fn parse_path(in: String) -> List(String) {
  string.split(in, "/")
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
    http.Post, ["users", user_id, "online"] -> {
      todo
      // user says they are online
    }
    http.Get, ["users", user_id] -> {
      todo
      // get a user for messaging
    }
    http.Post, ["subreddits"] -> {
      todo
      // create subreddit
    }
    http.Get, ["subreddits"] -> {
      todo
      // get list of subreddits
    }
    http.Post, ["subreddits", sub_id, "join"] -> {
      todo
      // join subreddit
    }
    http.Post, ["subreddits", sub_id, "leave"] -> {
      todo
      // leave subreddit
    }
    http.Post, ["subreddits", sub_id, "posts"] -> {
      todo
      // make a post in a subreddit
    }
    http.Post, ["subreddits", sub_id, "posts", post_id, "upvote"] -> {
      todo
      //upvote a post
    }
    http.Post, ["subreddits", sub_id, "posts", post_id, "downvote"] -> {
      todo
      //downvote a post
    }
    http.Post, ["subreddits", sub_id, "posts", post_id, "comments"] -> {
      todo
      //comment on a post
    }
    http.Post,
      ["subreddits", sub_id, "posts", post_id, "comments", comment_id, "reply"]
    -> {
      todo
      // reply to a comment
    }
    http.Post,
      ["subreddits", sub_id, "posts", post_id, "comments", comment_id, "upvote"]
    -> {
      todo
      // upvote a comment
    }
    http.Post,
      [
        "subreddits",
        sub_id,
        "posts",
        post_id,
        "comments",
        comment_id,
        "downvote",
      ]
    -> {
      todo
      // downvote a comment
    }
    _, _ -> {
      todo
    }
  }
}

fn engine_handler() {
  todo
  // receives messages from engine
}

type ServerState {
  ServerState
}

pub fn main() {
  let secret_key_base = wisp.random_string(64)
  let assert Ok(_) =
    http_handler
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start
  let state = ServerState
  let assert Ok(_server) =
    actor.new(state)
    |> actor.on_message(engine_handler())
    |> actor.start
}

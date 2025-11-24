import argv
import gleam/erlang/process.{type Subject, receive}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/time/duration
import gleam/time/timestamp
import prng/random
import prng/seed
import types
import user.{account_message_handler}

import engine/engine.{engine_message_handler}
import utils.{create_actors, create_default_subs}

pub fn main() -> Nil {
  //number of actors
  let assert Ok(args) = list.rest(argv.load().arguments)
  let assert Ok(num_string) = list.first(args)
  let assert Ok(num_actors) = int.parse(num_string)

  //max frequency of users sending in seconds
  let assert Ok(args) = list.rest(args)
  let assert Ok(num_string) = list.first(args)
  let assert Ok(max_frequency) = int.parse(num_string)
  let max_frequency = max_frequency * 1000

  //how long the simulation should run in seconds
  let assert Ok(args) = list.rest(args)
  let assert Ok(num_string) = list.first(args)
  let assert Ok(duration) = int.parse(num_string)

  let reply_subj = process.new_subject()

  //create 10 existing subreddits so users have places to post and such
  let engine_state =
    types.Engine(
      create_default_subs(2),
      [],
      reply_subj,
      timestamp.system_time(),
      duration,
      timestamp.system_time(),
      0,
      0,
      0,
    )
  let assert Ok(engine) =
    actor.new(engine_state)
    |> actor.on_message(engine_message_handler)
    |> actor.start

  let step_size = max_frequency / num_actors
  create_actors(num_actors, 0, step_size, step_size, engine.data)

  //listen for finished message
  case receive(reply_subj, { duration * 1000 } + 1000) {
    Ok(x) -> {
      io.println(x)
    }
    Error(_) -> {
      io.println("Timeout")
    }
  }
  Nil
}

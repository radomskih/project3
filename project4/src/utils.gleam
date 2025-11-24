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

//just to fill up subreddit to support more frequent user interactions (post, comment, vote)
pub fn create_default_subs(num: Int) -> List(types.SubReddit) {
  case num {
    0 -> {
      []
    }
    1 -> {
      [types.SubReddit(num, { "Default " <> int.to_string(num) }, [], [])]
    }
    _ -> {
      let existing_list = create_default_subs(num - 1)
      let sub = [
        types.SubReddit(num, { "Default " <> int.to_string(num) }, [], []),
      ]
      list.append(existing_list, sub)
    }
  }
}

pub fn create_actors(
  num: Int,
  index: Int,
  curr_freq: Int,
  step: Int,
  engine: Subject(types.EngineMessage),
) -> Nil {
  case index < num {
    True -> {
      //let seed = seed.new(index)
      let assert Ok(actor) =
        actor.new(types.Account(
          int.to_string(index + 1),
          None,
          curr_freq,
          [],
          [],
          0,
          [],
          engine,
          random.float(0.0, 1.0),
          timestamp.system_time(),
        ))
        |> actor.on_message(account_message_handler)
        |> actor.start
      //update actor with own subject for further operations
      actor.send(actor.data, types.Start(actor.data))
      //make user known to reddit engine
      actor.send(engine, types.Join(actor.data))
      //all users first action is to join a subreddit
      actor.send(actor.data, types.NextAction(0.035, seed.new(index)))
      //continue creating actors
      create_actors(num, { index + 1 }, { curr_freq + step }, step, engine)
    }
    False -> {
      Nil
    }
  }
}

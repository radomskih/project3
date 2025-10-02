import gleam/bit_array
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

pub fn main() -> Nil {
  let _num_nodes = 10
  let num_resources = 100
  let _keys = create_keys(num_resources)
  let _nodes = create_nodes(num_nodes)
  Nil
}

pub type Message {
  Add(Int)
  Get(Subject(Int))
}

pub fn handle_message(state: Int, message: Message) -> actor.Next(Int, Message) {
  case message {
    Add(i) -> {
      let state = state + i
      echo state
      actor.continue(state)
    }
    Get(reply) -> {
      actor.send(reply, state)
      actor.continue(state)
    }
  }
}

fn create_keys(index: Int) -> List(Int) {
  case index {
    1 -> {
      let digest =
        crypto.hash(crypto.Sha1, bit_array.from_string(int.to_string(index)))
      let hex = bit_array.base16_encode(digest)
      let assert Ok(num) = int.base_parse(hex, 16)
      [num]
    }
    _ -> {
      let new_index = index - 1
      let existing_list = create_keys(new_index)

      let digest =
        crypto.hash(crypto.Sha1, bit_array.from_string(int.to_string(index)))
      let hex = bit_array.base16_encode(digest)
      let assert Ok(num) = int.base_parse(hex, 16)

      let new_list = list.append(existing_list, [num])
      list.sort(new_list, int.compare)
    }
  }
}

fn create_nodes(index: Int) -> List(Int) {
  case index {
    1 -> {
      let digest =
        crypto.hash(crypto.Sha1, bit_array.from_string(int.to_string(index)))
      let hex = bit_array.base16_encode(digest)
      let assert Ok(num) = int.base_parse(hex, 16)
      [num]
    }
    _ -> {
      let new_index = index - 1
      let existing_list = create_keys(new_index)

      let digest =
        crypto.hash(crypto.Sha1, bit_array.from_string(int.to_string(index)))
      let hex = bit_array.base16_encode(digest)
      let assert Ok(num) = int.base_parse(hex, 16)

      let new_list = list.append(existing_list, [num])
      list.sort(new_list, int.compare)
    }
  }
}

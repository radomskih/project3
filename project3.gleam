import gleam/dict
import gleam/erlang/process.{type Subject, send_after}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair

pub fn main() -> Nil {
  let actor_state = State(None, 0, None, 0, dict.new(), [], 0)
  let assert Ok(node) =
    actor.new(actor_state)
    |> actor.on_message(worker_handle_message)
    |> actor.start

  io.println("starting node")
  actor.send(node.data, Start(node.data))
  process.sleep(5000)
  Nil
}

pub fn lookup(state: State) {
  let n = 100
  //TODO: change n to however many keys we use

  //pick random key to query
  let random = int.random(n)

  //TODO: convert chosen key to hashed key id
  let hash = random

  //get next hop towards key
  let target = get_next_hop(hash, state)
  let target_subject = pair.second(target)
  let assert Some(self) = state.self

  //send query to the next hop with return information and number of hops initialized to 0
  actor.send(target_subject, Query(self, state.self_id, hash, 0))
}

pub fn get_next_hop(key: Int, state: State) -> #(Int, Subject(Message)) {
  //TODO: update for wrap around
  case key > state.self_id && key <= state.succ_id {
    True -> {
      //key is between you and your successor, so you know your successor has it
      let assert Some(succ) = state.succ
      #(state.succ_id, succ)
    }
    False -> {
      //try to get as close as possible without overshooting
      let assert Some(self) = state.self
      closest_preceding_node(key, state.contacts, self)
    }
  }
}

pub fn update_contacts(
  self_id: Int,
  candidate: Subject(Message),
  candidate_id: Int,
  contacts: dict.Dict(Int, Subject(Message)),
) -> dict.Dict(Int, Subject(Message)) {
  //this function maintains the finger table
  //each time a new node is recognized, we decide if we should keep it as a contact
  case dict.has_key(contacts, candidate_id) {
    //if candidate is already in contacts, no change
    True -> contacts
    False -> {
      //find contacts with ids directly lower and higher than candidate id
      let lower_contact =
        closest_preceding_node(candidate_id, contacts, candidate)
      let higher_contact =
        closest_following_node(candidate_id, contacts, candidate)

      //figure out their positions in a finger table
      let lower_routing_position = case pair.first(lower_contact) == 0 {
        True -> {
          //there is no preceding node
          -1
        }
        False -> {
          get_routing_position(pair.first(lower_contact), self_id)
        }
      }

      let higher_routing_position = case pair.first(higher_contact) == 0 {
        True -> {
          //there is no following node
          -1
        }
        False -> {
          get_routing_position(pair.first(higher_contact), self_id)
        }
      }

      let candidate_routing_position =
        get_routing_position(candidate_id, self_id)

      //if there is no preceding node or no following node, their routing position is -1
      //candidate routing position will not match -1, so the results will not be effected
      //Note: rather than keeping a full table with a node potentially filling multiple entries, 
      //we calculate the last entry in the table that a node would fill

      case lower_routing_position == candidate_routing_position {
        True -> {
          //current contact and candidate would fill same spot in table
          //current contact is lower than candidate, so it is preferable
          //do not add candidate, return contacts as is
          contacts
        }
        False -> {
          case higher_routing_position == candidate_routing_position {
            True -> {
              //candidate shares spot in finger table with current contact
              //candidate is below current contact, so it is preferable
              //no need for current contact, delete it from contacts
              let deleted = dict.delete(contacts, pair.first(higher_contact))
              //add candidate to fill spot
              dict.insert(deleted, candidate_id, candidate)
            }
            False -> {
              //candidate does not fill same spot as lower contact or higher contact
              //we can keep all three
              dict.insert(contacts, candidate_id, candidate)
            }
          }
        }
      }
    }
  }
}

pub fn get_routing_position(key: Int, start: Int) -> Int {
  //finger table keeps first node that follows n by at least 2^(i-1) for each i
  //figure out highest value of i this node would be stored under

  //measuring distance from start key
  let diff = key - start
  let diff_float = int.to_float(diff)

  //get log_2 of difference
  let log_val = log2(diff_float)

  //round down and convert to int
  let floor_val = float.floor(log_val)
  let val_int = float.round(floor_val)
  val_int
}

pub fn log2(n: Float) -> Float {
  //float.logarithm uses base e, so use change of bases formula
  let assert Ok(log_e_n) = float.logarithm(n)
  let assert Ok(log_e_2) = float.logarithm(2.0)

  let log_2_n = log_e_n /. log_e_2
  log_2_n
}

pub fn closest_preceding_node(
  key: Int,
  contacts: dict.Dict(Int, Subject(Message)),
  self: Subject(Message),
) -> #(Int, Subject(Message)) {
  //move through list, looking for highest node that is below key
  let target_id =
    list.fold(dict.keys(contacts), 0, fn(best, n) {
      case best {
        //if it is the first valid node, it is the best
        0 -> {
          //TODO:update with wrap-around 
          case n <= key {
            True -> n
            False -> 0
          }
        }
        _ -> {
          //it is the new best if it is above prev best and below key
          case n <= key && n > best {
            True -> n
            False -> best
          }
        }
      }
    })
  //access subject associated with selected key, return it
  case dict.get(contacts, target_id) {
    Ok(target) -> #(target_id, target)
    //if there was no valid contact, return 0 to communicate that
    Error(_) -> #(0, self)
  }
}

pub fn closest_following_node(
  key: Int,
  contacts: dict.Dict(Int, Subject(Message)),
  self: Subject(Message),
) -> #(Int, Subject(Message)) {
  //move through list, looking for lowest node that is above key
  let target_id =
    list.fold(dict.keys(contacts), 0, fn(best, n) {
      case best {
        //if it is the first valid node, it is the best
        0 -> {
          //TODO:update with wrap-around 
          case n >= key {
            True -> n
            False -> 0
          }
        }
        _ -> {
          //it is the new best if it is below prev best and above key
          case n >= key && n < best {
            True -> n
            False -> best
          }
        }
      }
    })
  //access subject associated with selected key, return it if possible
  case dict.get(contacts, target_id) {
    Ok(target) -> #(target_id, target)
    Error(_) -> #(0, self)
  }
}

pub type State {
  State(
    //keep own info for sending to others, checking key ownership
    self: Option(Subject(Message)),
    self_id: Int,
    //keep successor info for easy access during requests
    succ: Option(Subject(Message)),
    succ_id: Int,
    //keep list of other contacts for larger hops
    contacts: dict.Dict(Int, Subject(Message)),
    //keep list of keys you own
    contents: List(Int),
    starter_key: Int,
  )
}

pub type Message {
  //for first node in system
  Start(self: Subject(Message))
  //for other nodes joining system, given one contact to start
  Join(self: Subject(Message), contact: Subject(Message), contact_id: Int)
  //node requests data from other nodes
  Query(sender: Subject(Message), sender_id: Int, key: Int, hops: Int)
  //node responds to query 
  Response(hops: Int)
  //node looking for a successor contact
  SuccessorQuery(sender: Subject(Message), sender_id: Int)
  //node responds to successor query
  SuccessorResponse(sender: Subject(Message), sender_id: Int)
  //stabilization trigger gets sent to self periodically
  Stabilize
}

fn worker_handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    //main process tells node to start, it is first in system
    Start(self) -> {
      io.println("received start message!")
      //update state to store your own Subject
      let new_state =
        State(
          Some(self),
          state.self_id,
          state.succ,
          state.succ_id,
          state.contacts,
          state.contents,
          0,
        )
      //start the stabilization cycle
      send_after(self, 2000, Stabilize)
      actor.continue(new_state)
    }
    //main process tells node to join pre-existing system through one contact
    Join(self, contact, contact_id) -> {
      io.println("received start message")
      //use contact to find successor
      actor.send(contact, SuccessorQuery(self, state.self_id))
      //will get response as separate message
      //update contacts with your first contact
      let updated_contacts =
        update_contacts(state.self_id, contact, contact_id, state.contacts)
      let new_state =
        State(
          Some(self),
          state.self_id,
          state.succ,
          state.succ_id,
          updated_contacts,
          state.contents,
          0,
        )

      //start stabilizing cycle
      send_after(self, 2000, Stabilize)

      actor.continue(new_state)
    }
    Query(sender, sender_id, key, hops) -> {
      io.println("received a request")
      //if you have the key, send the response
      case list.contains(state.contents, key) {
        True -> {
          actor.send(sender, Response(hops + 1))
        }
        //else, pass the request on with incremented hops
        False -> {
          let target = get_next_hop(key, state)
          actor.send(
            pair.second(target),
            Query(sender, sender_id, key, hops + 1),
          )
        }
      }

      //update contacts with sender info
      let updated_contacts =
        update_contacts(state.self_id, sender, sender_id, state.contacts)
      let new_state =
        State(
          state.self,
          state.self_id,
          state.succ,
          state.succ_id,
          updated_contacts,
          state.contents,
          state.starter_key,
        )

      actor.continue(new_state)
    }

    Response(hops) -> {
      io.println("received a response")
      //TODO:
      //send monitor number of hops it took
      //maybe change to also get info of sender for adding to contacts
      actor.continue(state)
    }

    //a node is looking for their successor
    SuccessorQuery(sender, sender_id) -> {
      //TODO:
      //update your contacts with their info

      //if sender id is within your current range, you are their successor
      case sender_id >= state.starter_key && sender_id < state.self_id {
        True -> {
          //you are their successor
          let assert Some(self) = state.self
          actor.send(sender, SuccessorResponse(self, state.self_id))
          //TODO:
          //update your own contents/range
        }
        False -> {
          //you are not their successor, pass query along
          //next_hop will either be the right successor or the closest you can get without overshooting
          let next_hop = get_next_hop(sender_id, state)
          actor.send(pair.second(next_hop), SuccessorQuery(sender, sender_id))
        }
      }
      actor.continue(state)
    }

    SuccessorResponse(sender, sender_id) -> {
      //TODO:
      //update contacts with sender's info

      //update state with new successor info
      let new_state =
        State(
          state.self,
          state.self_id,
          Some(sender),
          sender_id,
          state.contacts,
          state.contents,
          state.starter_key,
        )
      actor.continue(new_state)
    }

    Stabilize -> {
      //TODO:
      //stabilize protocol
      let assert Some(self) = state.self
      send_after(self, 2000, Stabilize)
      actor.continue(state)
    }
  }
}

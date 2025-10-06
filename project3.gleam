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
  let actor_state = State(None, 0, None, 0, None, 0, dict.new())
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
  let key_dist = distance(state.self_id, key)
  let succ_dist = distance(state.self_id, state.succ_id)
  //if key is closer to you than your successor, it is within their range
  case key_dist <= succ_dist {
    True -> {
      //key is between you and your successor, so you know your successor has it
      let assert Some(succ) = state.succ
      #(state.succ_id, succ)
    }
    False -> {
      //try to get as close as possible without overshooting
      closest_preceding_node(key, state)
    }
  }
}

pub fn update_contacts(
  candidate: Subject(Message),
  candidate_id: Int,
  state: State,
) -> dict.Dict(Int, Subject(Message)) {
  //this function maintains the finger table
  //each time a new node is recognized, we decide if we should keep it as a contact
  case dict.has_key(state.contacts, candidate_id) {
    //if candidate is already in contacts, no change
    True -> state.contacts
    False -> {
      //find contacts with ids directly lower and higher than candidate id
      let lower_contact = closest_preceding_node(candidate_id, state)
      let higher_contact = closest_following_node(candidate_id, state)

      //figure out their positions in a finger table
      let lower_routing_position = case pair.first(lower_contact) == 0 {
        True -> {
          //there is no preceding node
          -1
        }
        False -> {
          get_routing_position(pair.first(lower_contact), state.self_id)
        }
      }

      let higher_routing_position = case pair.first(higher_contact) == 0 {
        True -> {
          //there is no following node
          -1
        }
        False -> {
          get_routing_position(pair.first(higher_contact), state.self_id)
        }
      }

      let candidate_routing_position =
        get_routing_position(candidate_id, state.self_id)

      //if there is no preceding node or no following node, their routing position is -1
      //candidate routing position will not match -1, so the results will not be effected
      //Note: rather than keeping a full table with a node potentially filling multiple entries, 
      //we calculate the last entry in the table that a node would fill

      case lower_routing_position == candidate_routing_position {
        True -> {
          //current contact and candidate would fill same spot in table
          //current contact is lower than candidate, so it is preferable
          //do not add candidate, return contacts as is
          state.contacts
        }
        False -> {
          case higher_routing_position == candidate_routing_position {
            True -> {
              //candidate shares spot in finger table with current contact
              //candidate is below current contact, so it is preferable
              //no need for current contact, delete it from contacts
              let deleted =
                dict.delete(state.contacts, pair.first(higher_contact))
              //add candidate to fill spot
              dict.insert(deleted, candidate_id, candidate)
            }
            False -> {
              //candidate does not fill same spot as lower contact or higher contact
              //we can keep all three
              dict.insert(state.contacts, candidate_id, candidate)
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
  let diff = distance(start, key)
  let diff_float = int.to_float(diff) +. 0.001

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
  state: State,
) -> #(Int, Subject(Message)) {
  //move through list, looking for highest node that is below key
  let target_id =
    list.fold(dict.keys(state.contacts), 0, fn(best, n) {
      case best {
        //if it is the first valid node, it is the best
        0 -> {
          //node must be closer than key
          let key_dist = distance(state.self_id, key)
          let n_dist = distance(state.self_id, n)
          case n_dist < key_dist {
            True -> n
            False -> 0
          }
        }
        _ -> {
          //it is the new best if it is further than prev best and closer than key
          let best_dist = distance(state.self_id, best)
          let n_dist = distance(state.self_id, n)
          let key_dist = distance(state.self_id, key)
          case n_dist < key_dist && n_dist > best_dist {
            True -> n
            False -> best
          }
        }
      }
    })
  //access subject associated with selected key, return it
  case dict.get(state.contacts, target_id) {
    Ok(target) -> #(target_id, target)
    //if there was no valid contact, return 0 to communicate that
    Error(_) -> {
      let assert Some(self) = state.self
      #(0, self)
    }
  }
}

pub fn closest_following_node(
  key: Int,
  state: State,
) -> #(Int, Subject(Message)) {
  //move through list, looking for lowest node that is above key
  let target_id =
    list.fold(dict.keys(state.contacts), 0, fn(best, n) {
      case best {
        //if it is the first valid node, it is the best
        0 -> {
          let key_dist = distance(state.self_id, key)
          let n_dist = distance(state.self_id, n)
          //n is valid if it is further than the key
          case n_dist > key_dist {
            True -> n
            False -> 0
          }
        }
        _ -> {
          //it is the new best if it is closer than prev best and further than key
          let key_dist = distance(state.self_id, key)
          let n_dist = distance(state.self_id, n)
          let best_dist = distance(state.self_id, best)
          case n_dist >= key_dist && n_dist < best_dist {
            True -> n
            False -> best
          }
        }
      }
    })
  //access subject associated with selected key, return it if possible
  case dict.get(state.contacts, target_id) {
    Ok(target) -> #(target_id, target)
    Error(_) -> {
      let assert Some(self) = state.self
      #(0, self)
    }
  }
}

pub fn distance(start: Int, end: Int) -> Int {
  //TODO: CHANGE TO FINAL VALUE
  let circle_size = 10_000
  //this value can either be positive or negative
  let diff = end - start
  //if diff is negative, we must wrap around the circle
  case diff >= 0 {
    True -> diff
    False -> circle_size + diff
  }
}

pub fn update_state(
  sender: Subject(Message),
  sender_id: Int,
  state: State,
) -> State {
  //add sender to contacts
  let updated_contacts = update_contacts(sender, sender_id, state)
  //check if sender should replace pred or succ
  let pred_dist = distance(state.self_id, state.pred_id)
  let succ_dist = distance(state.self_id, state.succ_id)
  let sender_dist = distance(state.self_id, sender_id)
  case sender_dist < succ_dist {
    True -> {
      //sender is closer than successor, it should be the new successor
      State(
        state.self,
        state.self_id,
        Some(sender),
        sender_id,
        state.pred,
        state.pred_id,
        updated_contacts,
      )
    }
    False -> {
      case sender_dist > pred_dist {
        True -> {
          //sender is closer behind that predecessor, it should be the new predecessor
          State(
            state.self,
            state.self_id,
            state.succ,
            state.succ_id,
            Some(sender),
            sender_id,
            updated_contacts,
          )
        }
        False -> {
          //sender does not replace either neighbor
          State(
            state.self,
            state.self_id,
            state.succ,
            state.succ_id,
            state.pred,
            state.pred_id,
            updated_contacts,
          )
        }
      }
    }
  }
  //add sender to contacts
  //create new state
}

pub type State {
  State(
    //keep own info for sending to others, checking key ownership
    self: Option(Subject(Message)),
    self_id: Int,
    //keep successor info for easy access during requests
    succ: Option(Subject(Message)),
    succ_id: Int,
    pred: Option(Subject(Message)),
    pred_id: Int,
    //keep list of other contacts for larger hops
    contacts: dict.Dict(Int, Subject(Message)),
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
  Response(sender: Subject(Message), sender_id: Int, hops: Int)
  //node looking for a successor contact
  SuccessorQuery(sender: Subject(Message), sender_id: Int)
  //node responds to successor query
  SuccessorResponse(
    succ: Subject(Message),
    succ_id: Int,
    pred: Subject(Message),
    pred_id: Int,
  )
  //stabilization trigger gets sent to self periodically
  StabilizeTrigger
  //send stabilization query to successor
  StabilizeQuery(sender: Subject(Message), sender_id: Int)
  //node responds to stabilize with its own predecessor
  StabilizeResponse(pred: Subject(Message), pred_id: Int)
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
          Some(self),
          state.self_id,
          Some(self),
          state.self_id,
          state.contacts,
        )

      //start stabilization cycle
      send_after(self, 2000, StabilizeTrigger)
      actor.continue(new_state)
    }

    //main process tells node to join pre-existing system through one contact
    Join(self, contact, contact_id) -> {
      io.println("received start message")
      //use contact to find successor
      actor.send(contact, SuccessorQuery(self, state.self_id))
      //will get response as separate message
      //update contacts with your first contact
      let updated_contacts = update_contacts(contact, contact_id, state)

      let new_state =
        State(
          Some(self),
          state.self_id,
          Some(contact),
          contact_id,
          Some(contact),
          contact_id,
          updated_contacts,
        )

      //start stabilizing cycle, sending to your predecessor, the new contact
      send_after(contact, 2000, StabilizeTrigger)

      actor.continue(new_state)
    }
    Query(sender, sender_id, key, hops) -> {
      io.println("received a request")
      //if you have the key, send the response
      //key must be further  around circle than predecessor to be yours
      let pred_dist = distance(state.self_id, state.pred_id)
      let key_dist = distance(state.self_id, key)
      case key_dist > pred_dist {
        True -> {
          let assert Some(self) = state.self
          actor.send(sender, Response(self, state.self_id, hops + 1))
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
      let new_state = update_state(sender, sender_id, state)

      actor.continue(new_state)
    }

    Response(sender, sender_id, _hops) -> {
      io.println("received a response")
      //update contacts with sender's info
      let new_state = update_state(sender, sender_id, state)

      //TODO:
      //send monitor number of hops it took
      //maybe change to also get info of sender for adding to contacts
      actor.continue(new_state)
    }

    //a node is looking for their successor
    SuccessorQuery(sender, sender_id) -> {
      let updated_contacts = update_contacts(sender, sender_id, state)

      //if sender id is within your current range, you are their successor
      //the distance to sender must be larger than distance to predecessor
      let sender_dist = distance(state.self_id, sender_id)
      let pred_dist = distance(state.self_id, state.pred_id)
      //if you had yourself previously stored as your own predecessor, automatically change it
      let new_state = case sender_dist > pred_dist || pred_dist == 0 {
        True -> {
          //you are their successor, your prev predecessor is now theirs
          let assert Some(self) = state.self
          let assert Some(pred) = state.pred
          actor.send(
            sender,
            SuccessorResponse(self, state.self_id, pred, state.pred_id),
          )
          //they are now your predecessor
          State(
            state.self,
            state.self_id,
            state.succ,
            state.succ_id,
            Some(sender),
            sender_id,
            updated_contacts,
          )
        }
        False -> {
          //you are not their successor, pass query along
          //next_hop will either be the right successor or the closest you can get without overshooting
          let next_hop = get_next_hop(sender_id, state)
          actor.send(pair.second(next_hop), SuccessorQuery(sender, sender_id))
          State(
            state.self,
            state.self_id,
            state.succ,
            state.succ_id,
            state.pred,
            state.pred_id,
            updated_contacts,
          )
        }
      }
      actor.continue(new_state)
    }

    SuccessorResponse(succ, succ_id, pred, pred_id) -> {
      //get contacts with predecessor added
      let contacts_with_succ = update_contacts(succ, succ_id, state)
      //update state to pass through update_contacts again
      let state_with_succ =
        State(
          state.self,
          state.self_id,
          state.succ,
          state.succ_id,
          state.pred,
          state.pred_id,
          contacts_with_succ,
        )
      let final_contacts = update_contacts(pred, pred_id, state_with_succ)
      //get final state with pred, succ, and final contacts
      let final_state =
        State(
          state.self,
          state.self_id,
          Some(succ),
          succ_id,
          Some(pred),
          pred_id,
          final_contacts,
        )

      actor.continue(final_state)
    }

    StabilizeTrigger -> {
      let assert Some(succ) = state.succ
      let assert Some(self) = state.self
      //send stabilize query to your successor
      actor.send(succ, StabilizeQuery(self, state.self_id))

      //resend trigger to yourself after some time
      send_after(self, 2000, StabilizeTrigger)
      actor.continue(state)
    }
    StabilizeQuery(sender, sender_id) -> {
      //someone has sent you a message because you are their successor
      let new_state = update_state(sender, sender_id, state)
      //send response telling them who your predecessor is
      let assert Some(pred) = new_state.pred
      actor.send(sender, StabilizeResponse(pred, new_state.pred_id))
      actor.continue(new_state)
    }

    StabilizeResponse(result, result_id) -> {
      //your successor has responded with their predecessor
      //if you are still their predecessor, nothing has changed
      //otherwise, there is a new node between you two that will be your new successor
      case result_id == state.self_id {
        True -> {
          //no change
          actor.continue(state)
        }
        False -> {
          //new successor
          let new_state = update_state(result, result_id, state)
          actor.continue(new_state)
        }
      }
    }
  }
}

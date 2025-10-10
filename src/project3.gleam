import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/erlang/process.{type Subject, receive, send_after}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/string

pub fn main() -> Nil {
  //TODO: read num_nodes and num_queries from command line
  let num_nodes = 50
  let num_queries = 10
  //set up place to receive results
  let reply_subject = process.new_subject()

  //set up monitor and pass data to nodes
  let _total_queries = num_nodes * num_queries
  //TODO: change 100 to total_queries 
  let monitor_state = MonitorState(0, 0, reply_subject, 500)
  let assert Ok(monitor) =
    actor.new(monitor_state)
    |> actor.on_message(monitor_handle_message)
    |> actor.start

  //generate n nodes to be joined to the chord with monitor data
  let nodes_dict = create_nodes(num_nodes, monitor.data)
  //for cheaper iteration
  let nodes_list = dict.to_list(nodes_dict)
  //build chord
  build_chord(num_nodes, nodes_list, num_queries)

  case receive(reply_subject, 4500) {
    Ok(results) -> {
      io.println("finished! results: " <> float.to_string(results))
    }
    Error(_) -> {
      io.println("timeout")
    }
  }
  Nil
}

fn key_hash(key: String) -> Int {
  let digest = crypto.hash(crypto.Sha1, bit_array.from_string(key))
  let hex = bit_array.base16_encode(digest)
  let assert Ok(num) = int.base_parse(hex, 16)
  num
}

fn create_nodes(
  index: Int,
  reply_subject: Subject(MonitorMessage),
) -> dict.Dict(Int, Subject(Message)) {
  case index {
    1 -> {
      let actor_state =
        State(None, 0, None, 0, None, 0, dict.new(), reply_subject)
      let assert Ok(node) =
        actor.new(actor_state)
        |> actor.on_message(worker_handle_message)
        |> actor.start
      let hash = key_hash(string.inspect(node.pid))
      let nodes = dict.new()
      let nodes = dict.insert(nodes, hash, node.data)
      nodes
    }
    _ -> {
      let new_index = index - 1
      let nodes = create_nodes(new_index, reply_subject)

      let actor_state =
        State(None, 0, None, 0, None, 0, dict.new(), reply_subject)
      let assert Ok(node) =
        actor.new(actor_state)
        |> actor.on_message(worker_handle_message)
        |> actor.start
      let hash = key_hash(string.inspect(node.pid))
      let nodes = dict.insert(nodes, hash, node.data)
      nodes
    }
  }
}

fn build_chord(
  index: Int,
  nodes: List(#(Int, Subject(Message))),
  num_queries: Int,
) -> #(Subject(Message), Int) {
  case index {
    1 -> {
      //Get node's addr to join
      let assert Ok(node) = list.first(nodes)
      let subject = pair.second(node)
      let id = pair.first(node)

      io.println("initializing node 1")
      actor.send(subject, Start(subject, num_queries))
      //pass back this node as the reference for the next node
      #(subject, id)
    }
    _ -> {
      //remove self from list and pass the list along
      let assert Ok(node) = list.first(nodes)
      let subject = pair.second(node)
      let id = pair.first(node)
      let assert Ok(nodes) = list.rest(nodes)
      //get reference node from the node before you
      let ref_node = build_chord(index - 1, nodes, num_queries)
      let ref_subject = pair.first(ref_node)
      let ref_id = key_hash(string.inspect(ref_subject))
      //io.println("sending join message " <> int.to_string(index))
      actor.send(subject, Join(subject, ref_subject, ref_id, num_queries))
      #(subject, id)
    }
  }
}

pub fn lookup(num_queries: Int, state: State) {
  case num_queries {
    0 -> {
      //after n queries, finish
      Nil
    }
    _ -> {
      let assert Ok(n) = int.power(2, 160.0)

      //pick random key to query
      let random = int.random(float.round(n))

      //get next hop towards key
      let target = get_next_hop(random, state)
      let target_subject = pair.second(target)
      let assert Some(self) = state.self

      //send query to the next hop with return information and number of hops initialized to 0
      actor.send(target_subject, Query(self, state.self_id, random, 0))

      //resend query trigger and decrement
      let assert Some(self) = state.self
      send_after(self, 100, QueryTrigger(num_queries - 1))
      Nil
    }
  }
}

pub fn get_next_hop(key: Int, state: State) -> #(Int, Subject(Message)) {
  let key_dist = distance(state.self_id, key)
  let succ_dist = distance(state.self_id, state.succ_id)
  let pred_dist = distance(state.self_id, state.pred_id)
  //if key is closer to you than your successor, it is within their range
  case key_dist {
    i if i <= succ_dist -> {
      //key is between you and your successor, so you know your successor has it
      let assert Some(succ) = state.succ
      #(state.succ_id, succ)
    }
    i if i > pred_dist -> {
      //key is between you and your predecessor, so it is yours
      let assert Some(self) = state.self
      #(state.self_id, self)
    }
    _ -> {
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
  case
    dict.has_key(state.contacts, candidate_id)
    || candidate_id == state.self_id
    || candidate_id == 0
  {
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
          //returns -1 if dist is 0
          get_routing_position(pair.first(lower_contact), state.self_id)
        }
      }

      let higher_routing_position = case pair.first(higher_contact) == 0 {
        True -> {
          //there is no following node
          -1
        }
        False -> {
          //also returns -1 if distance is zero, node's neighbor is itself
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
          //pre-existing contact and candidate would fill same spot in table
          //this pre-existing contact is lower than candidate, so it is preferable
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
  case diff > 0 {
    True -> {
      //get log of dist to key
      let diff_float = int.to_float(diff)
      case log2(diff_float) {
        Some(log_val) -> {
          //round down and convert to int
          let floor_val = float.floor(log_val)
          let val_int = float.round(floor_val)
          val_int
        }
        None -> -1
      }
    }
    False -> -1
  }
}

pub fn log2(n: Float) -> Option(Float) {
  case float.logarithm(n) {
    Ok(log_e_n) -> {
      let assert Ok(log_e_2) = float.logarithm(2.0)
      Some(log_e_n /. log_e_2)
    }
    Error(_) -> None
  }
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
      let assert Some(succ) = state.succ
      #(0, succ)
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
  let assert Ok(circle_size) = int.power(2, 160.0)
  //this value can either be positive or negative
  let diff = end - start
  //if diff is negative, we must wrap around the circle
  case diff >= 0 {
    True -> diff
    False -> float.round(circle_size) + diff
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
  case { sender_dist != 0 && sender_dist < succ_dist } || succ_dist == 0 {
    True -> {
      //sender is closer than successor, it should be the new successor
      case pred_dist == 0 {
        True -> {
          State(
            state.self,
            state.self_id,
            Some(sender),
            sender_id,
            Some(sender),
            sender_id,
            updated_contacts,
            state.monitor,
          )
        }
        False -> {
          State(
            state.self,
            state.self_id,
            Some(sender),
            sender_id,
            state.pred,
            state.pred_id,
            updated_contacts,
            state.monitor,
          )
        }
      }
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
            state.monitor,
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
            state.monitor,
          )
        }
      }
    }
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
    pred: Option(Subject(Message)),
    pred_id: Int,
    //keep list of other contacts for larger hops
    contacts: dict.Dict(Int, Subject(Message)),
    //monitor data to send results
    monitor: Subject(MonitorMessage),
  )
}

pub type Message {
  //for first node in system
  Start(self: Subject(Message), num_queries: Int)
  //for other nodes joining system, given one contact to start
  Join(
    self: Subject(Message),
    contact: Subject(Message),
    contact_id: Int,
    num_queries: Int,
  )
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
  //triggers lookups after contacts have had time to form
  QueryTrigger(num_queries: Int)
  FixFingerTrigger(last_finger: Int)
  FixFingerQuery(sender: Subject(Message), sender_id: Int, key: Int)
  FixFingerResponse(contact: Subject(Message), contact_id: Int)
}

fn worker_handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    //main process tells node to start, it is first in system
    Start(self, num_queries) -> {
      //io.println("received start message!")
      //update state to store your own Subject and id
      //calculate id
      let id = key_hash(string.inspect(self))
      let new_state =
        State(
          Some(self),
          id,
          Some(self),
          id,
          Some(self),
          id,
          state.contacts,
          state.monitor,
        )

      //start stabilization cycle and fix finger cycle
      send_after(self, 10, StabilizeTrigger)
      send_after(self, 10, FixFingerTrigger(0))

      //set query trigger
      send_after(self, 1500, QueryTrigger(num_queries))

      actor.continue(new_state)
    }
    //main process tells node to join pre-existing system through one contact
    Join(self, contact, contact_id, num_queries) -> {
      //io.println("received join message")
      //calculate your id
      let id = key_hash(string.inspect(self))

      //use contact to find successor
      actor.send(contact, SuccessorQuery(self, id))
      //will get response as separate message

      //update contacts with your first contact
      let state_with_self =
        State(
          Some(self),
          id,
          Some(contact),
          contact_id,
          Some(contact),
          contact_id,
          state.contacts,
          state.monitor,
        )

      let updated_contacts =
        update_contacts(contact, contact_id, state_with_self)

      //update state
      let new_state =
        State(
          Some(self),
          id,
          Some(contact),
          contact_id,
          Some(contact),
          contact_id,
          updated_contacts,
          state.monitor,
        )

      //start stabilizing cycle and finger fix trigger
      send_after(self, 10, StabilizeTrigger)
      send_after(self, 10, FixFingerTrigger(0))

      //set query trigger
      send_after(self, 1500, QueryTrigger(num_queries))

      actor.continue(new_state)
    }
    Query(sender, sender_id, key, hops) -> {
      case hops > 99 && hops % 100 == 0 {
        True -> {
          io.println("message running wild! (key " <> int.to_string(key) <> ")")
        }
        False -> Nil
      }
      //io.println("received a request")
      //if you have the key, send the response
      //key must be further  around circle than predecessor to be yours
      let pred_dist = distance(state.self_id, state.pred_id)
      let key_dist = distance(state.self_id, key)
      //io.println(
      // "my range: "
      //<> int.to_string(state.pred_id)
      //<> " to "
      // <> int.to_string(state.self_id)
      // <> ", key: "
      // <> int.to_string(key)
      // <> bool.to_string(key_dist > pred_dist)
      // <> " sending to "
      // <> int.to_string(pair.first(get_next_hop(key, state))),
      //)
      case key_dist > pred_dist || key_dist == 0 {
        True -> {
          //io.println("i have it!")
          let assert Some(self) = state.self
          actor.send(sender, Response(self, state.self_id, hops + 1))
        }
        //else, pass the request on with incremented hops
        False -> {
          //io.println("passing it on...")
          let target = get_next_hop(key, state)

          //otherwise, pass it on
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

    Response(sender, sender_id, hops) -> {
      //io.println("received a response with " <> int.to_string(hops) <> " hops")
      //update contacts with sender's info
      let new_state = update_state(sender, sender_id, state)

      //send monitor the query results
      actor.send(state.monitor, QueryResults(hops))
      actor.continue(new_state)
    }

    //a node is looking for their successor
    SuccessorQuery(sender, sender_id) -> {
      let updated_contacts = update_contacts(sender, sender_id, state)

      //if sender id is within your current range, you are their successor
      //the distance to sender must be larger than distance to predecessor
      let sender_dist = distance(state.self_id, sender_id)
      let pred_dist = distance(state.self_id, state.pred_id)
      //if you had yourself previously stored as your own predecessor (you were the first node), automatically change it
      let new_state = case sender_dist > pred_dist || pred_dist == 0 {
        True -> {
          //you are their successor, your prev predecessor is now their predecessor
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
            state.monitor,
          )
        }
        False -> {
          //you are not their successor, pass query along
          //next_hop will either be the right successor or the closest you can get without overshooting
          let next_hop = get_next_hop(sender_id, state)

          case pair.first(next_hop) == 0 && sender_dist != 0 {
            True -> {
              //your successor will be their successor, you will be their predecessor
              let assert Some(succ) = state.succ
              let assert Some(self) = state.self
              actor.send(
                sender,
                SuccessorResponse(succ, state.succ_id, self, state.self_id),
              )

              //they will be your successor, update your state
              State(
                state.self,
                state.self_id,
                Some(sender),
                sender_id,
                state.pred,
                state.pred_id,
                updated_contacts,
                state.monitor,
              )
            }
            False -> {
              actor.send(
                pair.second(next_hop),
                SuccessorQuery(sender, sender_id),
              )
              State(
                state.self,
                state.self_id,
                state.succ,
                state.succ_id,
                state.pred,
                state.pred_id,
                updated_contacts,
                state.monitor,
              )
            }
          }
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
          state.monitor,
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
          state.monitor,
        )

      actor.continue(final_state)
    }

    StabilizeTrigger -> {
      let assert Some(succ) = state.succ
      let assert Some(self) = state.self
      //send stabilize query to your successor
      actor.send(succ, StabilizeQuery(self, state.self_id))

      //resend trigger to yourself after some time
      send_after(self, 100, StabilizeTrigger)
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
    QueryTrigger(num_queries) -> {
      //send out a query
      lookup(num_queries, state)
      actor.continue(state)
    }
    FixFingerTrigger(last_finger) -> {
      //determine the size of the finger table, based on the id space
      let assert Ok(size) = int.power(2, 160.0)
      let assert Some(range) = log2(size)
      let num_fingers = float.round(float.floor(range))

      //pick next finger, with randomized step size from previous finger
      let next_finger = { last_finger + int.random(3) + 1 } % num_fingers
      //calculate what key this finger corresponds to
      let assert Ok(offset) = int.power(2, int.to_float(next_finger) -. 1.0)
      let search_key =
        { state.self_id + float.round(offset) } % float.round(size)

      //get next hop towards this key
      let target = get_next_hop(search_key, state)

      //send query off to target
      let assert Some(self) = state.self
      actor.send(
        pair.second(target),
        FixFingerQuery(self, state.self_id, search_key),
      )

      //io.println(int.to_string(dict.size(state.contacts)))
      //retrigger next fix-finger
      send_after(self, 100, FixFingerTrigger(next_finger))
      actor.continue(state)
    }
    FixFingerQuery(sender, sender_id, key) -> {
      //a node is looking for another node that is as close to this key as possible without being closer
      //handle similar to regular query
      let pred_dist = distance(state.self_id, state.pred_id)
      let key_dist = distance(state.self_id, key)
      case key_dist > pred_dist {
        True -> {
          //key is in your range, you fit their entry perfectly
          let assert Some(self) = state.self
          actor.send(sender, FixFingerResponse(self, state.self_id))
        }
        //else, pass the request on 
        False -> {
          let target = get_next_hop(key, state)
          actor.send(
            pair.second(target),
            FixFingerQuery(sender, sender_id, key),
          )
        }
      }
      //update contacts with sender info
      let new_state = update_state(sender, sender_id, state)

      actor.continue(new_state)
    }
    FixFingerResponse(contact, contact_id) -> {
      //received response from your finger query
      //update your state and move on
      let new_state = update_state(contact, contact_id, state)
      actor.continue(new_state)
    }
  }
}

pub type MonitorState {
  MonitorState(
    num_queries: Int,
    num_hops: Int,
    reply_subject: Subject(Float),
    expected_num: Int,
  )
}

pub type MonitorMessage {
  QueryResults(hops: Int)
}

fn monitor_handle_message(
  state: MonitorState,
  message: MonitorMessage,
) -> actor.Next(MonitorState, MonitorMessage) {
  case message {
    QueryResults(hops) -> {
      case state.num_queries + 1 == state.expected_num {
        True -> {
          //we have received all the results, now calculate average
          let average =
            { int.to_float(state.num_hops + hops) }
            /. { int.to_float(state.num_queries + 1) }
          //send results to main process
          actor.send(state.reply_subject, average)
          actor.stop()
        }
        False -> {
          case state.num_queries % 5 == 0 {
            True -> {
              let percent =
                int.to_float(state.num_queries)
                /. int.to_float(state.expected_num)

              io.println(float.to_string(percent *. 100.0) <> "% complete!")
            }
            False -> {
              Nil
            }
          }

          let new_state =
            MonitorState(
              state.num_queries + 1,
              state.num_hops + hops,
              state.reply_subject,
              state.expected_num,
            )
          actor.continue(new_state)
        }
      }
    }
  }
}

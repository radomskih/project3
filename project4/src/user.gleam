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

pub fn account_message_handler(
  state: types.Account,
  message: types.AccountMessage,
) -> actor.Next(types.Account, types.AccountMessage) {
  case message {
    //updates the state's subject since its generated after the fact
    types.Start(sbj) -> {
      //io.println("User " <> state.username <> " is up and running")
      actor.continue(types.Account(..state, subject: Some(sbj)))
    }
    types.NextAction(choice, seed) -> {
      //echo choice
      //process current choice that was sent to actor
      case choice {
        //create a new subreddit
        n if n <. 0.02 -> {
          let name = "Subreddit created by " <> state.username
          actor.send(state.reddit_engine, types.CreateSubReddit(name))
          actor.continue(state)
        }
        //Send request for the list of subreddits to join
        n if n >. 0.002 && n <. 0.14 -> {
          //Request the list of subreddits to join
          let assert Some(self) = state.subject
          //subreddit will send actor a list of available subreddits to join
          actor.send(state.reddit_engine, types.GetSubReddits(self))
          actor.continue(state)
        }
        //Leave a subreddit you're apart of
        //TODO: remove posts from feed (beyond project scope)
        n if n >. 0.14 && n <. 0.2 -> {
          //leave subreddit if you have more than two subs
          case list.length(state.subreddits) > 2 {
            True -> {
              //get a subreddits to leave
              let sub_id = get_random_id(state.subreddits)
              let updated_subs =
                list.drop_while(state.subreddits, fn(sub) { sub == sub_id })
              //io.println("User " <> state.username <> " left a subreddit.")
              actor.continue(types.Account(..state, subreddits: updated_subs))
            }
            False -> {
              //wait for next user action
              actor.continue(state)
            }
          }
        }
        //Make a post in a subreddit
        n if n >. 0.2 && n <. 0.32 -> {
          //can't if you've left all your subreddits
          case !list.is_empty(state.subreddits) {
            True -> {
              //get random sub id
              let sub_id = get_random_id(state.subreddits)
              //need self to get Karma updates
              let assert Some(self) = state.subject
              let post =
                types.Post(
                  0,
                  sub_id,
                  {
                    "This is a cool topics idea "
                    <> state.username
                    <> " wants to talk about."
                  },
                  state.username,
                  self,
                  {
                    "Imagine this has a lot of conent about something interesting. A lot of great points were made, then they lost you. This is a post by "
                    <> state.username
                  },
                  [],
                  0,
                  0,
                )
              actor.send(state.reddit_engine, types.PostInSub(sub_id, post))
              //io.println("User " <> state.username <> " made a post.")
              actor.continue(state)
            }
            False -> {
              //no subreddits to post in
              actor.continue(state)
            }
          }
        }
        //make comment on post or reply to comment
        n if n >. 0.32 && n <. 0.48 -> {
          case list.is_empty(state.feed) {
            True -> {
              //no posts in feed to 
              actor.continue(state)
            }
            False -> {
              //get post to possibly comment on
              let post = get_random_post(state.feed)
              //create the comment to post
              let assert Some(self) = state.subject
              let comment =
                types.Comment(
                  0,
                  { "This is a comment by " <> state.username },
                  state.username,
                  self,
                  0,
                  0,
                  0,
                )
              //check if the post has any comments to reply to
              //flip a coin to decide if to reply to the post or reply to a comment
              case !list.is_empty(post.comments) && flip_a_coin() {
                //if the post has comments and the flip was true
                //reply to an existing comment under the post
                True -> {
                  let existing_comment = get_random_comment(post.comments)
                  actor.send(
                    state.reddit_engine,
                    types.ReplyToComment(
                      post.sub_id,
                      post.id,
                      existing_comment.id,
                      comment,
                    ),
                  )
                  //io.println(
                  //  "User " <> state.username <> " replied to a comment.",
                  //)
                }
                //if the flip was false then just reply to the post
                False -> {
                  actor.send(
                    state.reddit_engine,
                    types.CommentOnPost(post.sub_id, post.id, comment),
                  )
                  //io.println(
                  //"User " <> state.username <> " commented on a post.",
                  //)
                }
              }
              actor.continue(state)
            }
          }
        }
        //Upvote a post or a comment
        n if n >. 0.48 && n <. 0.68 -> {
          //make sure there's posts to upvote
          case !list.is_empty(state.feed) {
            True -> {
              let post = get_random_post(state.feed)
              //check if the post has any comments to reply to
              //flip a coin to decide if to reply to the post or reply to a comment
              case flip_a_coin() && !list.is_empty(post.comments) {
                //if the post has comments and the flip was true upvote a comment
                True -> {
                  let comment = get_random_comment(post.comments)
                  process.send(
                    state.reddit_engine,
                    types.UpVoteComment(post.sub_id, post.id, comment.id),
                  )
                  //io.println(
                  //"User " <> state.username <> " up voted a comment.",
                  //)
                }
                //if the post has comments and the flip was false upvote a post
                False -> {
                  process.send(
                    state.reddit_engine,
                    types.UpVotePost(post.sub_id, post.id),
                  )
                  //io.println("User " <> state.username <> " up voted a post.")
                }
              }
              actor.continue(state)
            }
            False -> {
              //no posts to upvote
              actor.continue(state)
            }
          }
        }
        //Downvote comment or post
        n if n >. 0.68 && n <. 0.8 -> {
          case !list.is_empty(state.feed) {
            True -> {
              let post = get_random_post(state.feed)
              //check if the post has any comments to reply to
              //flip a coin to decide if to reply to the post or reply to a comment
              case flip_a_coin() && !list.is_empty(post.comments) {
                //if the post has comments and the flip was true upvote a comment
                True -> {
                  let comment = get_random_comment(post.comments)
                  process.send(
                    state.reddit_engine,
                    types.DownVoteComment(post.sub_id, post.id, comment.id),
                  )
                  //io.println(
                  //"User " <> state.username <> " down voted a comment.",
                  //)
                }
                //if the post has comments and the flip was false upvote a post
                False -> {
                  process.send(
                    state.reddit_engine,
                    types.DownVotePost(post.sub_id, post.id),
                  )
                  //io.println("User " <> state.username <> " down voted a post.")
                }
              }
              actor.continue(state)
            }
            False -> {
              //can't do anything so just pass
              actor.continue(state)
            }
          }
        }
        n if n >. 0.8 && n <. 0.86 -> {
          //Repost another users post
          //if the feed is empty then there's no posts to repost
          //if the user isn't subscribed to any subreddits no place to repost
          case list.is_empty(state.feed) || list.is_empty(state.subreddits) {
            True -> {
              actor.continue(state)
            }
            False -> {
              //otherwise select a random post repost
              let post = get_random_post(state.feed)
              //io.println(
              //"User "
              //<> state.username
              //<> " reposted a post by user "
              //<> post.author_username,
              //)
              //select random sub from subscribed subreddits to repost in (can be the same subreddit)
              let sub = get_random_id(state.subreddits)
              //update post's to current author and new subreddit
              let assert Some(self) = state.subject
              let post =
                types.Post(
                  ..post,
                  author_username: state.username,
                  author_subject: self,
                  sub_id: sub,
                )
              actor.send(state.reddit_engine, types.PostInSub(sub, post))
              actor.continue(state)
            }
          }
        }
        n if n >. 0.86 && n <. 0.96 -> {
          //ask reddit for a user to send a message to 
          let assert Some(self) = state.subject
          actor.send(state.reddit_engine, types.GetAUser(self))
          actor.continue(state)
        }
        _ -> {
          //put user to sleep for a time
          //io.println("User " <> state.username <> " is going offline.")
          //sleep time is proportional to the user frequency so hyper users don't sleep as long :P
          let time = state.frequency * 5
          actor.send(state.reddit_engine, types.OnlineUpdate(-1))
          process.sleep(time)
          //io.println("User " <> state.username <> " is back online.")
          actor.send(state.reddit_engine, types.OnlineUpdate(1))
          actor.continue(state)
        }
      }
      //select the next action for the user to take
      let assert Some(self) = state.subject
      let #(next_choice, updated_seed) = state.generator |> random.step(seed)
      process.send_after(
        self,
        state.frequency,
        types.NextAction(next_choice, updated_seed),
      )
      actor.continue(state)
    }
    types.JoinSub(all_subs) -> {
      //get only the subreddits the user isn't already a part of
      let filtered =
        list.filter(all_subs, fn(sub) { !list.contains(state.subreddits, sub) })

      case list.is_empty(filtered) {
        True -> {
          //already a part of all the subreddits
          actor.continue(state)
        }
        False -> {
          //get the id of one of the avilable subreddits
          let sub_index = get_random_id(filtered)
          //io.println("Choosen sub: " <> int.to_string(sub_index))
          //send self's subject so you can get updates
          let assert Some(self) = state.subject
          actor.send(state.reddit_engine, types.JoinSubReddit(sub_index, self))
          //update subreddits account is subscribed to
          let updated_subs = list.append(state.subreddits, [sub_index])
          //io.println(
          //"User " <> state.username <> " subscribed to a new subreddit",
          //)
          actor.continue(types.Account(..state, subreddits: updated_subs))
        }
      }
    }
    types.ReceiveDM(message) -> {
      //choose to ignore the message or reply to it
      //otherwise the messages will just ping pong forever
      let choice = int.random(2)
      case choice {
        //ignore message
        0 -> {
          actor.continue(
            types.Account(..state, inbox: list.append(state.inbox, [message])),
          )
        }
        //reply to message
        _ -> {
          let assert Some(self) = state.subject
          let reply =
            types.DirectMessage(self, {
              state.username <> " sent you a really cool message."
            })
          actor.send(message.sender, types.ReceiveDM(reply))
          actor.continue(
            types.Account(..state, inbox: list.append(state.inbox, [message])),
          )
        }
      }
    }
    types.SendDM(other) -> {
      let assert Some(self) = state.subject
      case other == self {
        True -> {
          //no one to message :((((
          Nil
        }
        //send message to the other user
        False -> {
          let dm =
            types.DirectMessage(
              self,
              state.username <> " sent you a really cool message.",
            )
          actor.send(other, types.ReceiveDM(dm))
          Nil
        }
      }

      //not tracking which messages the user sends
      actor.continue(state)
    }
    types.UpdateKarma(new_vote) -> {
      //io.println(
      //"User "
      //<> state.username
      //<> " now has  "
      //<> int.to_string(state.karma + new_vote)
      //<> " karma.",
      //)
      //value will be either 1 or -1 so just add to value (can be negative)
      actor.continue(types.Account(..state, karma: { state.karma + new_vote }))
    }
    types.AddToFeed(post) -> {
      //someone posted in a subreddit so add that to the user feed
      actor.continue(
        types.Account(..state, feed: list.append(state.feed, [post])),
      )
    }
    types.UpdateFeed(updated_post) -> {
      //if feed is empty then updated post is treated as a new post
      case list.is_empty(state.feed) {
        True -> {
          actor.continue(
            types.Account(
              ..state,
              feed: list.append(state.feed, [updated_post]),
            ),
          )
        }
        //otherwise update existing post in feed with new comment
        False -> {
          let updated_feed =
            list.map(state.feed, fn(post) {
              case post.id == updated_post.id {
                True -> updated_post
                False -> post
              }
            })
          actor.continue(types.Account(..state, feed: updated_feed))
        }
      }
    }
  }
}

//most used for subreddit
fn get_random_id(list: List(Int)) -> Int {
  let len = list.length(list)
  case len == 1 {
    True -> {
      let assert Ok(sub_id) = list.first(list)
      sub_id
    }
    False -> {
      //select random item in the list
      let index = int.random(len)
      //splits list in two before the index
      let split = list.split(list, index)
      //get first item in second list from splits
      let assert Ok(sub_id) = list.first(pair.second(split))
      sub_id
    }
  }
}

fn get_random_post(list: List(types.Post)) -> types.Post {
  let len = list.length(list)
  case len == 1 {
    True -> {
      let assert Ok(post) = list.first(list)
      post
    }
    False -> {
      let index = int.random(len)
      let split = list.split(list, index)
      let assert Ok(post) = list.first(pair.second(split))
      post
    }
  }
}

fn get_random_comment(list: List(types.Comment)) -> types.Comment {
  let len = list.length(list)
  case len == 1 {
    True -> {
      let assert Ok(comment) = list.first(list)
      comment
    }
    False -> {
      let index = int.random(len)
      let split = list.split(list, index)
      let assert Ok(comment) = list.first(pair.second(split))
      comment
    }
  }
}

//just adds some dynamic chooses without creating a seperate function
//neccessiates less messages
fn flip_a_coin() -> Bool {
  let choice = int.random(2)
  case choice {
    0 -> True
    _ -> False
  }
}

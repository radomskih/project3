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

pub fn engine_message_handler(
  state: types.Engine,
  message: types.EngineMessage,
) -> actor.Next(types.Engine, types.EngineMessage) {
  let time_passed =
    timestamp.difference(state.start_time, timestamp.system_time())
  let seconds_passed = duration.to_seconds(time_passed)
  case seconds_passed >=. int.to_float(state.duration) {
    True -> {
      //stop the show!
      print_engine(state)
      actor.send(state.reply_subj, "Simulation complete!")
      actor.stop()
    }
    False -> {
      //update the state for the message handling
      let state = types.Engine(..state, last_display: display_reddit(state))
      case message {
        types.Join(user) -> {
          actor.continue(
            types.Engine(
              ..state,
              accounts: list.append(state.accounts, [user]),
              online: { state.online + 1 },
              trans_count: { state.trans_count + 1 },
            ),
          )
        }
        types.CreateSubReddit(name) -> {
          //start subreddit indexing at 1
          let id = list.length(state.subreddits) + 1
          //create new subreddit
          let sub = types.SubReddit(id, name, [], [])
          //add this subreddit to the list of existing subreddits
          let sub_list = list.append(state.subreddits, [sub])
          actor.continue(
            types.Engine(..state, subreddits: sub_list, trans_count: {
              state.trans_count + 1
            }),
          )
        }
        types.JoinSubReddit(sub_id, user_subject) -> {
          //using map to locate and update the subreddit of interest
          let updated_subreddits =
            //look for subreddit ID from existing list 
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                //if this subreddit has the ID then update the number of subscribers
                True -> {
                  let new_accounts =
                    list.append(subreddit.subscribers, [user_subject])
                  types.SubReddit(..subreddit, subscribers: new_accounts)
                }
                //if this isn't the subreddit then just return the un changed 
                //subreddit to the updated list of subreddit
                False -> {
                  subreddit
                }
              }
            })
          //update reddit engine state to include updated list of subreddits
          //and count this towards transmissions
          actor.continue(
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            }),
          )
        }
        types.LeaveSubReddit(sub_id, subject) -> {
          //use map to iterate of list of subreddits and only edit the one we want
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                //find subreddit user is leaving and remove user from the list
                True -> {
                  let new_accounts =
                    //finds the first matching item and removes it from the list
                    list.drop_while(subreddit.subscribers, fn(subscriber) {
                      subscriber == subject
                    })
                  types.SubReddit(..subreddit, subscribers: new_accounts)
                }
                False -> {
                  subreddit
                }
              }
            })
          //update reddit engine state to include updated list of subreddits
          //and count this towards transmissions
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.PostInSub(sub_id, post) -> {
          //io.println("Someone posted in " <> int.to_string(sub_id) <> ".")
          //use map to iterate of list of subreddits and only edit the one we want
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                //found subreddit of interest so update the post's comments to add the new one
                True -> {
                  //let the reddit engine handle all ID generation for REST API stuff
                  //posts are unique only with subreddit id
                  let new_id = list.length(subreddit.posts) + 1
                  let post = types.Post(..post, id: new_id)
                  //update the list of posts
                  let new_posts = list.append(subreddit.posts, [post])
                  //send update to subscribers
                  list.each(subreddit.subscribers, fn(subscriber) {
                    actor.send(subscriber, types.AddToFeed(post))
                  })
                  //return a subreddit with an updated list of posts
                  types.SubReddit(..subreddit, posts: new_posts)
                }
                False -> {
                  //we don't care about you >_<
                  subreddit
                }
              }
            })
          //update reddit engine state to include updated list of subreddits
          //and count this towards transmissions
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.CommentOnPost(sub_id, post_id, comment) -> {
          //use map to step through list of subreddits and only update the one we're interested in
          //this reduces time complexity since you're not searching through all posts on the reddit engine
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                //when we find the subreddit of interest, the find the post
                True -> {
                  //use map to step through list of posts and only update the one we're interested in
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      //when we find the post add comment
                      case post.id == post_id {
                        True -> {
                          //let the reddit engine handle all ID generation for REST API stuff
                          //comment id are unique only in conjuction with subreddit and post ids
                          let new_id = list.length(post.comments) + 1
                          //update the comment the user sent with this id
                          let comment = types.Comment(..comment, id: new_id)
                          //append comment to posts list to create a new list
                          let updated_comments =
                            list.append(post.comments, [comment])
                          //since we updated the comment we also need to update the post (BOOOOO STATIC VARIABLES)
                          let new_post =
                            types.Post(..post, comments: updated_comments)

                          //send new post out to all subscribers
                          list.each(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          new_post
                        }
                        False -> {
                          //not the post we were looking for so you don't get updated
                          post
                        }
                      }
                    })
                  //returns a new subreddit to the list that started the search
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  //other subreddits remain unaffected
                  subreddit
                }
              }
            })
          //update reddit engine state to include updated list of subreddits
          //and count this towards transmissions
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.ReplyToComment(sub_id, post_id, existing_comment_id, new_comment) -> {
          //this is the exact same setup as the previus function
          //search in subreddits to find the one you want
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                True -> {
                  //search in this subreddits post to find the post you want to
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True -> {
                          //let the reddit engine handle all ID generation for REST API stuff
                          //comment id are unique only in conjuction with subreddit and post ids
                          let new_id = list.length(post.comments)
                          //update new comment with its new id and its parents id
                          //could have done this on the user side but I needed the parent_id anyway
                          let new_comment =
                            types.Comment(
                              ..new_comment,
                              id: new_id,
                              parent_id: existing_comment_id,
                            )
                          //update post's list of comments to include this one
                          let updated_comments =
                            list.append(post.comments, [new_comment])
                          //BOOO static typing, also update post
                          let new_post =
                            types.Post(..post, comments: updated_comments)
                          //notify subscribrs of this subreddit
                          list.each(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          //return updated post to subreddit
                          new_post
                        }
                        False -> {
                          //leave other posts unchanged
                          post
                        }
                      }
                    })
                  //return updated subreddit to reddit engine
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  subreddit
                }
              }
            })
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.UpVotePost(sub_id, post_id) -> {
          //find subreddit that match the id and update
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                True -> {
                  //find post that matches the id in this subreddit and update
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True -> {
                          //let author know their karma has changed
                          actor.send(post.author_subject, types.UpdateKarma(1))
                          //update post and let subscribers know
                          let new_post =
                            types.Post(..post, up_votes: { post.up_votes + 1 })
                          list.each(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          //return new updated post
                          new_post
                        }
                        False -> {
                          //leave other posts unchanged
                          post
                        }
                      }
                    })
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  subreddit
                }
              }
            })
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.DownVotePost(sub_id, post_id) -> {
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                True -> {
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True -> {
                          actor.send(post.author_subject, types.UpdateKarma(-1))
                          let new_post =
                            types.Post(..post, up_votes: { post.up_votes + 1 })
                          list.each(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          new_post
                        }
                        False -> {
                          post
                        }
                      }
                    })
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  subreddit
                }
              }
            })
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.UpVoteComment(sub_id, post_id, comment_id) -> {
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                True -> {
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True -> {
                          let updated_comments =
                            list.map(post.comments, fn(comment) {
                              case comment.id == comment_id {
                                True -> {
                                  actor.send(
                                    comment.author_subject,
                                    types.UpdateKarma(1),
                                  )
                                  types.Comment(..comment, up_votes: {
                                    comment.up_votes + 1
                                  })
                                }
                                False -> comment
                              }
                            })
                          let new_post =
                            types.Post(..post, comments: updated_comments)
                          list.map(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          new_post
                        }
                        False -> post
                      }
                    })
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  subreddit
                }
              }
            })
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.DownVoteComment(sub_id, post_id, comment_id) -> {
          let updated_subreddits =
            list.map(state.subreddits, fn(subreddit) {
              case subreddit.id == sub_id {
                True -> {
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True -> {
                          let updated_comments =
                            list.map(post.comments, fn(comment) {
                              case comment.id == comment_id {
                                True -> {
                                  actor.send(
                                    comment.author_subject,
                                    types.UpdateKarma(-1),
                                  )
                                  types.Comment(..comment, down_votes: {
                                    comment.down_votes + 1
                                  })
                                }
                                False -> comment
                              }
                            })
                          let new_post =
                            types.Post(..post, comments: updated_comments)
                          list.each(subreddit.subscribers, fn(subscriber) {
                            actor.send(subscriber, types.UpdateFeed(new_post))
                          })
                          new_post
                        }
                        False -> post
                      }
                    })
                  types.SubReddit(..subreddit, posts: updated_posts)
                }
                False -> {
                  subreddit
                }
              }
            })
          let new_state =
            types.Engine(..state, subreddits: updated_subreddits, trans_count: {
              state.trans_count + 1
            })
          actor.continue(new_state)
        }
        types.GetSubReddits(client) -> {
          //get all subreddit ids
          let sub_ids = list.map(state.subreddits, fn(sub) { sub.id })
          process.send(client, types.JoinSub(sub_ids))
          actor.continue(state)
        }
        types.GetAUser(user) -> {
          let len = list.length(state.accounts)
          case len {
            //you're the ony user so message yourself (handled on user side)
            1 -> {
              actor.send(user, types.SendDM(user))
              actor.continue(state)
            }
            _ -> {
              //remove the user who initaiated the request
              let filtered =
                list.filter(state.accounts, fn(sbj) { sbj != user })
              //select a random index in the list
              let index = int.random(len - 1)
              //split list before that index
              let split = list.split(filtered, index)
              //get the user
              let assert Ok(other_user) = list.first(pair.second(split))
              actor.send(user, types.SendDM(other_user))
              actor.continue(
                types.Engine(..state, message_count: { state.message_count + 1 }),
              )
            }
          }
        }
        types.OnlineUpdate(num) -> {
          actor.continue(types.Engine(..state, online: { state.online + num }))
        }
      }
    }
  }
}

pub fn display_reddit(reddit: types.Engine) -> timestamp.Timestamp {
  let curr_time = timestamp.system_time()
  let time_passed = timestamp.difference(reddit.last_display, curr_time)
  let seconds_passed = duration.to_seconds(time_passed)
  //io.println("time since last display " <> float.to_string(seconds_passed))
  case seconds_passed >=. 1.0 {
    True -> {
      print_engine(reddit)
      curr_time
    }
    False -> {
      reddit.last_display
    }
  }
}

pub fn print_engine(reddit: types.Engine) -> Nil {
  io.print(
    "Reddit Engine State\n"
    <> "Number of subreddits: "
    <> int.to_string(list.length(reddit.subreddits))
    <> "\n"
    <> "Number of posts: "
    <> int.to_string(
      list.fold(reddit.subreddits, 0, fn(count, sub) {
        count + list.length(sub.posts)
      }),
    )
    <> "\n"
    <> "Number of comments: "
    <> int.to_string(
      list.fold(reddit.subreddits, 0, fn(count, sub) {
        let comment_count =
          list.fold(sub.posts, 0, fn(cum, post) {
            cum + list.length(post.comments)
          })
        count + comment_count
      }),
    )
    <> "\n"
    <> "Users online: "
    <> int.to_string(reddit.online)
    <> "/"
    <> int.to_string(list.length(reddit.accounts))
    <> "\n"
    <> "Number of requests to engine: "
    <> int.to_string(reddit.trans_count)
    <> "\n"
    <> "Messages transmitted between users: "
    <> int.to_string(reddit.message_count)
    <> "\n"
    <> "-----------------------------------------------------------\n",
  )
}

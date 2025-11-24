import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/time/timestamp
import prng/random
import prng/seed

//Keeps track of user data for part 2 of the project
pub type Account {
  Account(
    username: String,
    subject: Option(Subject(AccountMessage)),
    frequency: Int,
    subreddits: List(Int),
    feed: List(Post),
    karma: Int,
    inbox: List(DirectMessage),
    reddit_engine: Subject(EngineMessage),
    generator: random.Generator(Float),
    start_time: timestamp.Timestamp,
  )
}

//User actions
pub type AccountMessage {
  //to get your own subject
  Start(Subject(AccountMessage))
  //the actor uses the number it's given to choose its next action
  NextAction(choice: Float, seed: seed.Seed)
  //get a subreddit first so you can join it
  JoinSub(all_subs: List(Int))
  //messaging between users
  ReceiveDM(message: DirectMessage)
  //get a user to message from reddit engine
  SendDM(other: Subject(AccountMessage))
  //called whenever someone votes on a post or comment
  UpdateKarma(int: Int)
  //update feed when new post comes in
  AddToFeed(post: Post)
  //update feed when a change is made to an existing post (comment replies)
  UpdateFeed(new_post: Post)
}

//trying to replicate a database so this would be the subreddit table
//it only keeps track of its own posts, each post must manage their own comments
//a subreddit can have many posts, but a post can't have multiple subreddits
pub type SubReddit {
  SubReddit(
    id: Int,
    name: String,
    posts: List(Post),
    subscribers: List(Subject(AccountMessage)),
  )
}

//trying to replicate a database so this would be the posts table
//it only keeps track of its own comments
//a post can have many comments, but a comment can only have one post
pub type Post {
  Post(
    id: Int,
    sub_id: Int,
    title: String,
    author_username: String,
    author_subject: Subject(AccountMessage),
    content: String,
    comments: List(Comment),
    up_votes: Int,
    down_votes: Int,
  )
}

//lowest element of the "database" hierachy so tracks nothing, just contains information
//parent id is 0, if it's the first level under a post
//otherwise the parent id is the id of the comment that this comment was replying to 
//the comment thread hierarchy would need to be enforced through a visual aid
pub type Comment {
  Comment(
    id: Int,
    content: String,
    author_username: String,
    author_subject: Subject(AccountMessage),
    //not zero if a reply to another comment
    parent_id: Int,
    up_votes: Int,
    down_votes: Int,
  )
}

//just easier to keep track of what I'm referencing vs using a pair
pub type DirectMessage {
  DirectMessage(sender: Subject(AccountMessage), message: String)
}

pub type Engine {
  Engine(
    //let each subreddit be a container to keep all the posts of that subreddit together
    subreddits: List(SubReddit),
    //keep track of subjects to update subscribers
    accounts: List(Subject(AccountMessage)),
    reply_subj: Subject(String),
    start_time: timestamp.Timestamp,
    //until simulation is over
    duration: Int,
    //for displaying update
    last_display: timestamp.Timestamp,
    online: Int,
    message_count: Int,
    trans_count: Int,
  )
}

pub type EngineMessage {
  //main functions
  Join(user: Subject(AccountMessage))
  CreateSubReddit(name: String)
  JoinSubReddit(sub_id: Int, user: Subject(AccountMessage))
  LeaveSubReddit(sub_id: Int, user: Subject(AccountMessage))
  PostInSub(sub_id: Int, post: Post)
  CommentOnPost(sub_id: Int, post_id: Int, comment: Comment)
  ReplyToComment(
    sub_id: Int,
    post_id: Int,
    existing_comment_id: Int,
    new_comment: Comment,
  )
  UpVotePost(sub_id: Int, post_id: Int)
  DownVotePost(sub_id: Int, post_id: Int)
  UpVoteComment(sub_id: Int, post_id: Int, comment_id: Int)
  DownVoteComment(sub_id: Int, post_id: Int, comment_id: Int)
  //for joining a subreddit
  GetSubReddits(user: Subject(AccountMessage))
  //for sending messages
  GetAUser(user: Subject(AccountMessage))
  //user notifies engine it's off or online
  OnlineUpdate(int: Int)
}

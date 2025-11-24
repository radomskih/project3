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

require "mysigner/version"
require "mysigner/config"
require "mysigner/client"
require "mysigner/build/detector"
require "mysigner/build/parser"
require "mysigner/build/configurator"
require "mysigner/build/executor"
require "mysigner/cli"

module Mysigner
  class Error < StandardError; end
end

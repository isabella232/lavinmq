require "./avalanchemq/version"
require "option_parser"
require "amqp-client"

class Perf
  @url = "amqp://guest:guest@localhost"
  @publishers = 1
  @consumers = 1
  @size = 1024
  @exchange = ""
  @queue = "perf-test"
  @routing_key = "perf-test"
  @no_ack = true
  @rate = 0
  @consume_rate = 0

  def parser
    parser = OptionParser.new
    parser.banner = "Usage: #{PROGRAM_NAME} [arguments] entity"
    parser.on("-u url", "--url=URL", "URL to connect to (default amqp://guest:guest@localhost)") do |v|
      @url = v
    end
    parser.on("-x publishers", "--publishers=number", "Number of publishers (default 1)") do |v|
      @publishers = v.to_i
    end
    parser.on("-y consumers", "--consumers=number", "Number of consumers (default 1)") do |v|
      @consumers = v.to_i
    end
    parser.on("-s msgsize", "--size=bytes", "Size of each message (default 1KB)") do |v|
      @size = v.to_i
    end
    parser.on("-a", "--ack", "Ack consumed messages (default false)") do
      @no_ack = false
    end
    parser.on("-c", "--confirm", "Confirm publishes (default false)") do
      @confirm = true
    end
    parser.on("-q queue", "--queue=name", "Queue name (default perf-test)") do |v|
      @queue = v
    end
    parser.on("-e exchange", "--exchange=name", "Exchange to publish to (default \"\")") do |v|
      @exchange = v
    end
    parser.on("-r pub-rate", "--rate=number", "Max publish rate (default 0)") do |v|
      @rate = v.to_i
    end
    parser.on("-R consumer-rate", "--consumer-rate=number", "Max consume rate (default 0)") do |v|
      @consume_rate = v.to_i
    end
    parser.on("-h", "--help", "Show this help") { puts parser; exit 1 }
    parser.on("-v", "--version", "Show version") { puts AvalancheMQ::VERSION; exit 0 }
    parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
    parser
  end

  def run
    parser.parse!

    @publishers.times do
      spawn pub
    end

    @consumers.times do
      spawn consume
    end

    loop do
      sleep 1
      print "Publish rate: "
      print @pubs
      print " msgs/s Consume rate: "
      print @consumes
      print " msgs/s\n"
      @pubs = 0
      @consumes = 0
    end
  end

  @pubs = 0
  @consumes = 0

  def pub
    a = AMQP::Client.new(@url).connect
    ch = a.channel
    data = "0" * @size
    loop do
      if @confirm
        ch.basic_publish_confirm data, @exchange, @routing_key
      else
        ch.basic_publish data, @exchange, @routing_key
      end
      @pubs += 1
      if @rate.zero?
        Fiber.yield if @pubs % 1000 == 0
      else
        sleep 1.0 / @rate
      end
    end
  ensure
    a.try &.close
  end

  def consume
    a = AMQP::Client.new(@url).connect
    ch = a.channel
    ch.queue(@queue).subscribe(no_ack: @no_ack) do |m|
      m.ack unless @no_ack
      @consumes += 1
      if @consume_rate.zero?
        Fiber.yield if @consumes % 1000 == 0
      else
        sleep 1.0 / @consume_rate
      end
    end
    sleep
  ensure
    a.try &.close
  end
end

Perf.new.run

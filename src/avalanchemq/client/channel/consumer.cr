require "logger"
require "./consumer"

module AvalancheMQ
  class Client
    class Channel
      class Consumer
        getter no_ack, queue, unacked, tag
        @log : Logger

        def initialize(@channel : Client::Channel, @tag : String, @queue : Queue, @no_ack : Bool)
          @log = @channel.log.dup
          @log.progname += "/Consumer[#{@tag}]"
          @unacked = Set(SegmentPosition).new
        end

        def accepts?
          @channel.prefetch_count.zero? || @unacked.size < @channel.prefetch_count
        end

        def deliver(msg, sp, queue, redelivered = false)
          @unacked << sp unless @no_ack

          @log.debug { "Getting delivery tag" }
          delivery_tag = @channel.next_delivery_tag(queue, sp, @no_ack, self)
          @log.debug { "Sending BasicDeliver" }
          @channel.send AMQP::Basic::Deliver.new(@channel.id, @tag,
                                                 delivery_tag,
                                                 redelivered,
                                                 msg.exchange_name, msg.routing_key)
          @channel.deliver(msg)
        end

        def ack(sp)
          @log.debug { "Ackin #{sp}. Unacked: #{@unacked.size}" }
          @unacked.delete(sp)
        end

        def reject(sp)
          @log.debug { "Rejecting #{sp}. Unacked: #{@unacked.size}" }
          @unacked.delete(sp)
        end
      end
    end
  end
end

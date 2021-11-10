require "file_utils"
require "./queue"
require "../schema"

module AvalancheMQ
  class DurableQueue < Queue
    @durable = true
    @ack_lock = Mutex.new(:checked)
    @enq_lock = Mutex.new(:checked)
    @ack : MFile

    def initialize(@vhost : VHost, @name : String,
                   @exclusive : Bool, @auto_delete : Bool,
                   @arguments : Hash(String, AMQP::Field))
      super
      @index_dir = File.join(@vhost.data_dir, Digest::SHA1.hexdigest @name)
      @log.debug { "Index dir: #{@index_dir}" }
      if Dir.exists?(@index_dir)
        restore_index
      else
        Dir.mkdir @index_dir
      end
      File.write(File.join(@index_dir, ".queue"), @name)
      @enq = MFile.new(File.join(@index_dir, "enq"), ack_max_file_size)
      SchemaVersion.verify_or_prefix(@enq, :index)
      @enq.seek 0, IO::Seek::End
      @enq.advise(MFile::Advice::DontNeed)
      @ack = MFile.new(File.join(@index_dir, "ack"), ack_max_file_size)
      SchemaVersion.verify_or_prefix(@ack, :index)
      @ack.seek 0, IO::Seek::End
      @ack.advise(MFile::Advice::DontNeed)
    end

    private def compact_index! : Nil
      @log.info { "Compacting index" }
      @enq_lock.lock
      i = 0
      @enq.close
      @enq = MFile.new(File.join(@index_dir, "enq.tmp"), ack_max_file_size + SP_SIZE * (@ready.size + @unacked.size))
      SchemaVersion.prefix(@enq, :index)
      @ready.locked_each do |all_ready|
        @unacked.locked_each do |all_unacked|
          next_unacked = all_unacked.next.as?(UnackQueue::Unack).try &.sp
          while sp = all_ready.next.as?(SegmentPosition)
            while next_unacked && next_unacked < sp
              @enq.write_bytes next_unacked
              i += 1
              next_unacked = all_unacked.next.as?(UnackQueue::Unack).try &.sp
            end
            @enq.write_bytes sp
            i += 1
          end
          while next_unacked
            @enq.write_bytes next_unacked
            i += 1
            next_unacked = all_unacked.next.as?(UnackQueue::Unack).try &.sp
          end
        end
      end

      @log.info { "Wrote #{i} SPs to new enq file" }
      @enq.move(File.join(@index_dir, "enq"))
      @enq.advise(MFile::Advice::DontNeed)

      @ack.delete
      @ack.close
      @ack = MFile.new(File.join(@index_dir, "ack"), Math.max(ack_max_file_size, @enq.size // 2))
      SchemaVersion.prefix(@ack, :index)
      @ack.advise(MFile::Advice::DontNeed)
    ensure
      @enq_lock.unlock
    end

    def close : Bool
      super || return false
      @log.debug { "Closing index files" }
      @enq_lock.synchronize do
        @enq.close
      end
      @ack_lock.synchronize do
        @ack.close
      end
      true
    end

    def delete : Bool
      super || return false
      @log.debug { "Deleting index directory" }
      FileUtils.rm_rf @index_dir
      true
    end

    def publish(sp : SegmentPosition, persistent = false) : Bool
      super || return false
      @enq_lock.synchronize do
        @log.debug { "writing #{sp} to enq" }
        begin
          @enq.write_bytes sp
        rescue IO::EOFError
          @log.debug { "Out of capacity in enq file, resizeing" }
          @enq.resize(@enq.size + ack_max_file_size)
          @enq.write_bytes sp
        end
      end
      true
    end

    protected def delete_message(sp : SegmentPosition) : Nil
      super
      @ack_lock.synchronize do
        begin
          @log.debug { "writing #{sp} to ack" }
          @ack.write_bytes sp
        rescue IO::EOFError
          half_enq_size = @enq.size // 2
          if @ack.size < half_enq_size && @ack.size < 512 * 1024**2
            @ack.resize half_enq_size + SP_SIZE
            @log.info { "Expanded ack file to avoid index compactation for long queue" }
            @ack.write_bytes sp
          else
            time = Time.measure do
              compact_index!
            end
            @log.info { "Compacting index took #{time.total_milliseconds} ms" }
          end
        end
      end
    end

    def purge(max_count : Int? = nil) : UInt32
      delete_count = super(max_count)
      return 0_u32 if delete_count.zero?
      if max_count.nil?
        @enq_lock.synchronize do
          @enq.close(truncate_to_size: false)
          @enq = MFile.new(File.join(@index_dir, "enq.tmp"), ack_max_file_size)
          SchemaVersion.prefix(@enq, :index)
          @enq.move(File.join(@index_dir, "enq"))
          @enq.advise(MFile::Advice::DontNeed)
        end
        @ack_lock.synchronize do
          @ack.close(truncate_to_size: false)
          @ack = MFile.new(File.join(@index_dir, "ack.tmp"), ack_max_file_size)
          SchemaVersion.prefix(@ack, :index)
          @ack.move(File.join(@index_dir, "ack"))
          @ack.advise(MFile::Advice::DontNeed)
        end
      else
        compact_index!
      end
      delete_count
    end

    def fsync_enq
      return if @closed
      # @log.debug "fsyncing enq"
      @enq.fsync
    end

    def fsync_ack
      return if @closed
      # @log.debug "fsyncing ack"
      @ack.fsync
    end

    SP_SIZE = SegmentPosition::BYTESIZE.to_i64

    private def restore_index : Nil
      @log.info "Restoring index"
      SchemaVersion.migrate(File.join(@index_dir, "enq"), :index)
      SchemaVersion.migrate(File.join(@index_dir, "ack"), :index)
      File.open(File.join(@index_dir, "enq")) do |enq|
        File.open(File.join(@index_dir, "ack")) do |ack|
          enq.buffer_size = Config.instance.file_buffer_size
          ack.buffer_size = Config.instance.file_buffer_size
          enq.advise(File::Advice::Sequential)
          ack.advise(File::Advice::Sequential)
          SchemaVersion.verify(enq, :index)
          SchemaVersion.verify(ack, :index)

          # Defer allocation of acked array in case we truncate due to zero sp.
          acked : Array(SegmentPosition)? = nil

          loop do
            sp = SegmentPosition.from_io ack
            if sp.zero?
              @log.info { "Truncating ack index" }
              File.open(ack.path, "W") do |f|
                f.truncate(ack.pos - SegmentPosition::BYTESIZE)
              end
              break
            end
            unless acked
              ack_count = ((ack.size - sizeof(Int32)) // SP_SIZE).to_u32
              acked = Array(SegmentPosition).new(ack_count)
            end
            acked << sp
          rescue IO::EOFError
            break
          end
          acked.try &.sort!

          # Defer allocation of ready queue in case we truncate due to zero sp.
          ready : ReadyQueue? = nil

          vhost = @vhost
          loop do
            sp = SegmentPosition.from_io enq
            if sp.zero?
              @log.info { "Truncating queue index" }
              File.open(enq.path, "W") do |f|
                f.truncate(enq.pos - SegmentPosition::BYTESIZE)
              end
              break
            end
            unless ready
              # To avoid repetetive allocations in Dequeue#increase_capacity
              # we redeclare the ready queue with a larger initial capacity
              enq_count = (enq.size.to_i64 - ack.size - (sizeof(Int32) * 2)) // SP_SIZE
              capacity = Math.max(enq_count, 1024)
              @ready = ready = ReadyQueue.new Math.pw2ceil(capacity)
            end
            next if acked.try { |a| a.bsearch { |asp| asp >= sp } == sp }
            ready << sp
            vhost.increase_segment_references(sp.segment)
          rescue IO::EOFError
            break
          end
          @log.info { "#{message_count} messages" }
          message_available if message_count > 0
        end
      end
    rescue ex : IO::Error
      @log.error { "Could not restore index: #{ex.inspect}" }
    end

    def enq_file_size
      @enq.size
    end

    def ack_file_size
      @ack.size
    end

    private def ack_max_file_size
      SP_SIZE * Config.instance.queue_max_acks
    end
  end
end

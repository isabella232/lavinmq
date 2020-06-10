module AvalancheMQ
  struct SegmentPosition
    include Comparable(self)

    getter segment, position
    def_equals_and_hash @segment, @position

    def initialize(@segment : UInt32, @position : UInt32)
    end

    def to_io(io : IO, format) : Int64
      buf = uninitialized UInt8[8]
      slice = buf.to_slice
      format.encode(@segment, slice[0, 4])
      format.encode(@position, slice[4, 4])
      io.write(slice)
    end

    def <=>(other : self)
      r = segment <=> other.segment
      return r unless r.zero?
      position <=> other.position
    end

    def self.from_io(io : IO, format = IO::ByteFormat::SystemEndian)
      seg = UInt32.from_io(io, format)
      pos = UInt32.from_io(io, format)
      self.new(seg, pos)
    end

    def to_s(io : IO)
      io << @segment.to_s.rjust(10, '0')
      io << @position.to_s.rjust(10, '0')
    end

    def self.parse(s)
      raise ArgumentError.new("A SegmentPosition string has to be 20 chars long") if s.bytesize != 20
      seg = s[0, 10].to_u32
      pos = s[10, 10].to_u32
      self.new seg, pos
    end
  end
end

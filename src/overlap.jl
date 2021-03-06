# BigWig Overlap
# ==============

struct OverlapIterator
    reader::Reader
    chromid::UInt32
    chromstart::UInt32
    chromend::UInt32
end

function Base.eltype(::Type{OverlapIterator})
    return Record
end

function Base.IteratorSize(::Type{OverlapIterator})
    return Base.SizeUnknown()
end

function GenomicFeatures.eachoverlap(reader::Reader, interval::Interval)
    if haskey(reader.chroms, seqname(interval))
        id, _ = reader.chroms[seqname(interval)]
    else
        id = typemax(UInt32)
    end
    return OverlapIterator(reader, id, leftposition(interval) - 1, rightposition(interval))
end

mutable struct OverlapIteratorState
    # inflating data stream
    stream::IOBuffer
    data::Vector{UInt8}
    done::Bool
    header::SectionHeader
    record::Record
    blocks::Vector{BBI.Block}
    current_block::Int
    n_records::UInt16
    current_record::UInt16
end

function Base.iterate(iter::OverlapIterator)
    data = Vector{UInt8}(undef, iter.reader.header.uncompress_buf_size)
    blocks = BBI.find_overlapping_blocks(iter.reader.index, iter.chromid, iter.chromstart, iter.chromend)
    # dummy header
    header = SectionHeader(0, 0, 0, 0, 0, 0, 0, 0)
    state = OverlapIteratorState(IOBuffer(), data, false, header, Record(), blocks, 1, 0, 0)
    return iterate(iter, state)
end

function Base.iterate(iter::OverlapIterator, state::OverlapIteratorState)
    advance!(iter, state)
    if state.done
        return nothing
    end
    return copy(state.record), state
end

function advance!(iter::OverlapIterator, state::OverlapIteratorState)
    while true
        # find a section that has at least one record
        while state.current_record == state.n_records && state.current_block ≤ lastindex(state.blocks)
            block = state.blocks[state.current_block]
            seek(iter.reader.stream, block.offset)
            size = BBI.uncompress!(state.data, read(iter.reader.stream, block.size))
            state.stream = IOBuffer(state.data[1:size])
            state.header = read(state.stream, SectionHeader)
            state.current_block += 1
            state.n_records = state.header.itemcount
            state.current_record = 0
        end
        if state.current_record == state.n_records && state.current_block > lastindex(state.blocks)
            state.done = true
            return state
        end

        # read a new record
        _read!(iter.reader, state, state.record)
        if overlaps(state.record, iter.chromid, iter.chromstart, iter.chromend)
            return state
        end
    end
end

function overlaps(record::Record, chromid::UInt32, chromstart::UInt32, chromend::UInt32)
    return record.header.chromid == chromid && !(record.chromend ≤ chromstart || record.chromstart ≥ chromend)
end

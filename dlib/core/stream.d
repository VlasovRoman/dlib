/*
Copyright (c) 2014 Martin Cejp
    
Boost Software License - Version 1.0 - August 17th, 2003
    
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:
    
The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.
    
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dlib.core.stream;

import std.bitmanip;
import std.stdint;
import std.conv;

import dlib.core.memory;

alias StreamPos = uint64_t;
alias StreamSize = uint64_t;
alias StreamOffset = int64_t;

class SeekException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/// Seekable
interface Seekable: ManuallyAllocatable
{
    // Won't throw on invalid position, may throw on a more serious error.
    
    StreamPos getPosition() @property;
    bool setPosition(StreamPos pos);
    StreamSize size();
    
    // Throw-on-error wrappers

    final StreamPos position(StreamPos pos)
    {
        if (!setPosition(pos))
            throw new SeekException("Cannot set Seekable position to " ~ pos.to!string);
            
        return pos;
    }
    
    final StreamPos position()
    {
        return getPosition();
    }
    
    // TODO: Non-throwing version
    final StreamPos seek(StreamOffset amount)
    {
        immutable StreamPos seekTo = getPosition() + amount;
        
        if (!setPosition(seekTo))
            throw new SeekException("Cannot set Seekable position to " ~ seekTo.to!string);
    
        return seekTo;
    }
}

/// Stream
interface Stream : Seekable
{
    void close();
    bool seekable();
}

interface InputStream : Stream
{
    // Won't throw on EOF, may throw on a more serious error.
    
    bool readable();
    size_t readBytes(void* buffer, size_t count);
    
    /// Read array.length elements into an pre-allocated array.
    /// Returns: true if all elements were read, false otherwise
    final bool fillArray(T)(T[] array)
    {
        immutable size_t len = array.length * T.sizeof;
        return readBytes(array.ptr, len) == len;
    }
    
    /// Read an integer in little-endian encoding
    final bool readLE(T)(T* value)
    {
        ubyte[T.sizeof] buffer;
        
        if (readBytes(buffer.ptr, buffer.length) != buffer.length)
            return false;
        
        *value = littleEndianToNative!T(buffer);
        return true;
    }
    
    /// Read an integer in big-endian encoding
    final bool readBE(T)(T* value)
    {
        ubyte[T.sizeof] buffer;
        
        if (readBytes(buffer.ptr, buffer.length) != buffer.length)
            return false;
        
        *value = bigEndianToNative!T(buffer);
        return true;
    }
}

interface OutputStream : Stream
{
    // Won't throw on full disk, may throw on a more serious error.
    
    void flush();
    bool writeable();
    size_t writeBytes(const void* buffer, size_t count);
    
    /// Write array.length elements from array.
    /// Returns: true if all elements were written, false otherwise
    final bool writeArray(T)(const T[] array)
    {
        immutable size_t len = array.length * T.sizeof;
        return writeBytes(array.ptr, len) == len;
    }
    
    /// Write a string as zero-terminated
    /// Returns: true on success, false otherwise
    final bool writeStringz(string text)
    {
        ubyte[1] zero = [0];
        
        return writeBytes(text.ptr, text.length)
            && writeBytes(zero.ptr, zero.length);
    }
    
    /// Write an integer in little-endian encoding
    final bool writeLE(T)(const T value)
    {
        ubyte[T.sizeof] buffer = nativeToLittleEndian!T(value);
        
        return writeBytes(buffer.ptr, buffer.length) == buffer.length;
    }
    
    /// Write an integer in big-endian encoding
    final bool writeBE(T)(const T value)
    {
        ubyte[T.sizeof] buffer = nativeToBigEndian!T(value);
        
        return writeBytes(buffer.ptr, buffer.length) == buffer.length;
    }
}

interface IOStream : InputStream, OutputStream
{
}

StreamSize copyFromTo(InputStream input, OutputStream output)
{
    ubyte[0x1000] buffer;
    StreamSize total = 0;

    while (input.readable)
    {
        size_t have = input.readBytes(buffer.ptr, buffer.length);

        if (have == 0)
            break;

        output.writeBytes(buffer.ptr, have);
        total += have;
    }

    return total;
}

// TODO: Move this?
// TODO: Add OutputStream methods
class ArrayStream : InputStream {
    import std.algorithm;
    
    this() {
    }
    
    this(ubyte[] data, size_t size) {
        assert(size_ <= data.length);
        
        this.size_ = size;
        this.data = data;
    }
    
    override void close() {
        this.pos = 0;
        this.size_ = 0;
        this.data = null;
    }
    
    override bool readable() {
        return pos < size_;
    }
    
    override size_t readBytes(void* buffer, size_t count) {
        import std.c.string;
        
        count = min(count, size_ - pos);
        
        // whoops, memcpy out of nowhere, can we do better than that?
        memcpy(buffer, data.ptr + pos, count);
        
        pos += count;
        return count;
    }
    
    override bool seekable() {
        return true;
    }
    
    override StreamPos getPosition() {
        return pos;
    }
    
    override bool setPosition(StreamPos pos) {
        if (pos > size_)
            return false;

        this.pos = cast(size_t)pos;
        return true;
    }
    
    override StreamSize size() {
        return size;
    }

    mixin ManualModeImpl;
    mixin FreeImpl;
    
    private:
    size_t pos = 0, size_ = 0;
    ubyte[] data;       // data.length is capacity
}

/*
Copyright (c) 2011-2015 Timur Gafarov, Martin Cejp

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

module dlib.image.io.png;

private
{
    import std.stdio;
    import std.math;
    import std.string;
    import std.range;

    import dlib.core.memory;
    import dlib.core.stream;
    import dlib.core.compound;
    import dlib.filesystem.local;
    import dlib.math.utils;
    import dlib.coding.zlib;
    import dlib.image.image;
    import dlib.image.io.io;
}

// uncomment this to see debug messages:
//version = PNGDebug;

static const ubyte[8] PNGSignature = [137, 80, 78, 71, 13, 10, 26, 10];
static const ubyte[4] IHDR = ['I', 'H', 'D', 'R'];
static const ubyte[4] IEND = ['I', 'E', 'N', 'D'];
static const ubyte[4] IDAT = ['I', 'D', 'A', 'T'];
static const ubyte[4] PLTE = ['P', 'L', 'T', 'E'];
static const ubyte[4] tRNS = ['t', 'R', 'N', 'S'];
static const ubyte[4] bKGD = ['b', 'K', 'G', 'D'];
static const ubyte[4] tEXt = ['t', 'E', 'X', 't'];
static const ubyte[4] iTXt = ['i', 'T', 'X', 't'];
static const ubyte[4] zTXt = ['z', 'T', 'X', 't'];

enum ColorType: ubyte
{
    Greyscale = 0,      // allowed bit depths: 1, 2, 4, 8 and 16
    RGB = 2,            // allowed bit depths: 8 and 16
    Palette = 3,        // allowed bit depths: 1, 2, 4 and 8
    GreyscaleAlpha = 4, // allowed bit depths: 8 and 16
    RGBA = 6,           // allowed bit depths: 8 and 16
    Any = 7             // one of the above
}

enum FilterMethod: ubyte
{
    None = 0,
    Sub = 1,
    Up = 2,
    Average = 3,
    Paeth = 4
}

struct PNGChunk
{
    uint length;
    ubyte[4] type;
    ubyte[] data;
    uint crc;
    
    void free()
    {
        if (data.ptr)
            Delete(data);
    }
}

struct PNGHeader
{
    union
    {
        struct 
        {
            uint width;
            uint height;
            ubyte bitDepth;
            ubyte colorType;
            ubyte compressionMethod;
            ubyte filterMethod;
            ubyte interlaceMethod;
        };
        ubyte[13] bytes;
    }
}
class PNGLoadException: ImageLoadException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/*
 * Load PNG from file using local FileSystem.
 * Causes GC allocation
 */
SuperImage loadPNG(string filename)
{
    InputStream input = openForInput(filename);
    auto img = loadPNG(input);    input.close();
    return img;
}

/*
 * Save PNG to file using local FileSystem.
 * Causes GC allocation
 */
void savePNG(SuperImage img, string filename)
{
    OutputStream output = openForOutput(filename);
    Compound!(bool, string) res = 
        savePNG(img, output);
    output.close();

    if (!res[0])
        throw new PNGLoadException(res[1]);
}

/*
 * Load PNG from stream using default image factory.
 * Causes GC allocation
 */
SuperImage loadPNG(InputStream istrm)
{
    Compound!(SuperImage, string) res = 
        loadPNG(istrm, defaultImageFactory);
    if (res[0] is null)
        throw new PNGLoadException(res[1]);
    else
        return res[0];
}

/*
 * Load PNG from stream using specified image factory.
 * GC-free
 */
Compound!(SuperImage, string) loadPNG(
    InputStream istrm, 
    SuperImageFactory imgFac)
{
    SuperImage img = null;
    
    Compound!(SuperImage, string) error(string errorMsg)
    {
        if (img)
        {
            img.free();
            img = null;
        }
        return compound(img, errorMsg);
    }

    bool readChunk(PNGChunk* chunk)
    {
        if (!istrm.readBE!uint(&chunk.length)
            || !istrm.fillArray(chunk.type))
        {
            return false;
        }
            
        version(PNGDebug) writefln("Chunk length = %s", chunk.length);
        version(PNGDebug) writefln("Chunk type = %s", cast(char[])chunk.type);
        
        if (chunk.length > 0)
        {
            chunk.data = New!(ubyte[])(chunk.length);

            if (!istrm.fillArray(chunk.data))
            {
                return false;
            }
        }
        
        version(PNGDebug) writefln("Chunk data.length = %s", chunk.data.length);
        
        if (!istrm.readBE!uint(&chunk.crc))
        {
            return false;
        }
            
        // TODO: reimplement CRC check with ranges instead of concatenation
        uint calculatedCRC = crc32(chain(chunk.type[0..$], chunk.data));
        
        version(PNGDebug) 
        {
            writefln("Chunk CRC = %s", chunk.crc);
            writefln("Calculated CRC = %s", calculatedCRC);
            writeln("-------------------");
        }

        if (chunk.crc != calculatedCRC)
        {
            return false;
        }
        
        return true;
    }
    
    bool readHeader(PNGHeader* hdr, PNGChunk* chunk)
    {
        hdr.bytes[] = chunk.data[];
        hdr.width = bigEndian(hdr.width);
        hdr.height = bigEndian(hdr.height);
        
        version(PNGDebug)
        { 
            writefln("width = %s", hdr.width);
            writefln("height = %s", hdr.height);
            writefln("bitDepth = %s", hdr.bitDepth);
            writefln("colorType = %s", hdr.colorType);
            writefln("compressionMethod = %s", hdr.compressionMethod);
            writefln("filterMethod = %s", hdr.filterMethod);
            writefln("interlaceMethod = %s", hdr.interlaceMethod);
            writeln("----------------"); 
        }
        
        return true;
    }

    ubyte[8] signatureBuffer;
    
    if (!istrm.fillArray(signatureBuffer))
    {
        return error("loadPNG error: signature check failed");
    }

    version(PNGDebug) 
    {
        writeln("----------------");
        writeln("PNG Signature: ", signatureBuffer);
        writeln("----------------");
    }
    
    PNGHeader hdr;
    
    ZlibDecoder zlibDecoder;
    
    ubyte[] palette;
    ubyte[] transparency;
    uint paletteSize = 0;

    bool endChunk = false;
    while (!endChunk && istrm.readable)
    {
        PNGChunk chunk;
        bool res = readChunk(&chunk);
        if (!res)
        {
            chunk.free();
            return error("loadPNG error: failed to read chunk");
        }
        else
        {
            if (chunk.type == IEND)
            {
                endChunk = true;
                chunk.free();
            }
            else if (chunk.type == IHDR)
            {
                if (chunk.data.length < hdr.bytes.length)
                    return error("loadPNG error: illegal header chunk");
                
                readHeader(&hdr, &chunk);
                chunk.free();

                bool supportedIndexed = 
                    (hdr.colorType == ColorType.Palette) && 
                    (hdr.bitDepth == 1 || 
                     hdr.bitDepth == 2 || 
                     hdr.bitDepth == 4 ||
                     hdr.bitDepth == 8);
                     
                if (hdr.bitDepth != 8 && hdr.bitDepth != 16 && !supportedIndexed)
                    return error("loadPNG error: unsupported bit depth");

                if (hdr.compressionMethod != 0)
                    return error("loadPNG error: unsupported compression method");

                if (hdr.filterMethod != 0)
                    return error("loadPNG error: unsupported filter method");

                if (hdr.interlaceMethod != 0) 
                    return error("loadPNG error: interlacing is not supported");
                
                uint bufferLength = ((hdr.width * hdr.bitDepth + 7) / 8) * hdr.height + hdr.height;
                ubyte[] buffer = New!(ubyte[])(bufferLength);
                
                zlibDecoder = ZlibDecoder(buffer);
                
                version(PNGDebug) 
                {
                    writefln("buffer.length = %s", bufferLength);
                    writeln("----------------"); 
                }
            }
            else if (chunk.type == IDAT)
            {
                zlibDecoder.decode(chunk.data);
                chunk.free();
            }
            else if (chunk.type == PLTE)
            {
                palette = chunk.data;
            }
            else if (chunk.type == tRNS)
            {
                transparency = chunk.data;
                version(PNGDebug) 
                {
                    writeln("----------------"); 
                    writefln("transparency.length = %s", transparency.length);
                    writeln("----------------"); 
                }
            }
            else
            {
                chunk.free();
            }
        }
    }
    
    // finalize decoder
    version(PNGDebug) writefln("zlibDecoder.hasEnded = %s", zlibDecoder.hasEnded);
    if (!zlibDecoder.hasEnded)
        return error("loadPNG error: unexpected end of zlib stream");
    
    ubyte[] buffer = zlibDecoder.buffer;
    version(PNGDebug) writefln("buffer.length = %s", buffer.length);
    
    // create image
    if (hdr.colorType == ColorType.Greyscale)
    {
        if (hdr.bitDepth == 8)
            img = imgFac.createImage(hdr.width, hdr.height, 1, 8);
        else if (hdr.bitDepth == 16)
            img = imgFac.createImage(hdr.width, hdr.height, 1, 16);
    }
    else if (hdr.colorType == ColorType.GreyscaleAlpha)
    {
        if (hdr.bitDepth == 8)
            img = imgFac.createImage(hdr.width, hdr.height, 2, 8);
        else if (hdr.bitDepth == 16)
            img = imgFac.createImage(hdr.width, hdr.height, 2, 16);
    }
    else if (hdr.colorType == ColorType.RGB)
    {
        if (hdr.bitDepth == 8)
            img = imgFac.createImage(hdr.width, hdr.height, 3, 8);
        else if (hdr.bitDepth == 16)
            img = imgFac.createImage(hdr.width, hdr.height, 3, 16);
    }
    else if (hdr.colorType == ColorType.RGBA)
    {
        if (hdr.bitDepth == 8)
            img = imgFac.createImage(hdr.width, hdr.height, 4, 8);
        else if (hdr.bitDepth == 16)
            img = imgFac.createImage(hdr.width, hdr.height, 4, 16);
    }
    else if (hdr.colorType == ColorType.Palette)
    {
        if (transparency.length > 0)
            img = imgFac.createImage(hdr.width, hdr.height, 4, 8);
        else
            img = imgFac.createImage(hdr.width, hdr.height, 3, 8);
    }
    else
        return error("loadPNG error: unsupported color type");

    version(PNGDebug)
    {
        writefln("img.width = %s", img.width);
        writefln("img.height = %s", img.height);
        writefln("img.bitDepth = %s", img.bitDepth);
        writefln("img.channels = %s", img.channels);
        writeln("----------------"); 
    }

    bool indexed = (hdr.colorType == ColorType.Palette);
    
    // don't close the stream, just release our reference
    istrm = null;

    // apply filtering to the image data
    ubyte[] buffer2;
    string errorMsg;
    if (!filter(&hdr, img.channels, indexed, buffer, buffer2, errorMsg))
    {
        return error(errorMsg); 
    }
    Delete(buffer);
    buffer = buffer2;

    // if a palette is used, substitute target colors
    if (indexed)
    {
        if (palette.length == 0)
            return error("loadPNG error: palette chunk not found"); 

        ubyte[] pdata = New!(ubyte[])(img.width * img.height * img.channels);
        if (hdr.bitDepth == 8)
        {
            for (int i = 0; i < buffer.length; ++i)
            {
                ubyte b = buffer[i];
                pdata[i * img.channels + 0] = palette[b * 3 + 0];
                pdata[i * img.channels + 1] = palette[b * 3 + 1];
                pdata[i * img.channels + 2] = palette[b * 3 + 2];
                if (transparency.length > 0)
                    pdata[i * img.channels + 3] = 
                        b < transparency.length ? transparency[b] : 0;
            }
        }
        else // bit depths 1, 2, 4
        {
            int srcindex = 0;
            int srcshift = 8 - hdr.bitDepth;
            ubyte mask = cast(ubyte)((1 << hdr.bitDepth) - 1);
            int sz = img.width * img.height; 
            for (int dstindex = 0; dstindex < sz; dstindex++) 
            {
                auto b = ((buffer[srcindex] >> srcshift) & mask);
                pdata[dstindex * img.channels + 0] = palette[b * 3 + 0];
                pdata[dstindex * img.channels + 1] = palette[b * 3 + 1];
                pdata[dstindex * img.channels + 2] = palette[b * 3 + 2];
                
                if (transparency.length > 0)
                    pdata[dstindex * img.channels + 3] =
                        b < transparency.length ? transparency[b] : 0;

                if (srcshift <= 0)
                {
                    srcshift = 8 - hdr.bitDepth;
                    srcindex++;
                }
                else
                {
                    srcshift -= hdr.bitDepth;
                }
            }
        }
        
        Delete(buffer);
        buffer = pdata;
        
        Delete(palette);
        Delete(transparency);
    }

    if (img.data.length != buffer.length)
        return error("loadPNG error: uncompressed data length mismatch");
    
    foreach(i, v; buffer)
        img.data[i] = v;
        
    Delete(buffer);

    return compound(img, "");
}

/*
 * Save PNG to stream.
 * GC-free
 */
Compound!(bool, string) savePNG(SuperImage img, OutputStream output)
in
{
    assert (img.data.length);
}
body
{
    Compound!(bool, string) error(string errorMsg)
    {
        return compound(false, errorMsg);
    }

    if (img.bitDepth != 8)
        return error("savePNG error: only 8-bit images are supported by encoder");

    bool writeChunk(ubyte[4] chunkType, ubyte[] chunkData)
    {
        PNGChunk hdrChunk;
        hdrChunk.length = cast(uint)chunkData.length;
        hdrChunk.type = chunkType;
        hdrChunk.data = chunkData;
        hdrChunk.crc = crc32(chain(chunkType[0..$], hdrChunk.data));
        
        if (!output.writeBE!uint(hdrChunk.length)        
            || !output.writeArray(hdrChunk.type))
            return false;
        
        if (chunkData.length)
            if (!output.writeArray(hdrChunk.data))
                return false;

        if (!output.writeBE!uint(hdrChunk.crc))
            return false;

        return true;
    }

    bool writeHeader()
    {
        PNGHeader hdr;
        hdr.width = networkByteOrder(img.width);
        hdr.height = networkByteOrder(img.height);
        hdr.bitDepth = 8;
        if (img.channels == 4)
            hdr.colorType = ColorType.RGBA;
        else if (img.channels == 3)
            hdr.colorType = ColorType.RGB;
        else if (img.channels == 2)
            hdr.colorType = ColorType.GreyscaleAlpha;
        else if (img.channels == 1)
            hdr.colorType = ColorType.Greyscale;
        hdr.compressionMethod = 0;
        hdr.filterMethod = 0;
        hdr.interlaceMethod = 0;

        return writeChunk(IHDR, hdr.bytes);
    }

    output.writeArray(PNGSignature);
    if (!writeHeader())
        return error("savePNG error: write failed (disk full?)");

    //TODO: filtering
    ubyte[] raw = New!(ubyte[])(img.width * img.height * img.channels + img.height);
    foreach(y; 0..img.height)
    {
        auto rowStart = (img.height - y - 1) * (img.width * img.channels + 1);
        raw[rowStart] = 0; // No filter

        foreach(x; 0..img.width)
        {
            auto dataIndex = (y * img.width + x) * img.channels;
            auto rawIndex = rowStart + 1 + x * img.channels;

            foreach(ch; 0..img.channels)
                raw[rawIndex + ch] = img.data[dataIndex + ch];
        }
    }

    ubyte[] buffer = New!(ubyte[])(1024 * 32);
    ZlibEncoder zlibEncoder = ZlibEncoder(buffer);
    if (!zlibEncoder.encode(raw))
        return error("savePNG error: zlib encoding failed");
    //writeChunk(IDAT, cast(ubyte[])compress(raw));
    writeChunk(IDAT, zlibEncoder.buffer);
    writeChunk(IEND, []);

    zlibEncoder.free();
    Delete(raw);

    return compound(true, "");
}

/*
 * performs the paeth PNG filter from pixels values:
 *   a = back
 *   b = up
 *   c = up and back
 */
pure ubyte paeth(ubyte a, ubyte b, ubyte c)
{
    int p = a + b - c;
    int pa = abs(p - a);
    int pb = abs(p - b);
    int pc = abs(p - c);
    if (pa <= pb && pa <= pc) return a;
    else if (pb <= pc) return b;
    else return c;
}

bool filter(PNGHeader* hdr, 
            uint channels,
            bool indexed,
            ubyte[] ibuffer,
        out ubyte[] obuffer,
        out string errorMsg)
{
    uint dataSize = cast(uint)ibuffer.length;
    uint scanlineSize;

    uint calculatedSize;
    if (indexed)
    {
        calculatedSize = hdr.width * hdr.height * hdr.bitDepth / 8 + hdr.height;
        scanlineSize = hdr.width * hdr.bitDepth / 8 + 1;
    }
    else
    {
        calculatedSize = hdr.width * hdr.height * channels + hdr.height;
        scanlineSize = hdr.width * channels + 1;
    }

    version(PNGDebug)
    {
        writefln("[filter] dataSize = %s", dataSize);
        writefln("[filter] calculatedSize = %s", calculatedSize);
    }

    if (dataSize != calculatedSize)
    {
        errorMsg = "loadPNG error: image size and data mismatch";
        return false;
    }

    obuffer = New!(ubyte[])(calculatedSize - hdr.height);

    ubyte pback, pup, pupback, cbyte;

    for (int i = 0; i < hdr.height; ++i)
    {
        pback = 0;

        // get the first byte of a scanline
        ubyte scanFilter = ibuffer[i * scanlineSize];

        if (indexed)
        {
            // TODO: support filtering for indexed images
            if (scanFilter != FilterMethod.None)
            {
                errorMsg = "loadPNG error: filtering is not supported for indexed images";
                return false;
            }

            for (int j = 1; j < scanlineSize; ++j)
            {
                ubyte b = ibuffer[(i * scanlineSize) + j];
                obuffer[((hdr.height-i-1) * (scanlineSize-1) + j - 1)] = b;
            }
            continue;
        }

        for (int j = 0; j < hdr.width; ++j)
        {
            for (int k = 0; k < channels; ++k)
            {
                if (i == 0)    pup = 0;
                else pup = obuffer[((hdr.height-(i-1)-1) * hdr.width + j) * channels + k];
                if (j == 0)    pback = 0;
                else pback = obuffer[((hdr.height-i-1) * hdr.width + j-1) * channels + k];
                if (i == 0 || j == 0) pupback = 0;
                else pupback = obuffer[((hdr.height-(i-1)-1) * hdr.width + j - 1) * channels + k];
                
                // get the current byte from ibuffer
                cbyte = ibuffer[i * (hdr.width * channels + 1) + j * channels + k + 1];

                // filter, then set the current byte in data
                switch (scanFilter)
                {
                    case FilterMethod.None:
                        obuffer[((hdr.height-i-1) * hdr.width + j) * channels + k] = cbyte;
                        break;
                    case FilterMethod.Sub:
                        obuffer[((hdr.height-i-1) * hdr.width + j) * channels + k] = cast(ubyte)(cbyte + pback);
                        break;
                    case FilterMethod.Up:
                        obuffer[((hdr.height-i-1) * hdr.width + j) * channels + k] = cast(ubyte)(cbyte + pup);
                        break;
                    case FilterMethod.Average:
                        obuffer[((hdr.height-i-1) * hdr.width + j) * channels + k] = cast(ubyte)(cbyte + (pback + pup) / 2);
                        break;
                    case FilterMethod.Paeth:
                        obuffer[((hdr.height-i-1) * hdr.width + j) * channels + k] = cast(ubyte)(cbyte + paeth(pback, pup, pupback));
                        break;
                    default:
                        errorMsg = format("loadPNG error: unknown scanline filter (%s)", scanFilter);
                        return false;
                }
            }
        }
    }

    return true;
}

uint crc32(R)(R range, uint inCrc = 0) if (isInputRange!R)
{
    uint[256] generateTable()
    { 
        uint[256] table;
        uint crc;
        for (int i = 0; i < 256; i++)
        {
            crc = i;
            for (int j = 0; j < 8; j++)
                crc = crc & 1 ? (crc >> 1) ^ 0xEDB88320UL : crc >> 1;
            table[i] = crc;
        }
        return table;
    }

    static const uint[256] table = generateTable();

    uint crc;

    crc = inCrc ^ 0xFFFFFFFF;
    foreach(v; range)
        crc = (crc >> 8) ^ table[(crc ^ v) & 0xFF];

    return (crc ^ 0xFFFFFFFF);
}

unittest
{
    import std.base64;
    
    InputStream png() {
        string minimal =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVR42mL4z8AAEGAAAwEBAGb9nyQAAAAASUVORK5CYII=";
    
        ubyte[] bytes = Base64.decode(minimal);
        return new ArrayStream(bytes, bytes.length);
    }
    
    SuperImage img = loadPNG(png());
    
    assert(img.width == 1);
    assert(img.height == 1);
    assert(img.channels == 3);
    assert(img.pixelSize == 3);
    assert(img.data == [0xff, 0x00, 0x00]);
    
    createDir("tests", false);
    savePNG(img, "tests/minimal.png");
    loadPNG("tests/minimal.png");
}


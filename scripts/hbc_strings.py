#!/usr/bin/env python3
"""Print the string table of a Hermes bytecode (.hbc) file, one string per line.

Static inspection only: reads the file header and string table, never executes
anything. Supports Hermes bytecode versions 84-99 (React Native 0.70-0.8x).
Newlines inside strings are escaped as \\n so every line is one string.

Usage: hbc_strings.py FILE.hbc
"""
import struct
import sys

MAGIC = 0x1F1903C103BC1FC6
HEADER_SIZE = 128


def align4(n):
    return (n + 3) & ~3


def read_strings(data):
    magic, version = struct.unpack_from("<QI", data, 0)
    if magic != MAGIC:
        raise ValueError("not a Hermes bytecode file")
    if not 84 <= version <= 99:
        raise ValueError(f"unsupported Hermes bytecode version {version}")
    # After magic(8) version(4) sourceHash(20): u32 fields.
    names = ["fileLength", "globalCodeIndex", "functionCount", "stringKindCount",
             "identifierCount", "stringCount", "overflowStringCount",
             "stringStorageSize"]
    h = dict(zip(names, struct.unpack_from("<8I", data, 32)))

    off = HEADER_SIZE
    off = align4(off + h["functionCount"] * 16)       # small function headers
    off = align4(off + h["stringKindCount"] * 4)      # string kinds
    off = align4(off + h["identifierCount"] * 4)      # identifier hashes
    small_off = off
    off = align4(off + h["stringCount"] * 4)          # small string table
    overflow_off = off
    off = align4(off + h["overflowStringCount"] * 8)  # overflow string table
    storage_off = off
    storage_end = storage_off + h["stringStorageSize"]
    if storage_end > len(data):
        raise ValueError("string storage runs past end of file; layout mismatch")

    out = []
    for i in range(h["stringCount"]):
        (entry,) = struct.unpack_from("<I", data, small_off + i * 4)
        is_utf16 = entry & 1
        offset = (entry >> 1) & 0x7FFFFF
        length = entry >> 24
        if length == 0xFF:
            offset, length = struct.unpack_from("<II", data, overflow_off + offset * 8)
        start = storage_off + offset
        if is_utf16:
            raw = data[start:start + length * 2]
            s = raw.decode("utf-16-le", errors="replace")
        else:
            raw = data[start:start + length]
            s = raw.decode("latin-1")
        out.append(s)
    return version, out


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    _, strings = read_strings(data)
    w = sys.stdout.write
    for s in strings:
        w(s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r") + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

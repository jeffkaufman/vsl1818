import sys
import re
from socket import *
import struct

identify = """
  0040  11 00 55 aa 4c 00  00 00 03 01 02 01 d2 04   A...U.L. ........
  0050  00 00 03 00 0a 00 43 38  3a 42 43 3a 43 38 3a 31   ......C8 :BC:C8:1
  0060  41 3a 39 46 3a 30 41 00  00 00 00 00 00 00 00 00   A:9F:0A. ........
  0070  00 00 00 00 00 00 41 42  31 38 31 38 2d 56 53 4c   ......AB 1818-VSL
  0080  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00   ........ ........
  0090  00 00 00 00 00 00                                  ......
"""

def identify_bytes():
    bytes_s = []
    for line in identify.split("\n"):
        line = re.sub("   .*", "", line)

        cols = line.split()[1:]

        cols = cols[:16]
        for col in cols:
            bytes_s.append(col)
    return "".join(bytes_s).decode('hex')

def pp(rb):
    return " ".join(b.encode("hex") for b in rb)

def dumpstr(s,n):
    assert len(s) < n
    return s + "\x00"*(n-len(s))

def build_identify_bytes():
    m = "".join([struct.pack("IIHH",
                             0x01020103,
                             1234,
                             0x0003,
                             10),
                 dumpstr('C8:BC:C8:1A:9F:0A', 32),
                 dumpstr('AB1818-VSL', 32)])
    h = struct.pack("II", 0xaa550011, len(m))
    return h + m

def start():
    s = build_identify_bytes()
    print pp(s)
    print pp(identify_bytes())

    assert s == identify_bytes()

if __name__ == "__main__":
    start(*sys.argv[1:])

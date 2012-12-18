import sys
import re
import datetime
import struct

def pp(rb):
    return " ".join(b.encode("hex") for b in rb)

def process_bytes(bs):
    while True:
        initial = bs.read(8)
        if not initial:
            break
        assert len(initial) == 8
        signature, l = struct.unpack("II", initial)
        assert signature == 0xaa550011
        v = bs.read(l)
        assert len(v) == l
        r = Record(v[:12], v[12:])
        print str(r)

def parsestr(s, n=None):
    assert '\x00' in s
    if n is not None:
        assert len(s) == n
    return s[:s.find('\x00')]

class Record(object):
    def __init__(self, v, r):
        unknown1, unknown2, self.category, unknown3 = struct.unpack("IIHH", v)
        assert unknown1 == 0x01020103
        assert unknown2 == 1234
        assert unknown3 == 10

        self.channel = ''

        if self.category == 5:
            assert r == '\x00'*128

        elif self.category == 4:
            unknown4, self.e1, channel = struct.unpack("HH48s", r)
            assert unknown4 == 0
            self.channel = parsestr(channel)

        elif self.category == 2:
            self.c1, self.c2, self.c3, channel = struct.unpack("IIH32s", r)
            self.channel = parsestr(channel)
        else:
            raise Exception("unknown category %s" % self.category)

        # remove the null padding bytes from the channel
        self.channel = self.channel.replace('\x00','')

    def __str__(self):
        if self.category == 5:
            return "5: all zeros"
        elif self.category == 4:
            return "4: %s %s" % (self.e1, self.channel)
        elif self.category == 2:
            return "2: %s %s %s %s" % (self.c1, self.c2, self.c3, self.channel)
        else:
            assert False

class Tee(object):
    def __init__(self, fname_out, inf):
        self.inf = inf
        self.outf = open(fname_out, "w")

    def read(*args, **kwargs):
        s = self.inf.read(*args, **kwargs)
        self.outf.write(s)
        return s

def nowstr():
    n = datetime.datetime.now()
    return "%s-%s-%s--%s-%s-%s" % (
        n.year, n.month, n.day, n.hour, n.minute, n.second)

def start(args):
    if not args:
        # look for audiobox udp annoucement
        # create tcp connection
        # parse and display what we get from it
        serverHost = "localhost"
        serverPort = 7069

        # tcp
        s = socket(AF_INET, SOCK_STREAM)
        
        s.connect((serverHost, serverPort))
        s.send(identify_bytes())
                
        process_bytes(Tee("log-%s.bytes" % nowstr(), s))
    else:
        (fname, ) = args
        
        with open(fname, 'rb') as inf:
            process_bytes(inf)

if __name__ == "__main__":
    start(sys.argv[1:])

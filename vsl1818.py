import sys
import re
import datetime
import struct

def pp(rb):
    return " ".join(b.encode("hex") for b in rb)

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
            self.c1, channel = struct.unpack("10s32s", r)
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
            return "2: %s %s" % (pp(self.c1), self.channel)
        else:
            assert False

    @staticmethod
    def readall(bs):
        while True:
            initial = bs.read(8)
            if not initial:
                return
            assert len(initial) == 8
            signature, l = struct.unpack("II", initial)
            assert signature == 0xaa550011
            v = bs.read(l)
            assert len(v) == l
            yield Record(v[:12], v[12:])

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

def connection_record():
    # TODO: send our real mac address
    m = struct.pack("IIHH32s32s",
                    0x01020103,
                    1234,
                    0x0003,
                    10,
                    'C8:BC:C8:1A:9F:0A',
                    'AB1818-VSL')
    h = struct.pack("II", 0xaa550011, len(m))
    return h + m

def connect_tcp(host, port):
    s = socket(AF_INET, SOCK_STREAM)
    s.connect((host, port))

def should_connect(data):
    (r, ) = list(Record.readall(data))

def start(args):
    if not args:
        # hardcode a specific host
        s = connect_tcp("localhost", 7069)
        s.send(connection_record())

        bs = Tee("log-%s.bytes" % nowstr(), s)
        for r in Record.readall(bs):
            print str(r)
    else:
        (fname, ) = args

        with open(fname, 'rb') as bs:
            for r in Record.readall(bs):
                print str(r)

if __name__ == "__main__":
    start(sys.argv[1:])

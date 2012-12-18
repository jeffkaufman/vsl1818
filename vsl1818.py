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
        r = Record(v)
        print str(r)
        

def parseint(l):
    n = 0
    for x in reversed(list(l)):
        n *= 256
        n += ord(x)
    return n

def parsestr(s, n=None):
    assert '\x00' in s
    if n is not None:
        assert len(s) == n
    return s[:s.find('\x00')]

class Record(object):
    def __init__(self, v):
        v = v
        assert v[:4] == '\x03\x01\x02\x01'
        assert parseint(v[4:8]) == 1234
        self.category = parseint(v[8:9])
        assert parseint(v[10:12]) == 10

        self.channel = ''

        if self.category == 5:
            assert v[12:] == '\x00'*128
        elif self.category == 4:
            print pp(v[12:])
            assert v[12:14] == '\x00\x00'
            self.e1 = parseint(v[14:16])
            self.channel = parsestr(v[16:], 48)
        elif self.category == 2:
            self.c1 = parseint(v[12])
            self.c2 = parseint(v[13])
            self.c3 = v[17:21]
            self.c4 = v[21]
            self.channel = v[22:32]
            trailer = v[32:]
            self.c5 = {"80e1bf5fff7f00006e2a09000100000070e1bf5fff7f": 'A',
                       "a0debf5fff7f00001746040001000000e0dfbf5fff7f": 'B',
                       "c1c70c7ee5d19271000000000000f03f000000c06ddb": 'C'}[
                trailer.encode('hex')]
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
            return "2: %s %s %s %s %s %s" % (
                self.c1, self.c2, self.c3.encode('hex'), pp(self.c4), self.channel, self.c5)
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

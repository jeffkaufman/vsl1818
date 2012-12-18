import sys
import re


def startswith(raw_bytes, sequence):
    if len(raw_bytes) < len(sequence):
        return False
    beginning = raw_bytes[:len(sequence)]

    for i, (raw_byte, s) in enumerate(zip(beginning, sequence)):
        if raw_byte != s.decode("hex"):
            print "%s: %s != %s" % (i, pp(raw_byte), s)
            print "a: %s" % pp(beginning)
            print "b: %s" % " ".join(sequence)
            return False

    return True

def skip(s, n):
    assert len(s) >= n
    del s[:n]

def consume(rb, sequence):
    sequence = sequence.split()
    if not startswith(rb, sequence):
        return False
    skip(rb, len(sequence))
    return True

def slurp(rb, n):
    s = ''.join(rb[:n])
    skip(rb, n)
    return s

def pp(rb):
    return " ".join(b.encode("hex") for b in rb)

class Packet(object):
    def __init__(self, raw_bytes):
        rb = list(raw_bytes)

        # ignore the first 66 bytes; they're header info
        skip(rb, 66)
    
        self.records = []
        while rb:
            self.records.append(Record(rb))

    def __str__(self):
        s = ["records:"]
        for i, record in enumerate(self.records):
            s.append("  record %s:" % i)
            s.append("    " + str(record).replace("\n", "\n    "))
        return "\n".join(s)

class Record(object):
    def __init__(self, rb):
        dbg_next_record = pp(rb).find("11 00 55 aa", 1)
        if dbg_next_record == -1:
            print pp(rb)
        else:
            print pp(rb)[:dbg_next_record]

        self.values = {}
        self.channel = ''

        if not consume(rb, "11 00 55 aa"):
            raise Exception("missing header")

        if not consume(rb, "36 00 00 00  03 01 02 01 "
                           "d2 04 00 00  02 00 0a 00 "):
            raise Exception("missing unknown1")

        self.values['A'] = slurp(rb, 2)
        
        if not consume(rb, "00"):
            raise Exception("missing unknown2")

        self.values['B'] = slurp(rb, 7)

        while rb[0] != '\x00':
            self.channel += slurp(rb, 1)
        skip(rb, 1) # skip the final null

        if not consume(rb, "00 00 a0 de bf 5f ff 7f "
                           "00 00 17 46 04 00 01 00 "
                           "00 00 e0 df bf 5f ff 7f "):
            raise Exception("missing unknown2")

    def __str__(self):
        facts = []

        for value in sorted(self.values):
            facts.append("  %s: %s" % (value, pp(self.values[value])))

        if self.channel:
            facts.append("  channel %s" % self.channel)

        return "\n".join(facts)

def start(fname):
    bytes_s = []
    for line in open(fname):
        line = re.sub("   .*", "", line)

        cols = line.split()[1:]

        cols = cols[:16]
        for col in cols:
            bytes_s.append(col)
    packet_bytes = "".join(bytes_s).decode('hex')

    print Packet(packet_bytes)

if __name__ == "__main__":
    start(*sys.argv[1:])

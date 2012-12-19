import sys
import re
import datetime
import struct
from socket import *

HOST='localhost'
PORT=7069

def parsestr(s, n=None):
    assert '\x00' in s
    if n is not None:
        assert len(s) == n
    return s[:s.find('\x00')]

def init_controls():
    control_table = [
        (3000, "master"),
        (1, "master pan"),
        (3005,"aux 3-4"),
        (16,"pan 3-4"),
        (3007,"aux 5-6"),
        (17,"pan 5-6"),
        (3009,"aux 7-8"),
        (17,"pan 7-8"),
        (3013, "A"),
        (3014, "B"),
        (3052, "mute"),
        (62, "phase reverse"),
        (3021, "high pass"),
        (3063, "post"),
        ]
    for control_encoded, control_decoded in control_table:
        control_encode[control_decoded] = control_encoded
        control_decode[control_encoded] = control_decoded
control_encode = {}
control_decode = {}
init_controls()

class VSL1818(object):
    def __init__(self):
        self.connection = None
        self.levels = None
        self.channel_display_names = {}

        # channel_name -> control_name -> value
        self.channels = {}

    def update(self, message_header, message_body):
        unknown1, unknown2, category, unknown3 = struct.unpack("IIHH", message_header)
        assert unknown1 == 0x01020103
        assert unknown2 == 1234
        assert unknown3 == 10
        
        if category == 5:
            self.levels = struct.unpack("128B", message_body)

        elif category == 4:
            unknown4, channel_num, channel_display_name = struct.unpack("HH48s", message_body)
            assert unknown4 == 0
            self.channel_display_names[channel_num] = parsestr(channel_display_name)

        elif category == 2:
            control_raw, value, channel = struct.unpack("=Hd32s", message_body)
            channel = parsestr(channel).split(",")[0]
            if channel.startswith("fx "):
                return
            assert channel.startswith("in")
            channel = int(channel[2:])

            if channel not in self.channels:
                self.channels[channel] = {}
            control = control_decode.get(control_raw, control_raw)
            self.channels[channel][control] = value

        else:
            raise Exception("unknown category %s" % category)

    def update_always(self):
        assert self.connection

        while True:
            signature, l = struct.unpack("II", self.read(8))
            assert signature == 0xaa550011
            v = self.read(l)
            self.update(v[:12], v[12:])

    def dumpstate(self):
        for channel, controls in sorted(self.channels.iteritems()):
            print self.channel_display_names.get(channel, channel)
            for control, value in sorted(controls.iteritems()):
                print " ", control, value

    def read(self, n):
        s = ""
        def remaining():
            return n-len(s)
        while remaining() > 0:
            b = self.connection.recv(remaining())
            s += b
        return s

    def connect(self):
        assert not self.connection

        self.connection = socket(AF_INET, SOCK_STREAM)
        self.connection.connect((HOST, PORT))

        # TODO: send our real mac address
        message = struct.pack("IIHH32s32s",
                              0x01020103,
                              1234,
                              0x0003,
                              10,
                              'C8:BC:C8:1B:9F:0A',
                              'AB1818-VSL')
        self.connection.send(struct.pack("II", 0xaa550011, len(message)))
        self.connection.send(message)

def start(args):
    assert not args
    
    vsl = VSL1818()
    vsl.connect()
    try:
        vsl.update_always()
    except:
        vsl.dumpstate()
        raise

if __name__ == "__main__":
    start(sys.argv[1:])

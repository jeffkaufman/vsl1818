import sys
import re
import datetime
import struct
from socket import *
import wsgiref.simple_server
import wsgiref.util
import threading
import traceback
import time
import json

HOST='localhost'
PORT=7069

def parsestr(s, n=None):
    assert '\x00' in s
    if n is not None:
        assert len(s) == n
    return s[:s.find('\x00')]

control_decode = {
    3000: "master",
    1: "master pan",
    3005: "aux 3-4",
    16: "pan 3-4",
    3007: "aux 5-6",
    17: "pan 5-6",
    3009: "aux 7-8",
    18: "pan 7-8",
    3013: "A",
    3014: "B",
    3052: "mute",
    62: "phase reverse",
    3021: "high pass",
    3063: "post",
    }

class VSL1818(object):
    def __init__(self):
        self.loaded = False
        self.killed = False
        self.connection = None
        self.levels = None
        self.channel_display_names = {}

        # channel -> control -> value
        self.channels = {}

    def update(self, message_header, message_body):
        unknown1, unknown2, category, unknown3 = struct.unpack("IIHH", message_header)
        assert unknown1 == 0x01020103
        assert unknown2 == 1234
        assert unknown3 == 10
        
        if category == 5:
            self.loaded = True # we're not fully loaded until we get some levels
            self.levels = struct.unpack("128B", message_body)

        elif category == 4:
            unknown4, channel_num, channel_display_name = struct.unpack("HH48s", message_body)
            assert unknown4 == 0
            self.channel_display_names[channel_num] = parsestr(channel_display_name)

        elif category == 2:
            control, value, channel = struct.unpack("=Hd32s", message_body)
            channel = parsestr(channel).split(",")[0]
            if channel.startswith("fx "):
                return
            assert channel.startswith("in")
            channel = int(channel[2:])

            if channel not in self.channels:
                self.channels[channel] = {}
            
            if control not in control_decode:
                return # ignoring unknown controls for now

            self.channels[channel][control] = value

        else:
            raise Exception("unknown category %s" % category)

    def update_always(self):
        assert self.connection

        while not self.killed:
            signature, l = struct.unpack("II", self.read(8))
            assert signature == 0xaa550011
            v = self.read(l)
            self.update(v[:12], v[12:])

    def dumpstate(self):
        if not self.loaded:
            return "<p>loading...</p>"

        s = ["<table border=1>"]
        for channel, controls in sorted(self.channels.iteritems()):
            if channel not in self.channel_display_names:
                continue # ignoring unknown channels for now
            display_name = self.channel_display_names[channel]
            s.append("<tr><td rowspan=%s>%s" % (len(controls), display_name))
            for control, value in sorted(controls.iteritems()):
                if not s[-1].startswith("<tr>"):
                    s.append("<tr>")
                s.append("<td>%s<td>%s" % (control_decode[control], value))
        s.append("</table>")
        return "".join(s)

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

def index(vsl):
    s = ["<html>", "<h1>VSL 1818</h1>"]
    for text, target in [["Dump State", "/dump"],
                         ["List Outputs", "/outputs"]]:
        s.append('<a href="%s">%s</a><br>' % (target, text))
    return "".join(s)

def list_outputs(vsl):
    s = ["<html>", "<h1>Available Channels</h1>"]
    for channel in sorted(vsl.channels):
        if channel not in vsl.channel_display_names:
            continue # ignoring unknown channels for now
        display_name = vsl.channel_display_names[channel]
        s.append('<a href="/output/%s">%s</a><br>' % (channel, display_name))
    return "".join(s)

def output(request, vsl):
    (channel_raw,) = request
    channel = int(channel_raw)
    display_name = vsl.channel_display_names[channel]

    s = ["<html>", "<h1>Channel %s</h1>" % display_name]
    s.append("<style>"
             ".barfg{background-color:black;margin:0;padding:0}"
             ".barbg{background-color:#BBB;margin:0;padding:0}"
             "</style>")
    controls = vsl.channels[channel]
    s.append("<dl>")
    for control, value in sorted(controls.iteritems()):
        s.append("<dt>%s" % control_decode[control])
        s.append('<dd>'
                 '<div id="control-bg-%s" class="barbg">'
                 '<div id="control-fg-%s" class="barfg" style="width:%.2f%%"'
                 '>&nbsp;</div></div>' % (control, control, value*100))
    s.append("</dl>")
    s.append("<script>"
             "function click_handler(fg, bg, control, channel) {"
             "  return function(e) {"
             "     var value = e.offsetX/bg.offsetWidth;"
             "     /* todo: send to server via ajax */"
             "     console.debug('channel='+channel+' control=' + control + 'value=' + value);"
             "  }"
             "}"
             "var channel=%s;"
             "var controls=%s;"
             "var i = 0;"
             "for (i = 0 ; i < controls.length ; i++) {"
             "  var bg = document.getElementById('control-bg-' + controls[i]);"
             "  var fg = document.getElementById('control-fg-' + controls[i]);"
             "  bg.onclick = click_handler(fg, bg, controls[i], channel);"
             "}"
             "</script>" % (channel, json.dumps(list(controls))))
    return "".join(s)

def handle_request(request, vsl):
    assert not request[0]
    request = request[1:]

    if not request[0]:
        return index(vsl)
    if request == ['outputs']:
        return list_outputs(vsl)
    if request[0] == "output":
        return output(request[1:], vsl)
    if request == ['dump']:
        return vsl.dumpstate()
    raise Exception("Unknown Request Path: '%s'" % request)

class MockVSL():
    def __init__(self):
        self.loaded = False
        self.killed = False
        self.levels = None
        self.channel_display_names = {1: "main", 2: "aux"}

        # channel_name -> control_name -> value
        self.channels = {1:{}, 2:{}}

    def update_always(self):
        i = 0
        while not self.killed:
            c = float(i % 256)
            
            self.levels = (c, c, 256-c, 256-c)
            self.channels[1][3000] = 0.0
            self.channels[1][3005] = .1
            self.channels[1][3007] = .5
            self.channels[1][3009] = .9
            self.channels[1][1] = 1.0

            time.sleep(1)
            i += 1

    def dumpstate(self):
        return "dumpstate"

def start(args):
    if len(args) == 1 and args[0] == "mock":
        vsl = MockVSL()
    else:
        assert not args

        vsl = VSL1818()
        vsl.connect()

    update_thread = threading.Thread(target=vsl.update_always)
    update_thread.start()

    def vsl_app(environ, start_response):
        try:
            response = handle_request(environ["PATH_INFO"].split("/"), vsl)
            headers = [('Content-type', 'text/html')]
            start_response("200 OK", headers)
            return str(response)
        except Exception:
            tb = traceback.format_exc()
            headers = [('Content-type', 'text/plain')]
            start_response("500 Internal Server Error", headers)
            return tb

    httpd = wsgiref.simple_server.make_server('', 8000, vsl_app)
    print "Serving HTTP on port 8000..."

    try:
        httpd.serve_forever()
    except:
        vsl.killed = True
        raise

if __name__ == "__main__":
    start(sys.argv[1:])

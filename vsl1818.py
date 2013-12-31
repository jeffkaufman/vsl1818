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
import cgi
import urllib2

HOST='localhost'
PORT=7069

def parsestr(s, n=None):
    assert '\x00' in s
    if n is not None:
        assert len(s) == n
    return s[:s.find('\x00')]

control_hierarchy = {
    "master": {
        "gain": 3000,
        "pan": 1,
        },
    "aux 3-4": {
        "gain": 3005,
        "pan": 16,
        },
    "aux 5-6": {
        "gain": 3007,
        "pan": 17,
        },
    "aux 7-8": {
        "gain": 3009,
        "pan": 18,
        },
    "out1": {
        "gain": 100001,
        },
    "out2": {
        "gain": 100002,
        },
    "out3": {
        "gain": 100003,
        },
    "out4": {
        "gain": 100004,
        },
    "out5": {
        "gain": 100005,
        },
    "out6": {
        "gain": 100006,
        },
    "out7": {
        "gain": 100007,
        },
    "out8": {
        "gain": 100008,
        },
    "A": 3013,
    "B": 3014,
    "mute": 3052,
    "filter": {
        "enable": 3080,
        "phase reverse": 62,
        "high pass": 3021,
        },
    "post": 3063,
    "eq": {
        "enable": 3068,
        "low": {
            "enable": 3069,
            "shelve": 3064,
            "gain": 3030,
            "freq": 3022,
            },
        "mid": {
            "enable": 3071,
            "hq": 3066,
            "gain": 3024,
            "freq": 3032,
            },
        "high": {
            "enable": 3072,
            "shelve": 3067,
            "gain": 3025,
            "freq": 3033,
            },
        },
    "compressor": {
        "auto": 3074,
        "limit": 3076,
        "threshold": 3034,
        "ratio": 3035,
        "attack": 3036,
        "release": 3037,
        "makeup gain": 3038,
        },
    "noise gate": {
        "enable": 3079,
        "threshold": 3041,
        },
    }

psuedo_unstereo_controls = {
    control_hierarchy["out1"]["gain"]: ['L', control_hierarchy["master"]["gain"], control_hierarchy["master"]["pan"]],
    control_hierarchy["out2"]["gain"]: ['R', control_hierarchy["master"]["gain"], control_hierarchy["master"]["pan"]],
    control_hierarchy["out3"]["gain"]: ['L', control_hierarchy["aux 3-4"]["gain"], control_hierarchy["aux 3-4"]["pan"]],
    control_hierarchy["out4"]["gain"]: ['R', control_hierarchy["aux 3-4"]["gain"], control_hierarchy["aux 3-4"]["pan"]],
    control_hierarchy["out5"]["gain"]: ['L', control_hierarchy["aux 5-6"]["gain"], control_hierarchy["aux 5-6"]["pan"]],
    control_hierarchy["out6"]["gain"]: ['R', control_hierarchy["aux 5-6"]["gain"], control_hierarchy["aux 5-6"]["pan"]],
    control_hierarchy["out7"]["gain"]: ['L', control_hierarchy["aux 7-8"]["gain"], control_hierarchy["aux 7-8"]["pan"]],
    control_hierarchy["out8"]["gain"]: ['R', control_hierarchy["aux 7-8"]["gain"], control_hierarchy["aux 7-8"]["pan"]],
}

# control_id -> control_name
control_decode = {}
def populate_control_decode(hierarchy=None, path=None):
    if path is None and hierarchy is None:
        path = []
        hierarchy = control_hierarchy
        control_decode.clear()

    for key, value in hierarchy.iteritems():
        child_path = path + [key]
        if type(value) == type({}):
            populate_control_decode(value, child_path)
        else:
            control_decode[value] = " ".join(child_path)
populate_control_decode()

binary_controls = [control_hierarchy["mute"],
                   control_hierarchy["post"],
                   control_hierarchy["filter"]["enable"],
                   control_hierarchy["filter"]["phase reverse"],
                   control_hierarchy["eq"]["enable"],
                   control_hierarchy["eq"]["low"]["enable"],
                   control_hierarchy["eq"]["mid"]["enable"],
                   control_hierarchy["eq"]["high"]["enable"],
                   control_hierarchy["eq"]["low"]["shelve"],
                   control_hierarchy["eq"]["mid"]["hq"],
                   control_hierarchy["eq"]["high"]["shelve"],
                   control_hierarchy["compressor"]["limit"],
                   control_hierarchy["compressor"]["auto"],
                   control_hierarchy["noise gate"]["enable"]]

renameable_controls = [control_hierarchy["master"]["gain"],
                       control_hierarchy["aux 3-4"]["gain"],
                       control_hierarchy["aux 5-6"]["gain"],
                       control_hierarchy["aux 7-8"]["gain"]]
for psuedo_unstereo_control_id in psuedo_unstereo_controls:
    renameable_controls.append(psuedo_unstereo_control_id)


# make something html-safe
def h(s, quote=False):
    return cgi.escape(s, quote=quote)

class VSL1818(object):
    def __init__(self):
        self.loaded = False
        self.killed = False
        self.connection = None
        self.levels = None
        self.channel_names = {} # channel_id -> channel_name
        self.channel_id_strs = {} # channel_id -> channel_id_str
        self.control_names = control_decode

        # channel_id -> control_id -> value
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
            unknown4, channel_id, channel_name = struct.unpack("HH48s", message_body)
            assert unknown4 == 0
            self.channel_names[channel_id] = parsestr(channel_name)

        elif category == 2:
            control_id, value, channel_id_str = struct.unpack("=Hd32s", message_body)
            channel_id_str = parsestr(channel_id_str)
            if channel_id_str.startswith("fx "):
                return
            assert channel_id_str.startswith("in")
            channel_id = int(channel_id_str.split(",")[0][2:])
            if channel_id not in self.channels:
                self.channels[channel_id] = {}
                self.channel_id_strs[channel_id] = channel_id_str

            if control_id not in self.control_names:
                return # ignoring unknown control_ids for now

            self.channels[channel_id][control_id] = value
            update_psuedo_controls(self, channel_id, control_id)

        else:
            raise Exception("unknown category %s" % category)

    def update_always(self):
        assert self.connection

        while not self.killed:
            signature, l = struct.unpack("II", self.read(8))
            assert signature == 0xaa550011
            v = self.read(l)
            self.update(v[:12], v[12:])

    def read(self, n):
        s = ""
        def remaining():
            return n-len(s)
        while remaining() > 0:
            b = self.connection.recv(remaining())
            s += b
        return s

    def sendmsg(self, message):
        self.connection.send(struct.pack("II", 0xaa550011, len(message)))
        self.connection.send(message)

    def send_to_host(self, channel_id, control_id, value):
        assert channel_id in self.channels
        assert control_id in self.channels[channel_id]
        if control_id in binary_controls:
            value = int(value+0.5) # round it
        if value > 1:
            value = 1
        if value < 0:
            value = 0

        header = struct.pack("IIHH",
                             0x01020103,
                             1234,
                             2, # control update
                             10)

        channel_id_str = self.channel_id_strs[channel_id]
        body = struct.pack("=Hd32s", control_id, value, channel_id_str)

        self.sendmsg(header + body)

    def connect(self):
        assert not self.connection

        self.connection = socket(AF_INET, SOCK_STREAM)
        self.connection.connect((HOST, PORT))

        # TODO: send our real mac address
        self.sendmsg(struct.pack("IIHH32s32s",
                                 0x01020103,
                                 1234,
                                 0x0003,
                                 10,
                                 'C8:BC:C8:1B:9F:0A',
                                 'AB1818-VSL'))

def update_psuedo_controls(vsl, channel_id, control_id):
    for psuedo_control_id in psuedo_unstereo_controls:
        direction, control_id_gain, control_id_pan = (
            psuedo_unstereo_controls[psuedo_control_id])

        if control_id in (control_id_gain, control_id_pan):
            gain = vsl.channels[channel_id].get(control_id_gain, 0)
            pan = vsl.channels[channel_id].get(control_id_pan, .5)
            left, right = to_left_right(gain, pan)

            if direction == 'L':
                value = left
            else:
                value = right

            vsl.channels[channel_id][psuedo_control_id] = value

            # keep going: always two to update

def begin(title, back):
    return ["<html>",
            h(title),
            ('<br><a href="%s">back</a>' % back) if back else "",
            "<br><style>body{font-size:200%}</style>"]

def index(vsl):
    s = begin("VSL 1818", back=None)
    for text, target in [["List Controls", "/controls"],
                         ["List Channels", "/channels"]]:
        s.append('<br><a href="%s">%s</a><br>' % (target, text))
    return "".join(s)

# operate_on is channel or control
def list_helper(vsl, operate_on, id_to_names):
    s = begin("Available %ss" % operate_on, "/")
    s.append('<a href="/rename_%ss">change names</a><br>' % operate_on)

    for key, value in sorted(id_to_names.iteritems()):
        s.append('<br><a href="/%s/%s">%s</a><br>' % (operate_on, key, h(value)))
    return "".join(s)

def list_controls(vsl):
    return list_helper(vsl, "control", vsl.control_names)

def list_channels(vsl):
    return list_helper(vsl, "channel", vsl.channel_names)

# operate_on is either 'channels' or 'controls'
def rename_helper(vsl, post_body, operate_on, id_to_names, update_fn):
    if post_body:
        for key_value in post_body.split('&'):
            key, value = key_value.split('=')
            key, value = int(key), urllib2.unquote(value).replace('+', ' ')
            update_fn(key, value)
            id_to_names[key] = value

    s = begin("Rename %s" % operate_on, "/")
    a = s.append
    a('<form action="/rename_%s" method="post">' % operate_on)

    for key in sorted(id_to_names):
        a('<input type="text" name="%s" value="%s"><br>' % (
                key, h(id_to_names[key], quote=True)))
    a('<input type=submit value=update>')
    a('</form>')
    return "".join(s)

def rename_channels(vsl, post_body):
    def update_fn(channel_id, channel_name):
        vsl.channel_names[channel_id] = channel_name
        return vsl.channel_names
    return rename_helper(vsl, post_body, "channels", vsl.channel_names, update_fn)

def rename_controls(vsl, post_body):
    # we only support renaming top-level entries in the hierarchy, and they're identified
    # by the id of one of their child named "gain".
    id_to_names = {}
    for control_id in renameable_controls:
        for control_group_name, control_group_value in control_hierarchy.iteritems():
            if type(control_group_value) != type({}) or "gain" not in control_group_value:
                continue
            if control_group_value["gain"] == control_id:
                id_to_names[control_id] = control_group_name
    assert len(renameable_controls) == len(id_to_names)

    def update_fn(control_id, control_name):
        if control_name in control_hierarchy:
            return # nothing to do; no rename happened

        old_name = id_to_names[control_id]
        control_hierarchy[control_name] = control_hierarchy[old_name]
        del control_hierarchy[old_name]
        populate_control_decode()

    return rename_helper(vsl, post_body, "controls", id_to_names, update_fn)

CLICK_HANDLER=("<script>"
               "function handle_button_press(channel_id, control_id, sign) {"
               "  var fg = document.getElementById('slider-fg-' + channel_id"
               "                                          + '-' + control_id);"
               "  var value = parseFloat(fg.style.width) / 100.0;"
               "  var new_value = value + (sign * 0.02);"
               "  var update_info = channel_id + ' ' + control_id + ' ' + new_value;"
               "  loadAjax('POST', '/update', update_info, function() {"
               "    update_sliders(channel_id + '-' + control_id);"
               "  });"
               "}"
               "</script>")

XML_HTTP_REQUEST = (
    "<script>"
    "function loadAjax(method, request, body, callback) {"
    "  var xr;"
    "  if (window.XMLHttpRequest) {"
    "    /* modern browsers */"
    "    xr = new XMLHttpRequest();"
    "  } else {"
    "    /* IE6, IE5 */"
    "    xr = new ActiveXObject('Microsoft.XMLHTTP');"
    "  }"
    "  xr.onreadystatechange=(function() {"
    "    if (xr.readyState==4 && xr.status==200) {"
    "      callback(xr.responseText);"
    "    }"
    "  });"
    "  xr.open(method, request, true);"
    "  xr.send(body);"
    "}"
    "</script>")

def show_sliders(title, vsl, slider_ids, back):
    s = begin(title, back)

    s.append("<style>"
             "body{margin:0;padding:0}"
             "button{width:49%}"
             ".barfg{background-color:black;margin:0;padding:0}"
             ".barbg{background-color:#BBB;margin:0;padding:0}"
             "</style>")

    for slider_name, channel_id, control_id in slider_ids:
        s.append('<br>%s<br>'
                 '<button id="down-%s-%s" onclick="handle_button_press(%s,%s,-1)">-</button>'
                 '<button id="up-%s-%s" onclick="handle_button_press(%s,%s,+1)">+</button>'
                 '<div id="slider-bg-%s-%s" class="barbg">'
                 '  <div id="slider-fg-%s-%s" class="barfg">'
                 '    &nbsp;</div></div>'
                 % (h(slider_name),
                    channel_id, control_id,
                    channel_id, control_id,
                    channel_id, control_id,
                    channel_id, control_id,
                    channel_id, control_id,
                    channel_id, control_id))
    s.append("</dl>")

    s.append(XML_HTTP_REQUEST)
    s.append(CLICK_HANDLER)
    s.append("<script>"
             "var sliders=%s;" # channel_id, control_id,
             "var i = 0;"
             "for (i = 0 ; i < sliders.length ; i++) {"
             "  var channel_id = sliders[i][0];"
             "  var control_id = sliders[i][1];"
             "}"
             "</script>" %
             json.dumps([(channel_id, control_id)
                         for slider_name, channel_id, control_id in slider_ids]))

    s.append("<script>"
             "function update_sliders(which_sliders) {"
             "  loadAjax('GET', '/sliders?q=' + which_sliders, '', function(response) {"
             "    r = JSON.parse(response);"
             "    var i;"
             "    for (i = 0 ; i < r.length ; i++) {"
             "      var channel_id = r[i][0];"
             "      var control_id = r[i][1];"
             "      var width_percent = r[i][2];"
             "      var fg = document.getElementById('slider-fg-' + channel_id"
             "                                              + '-' + control_id);"
             "      fg.style.width = width_percent;"
             "    }"
             "  });"
             "}"
             "setInterval(function() { update_sliders('%s') }, 1000);"
             "</script>" % ",".join("%s-%s" % (channel_id, control_id)
                                    for slider_name, channel_id, control_id in slider_ids))

    return "\n".join(s)

def show_control(request, vsl):
    (control_raw,) = request
    control_id = int(control_raw)
    control_name = vsl.control_names[control_id]

    sliders = [(vsl.channel_names[channel_id], channel_id, control_id)
               for channel_id, controls in sorted(vsl.channels.items())
               if control_id in controls]
    return show_sliders("Control %s" % control_name, vsl, sliders, "/controls")

def show_channel(request, vsl):
    (channel_id_raw,) = request
    channel_id = int(channel_id_raw)
    channel_name = vsl.channel_names[channel_id]

    controls = vsl.channels[channel_id]
    sliders = [(vsl.control_names[control_id], channel_id, control_id)
               for control_id in sorted(controls)]
    return show_sliders("Channel %s" % channel_name, vsl, sliders, "/channels")

def json_sliders(query_string, vsl):
    assert query_string.startswith("q=")
    request = query_string.replace("q=", "")

    s = []
    for slider in request.split(","):
        channel_id_s, control_id_s = slider.split("-", 1)
        channel_id, control_id = int(channel_id_s), int(control_id_s)
        s.append((channel_id, control_id, '%.2f%%' % (vsl.channels[channel_id][control_id]*100)))
    return json.dumps(s)

translated_full_sweep = []
with open("translated_full_sweep.csv") as inf:
    for line in inf:
        pan, gain, left, right = line.split(",")

        if pan == "pan":
            continue

        pan, gain = int(pan) / 100.0, int(gain) / 100.0
        left, right = float(left), float(right)

        translated_full_sweep.append((pan, gain, left, right))

def sqdiff(x,y):
    return (x-y)*(x-y)

# These lookups are brute force nearest-neighbor using data in translated_full_sweep.csv.
# They're embarassingly slow (20ms on my machine) because they consider all 10k points.
# While there are ways to speed this up (quadtree, dropping less informative points),
# these functions are only called as often as there are updates to the underlying auxes,
# which is rarely.

def to_left_right(gain_real, pan_real):
    closest_index = None
    closest_distance = None
    for index, (pan, gain, left, right) in enumerate(translated_full_sweep):
        distance = sqdiff(gain_real, gain) + sqdiff(pan_real, pan)
        if closest_distance is None or distance < closest_distance:
            closest_distance = distance
            closest_index = index
    _, _, closest_left, closest_right = translated_full_sweep[closest_index]
    return closest_left, closest_right

def to_gain_pan(left_real, right_real):
    closest_index = None
    closest_distance = None
    for index, (pan, gain, left, right) in enumerate(translated_full_sweep):
        distance = sqdiff(left_real, left) + sqdiff(right_real, right)
        if closest_distance is None or distance < closest_distance:
            closest_distance = distance
            closest_index = index
    closest_pan, closest_gain, _, _, = translated_full_sweep[closest_index]
    return closest_gain, closest_pan

def process_update(post_body, vsl):
    channel_id_s, control_id_s, value_s = post_body.split()
    channel_id = int(channel_id_s)
    control_id = int(control_id_s)
    value = float(value_s)

    if control_id in psuedo_unstereo_controls:
        direction, control_id_gain, control_id_pan = psuedo_unstereo_controls[control_id]
        old_gain = vsl.channels[channel_id][control_id_gain]
        old_pan = vsl.channels[channel_id][control_id_pan]

        current_left, current_right = to_left_right(old_gain, old_pan)

        if direction == 'L':
            current_left = value
        elif direction == 'R':
            current_right = value
        else:
            assert False

        new_gain, new_pan = to_gain_pan(current_left, current_right)
        vsl.send_to_host(channel_id, control_id_gain, new_gain)
        vsl.send_to_host(channel_id, control_id_pan, new_pan)
    else:
        assert control_id >= 0
        vsl.send_to_host(channel_id, control_id, value)

def handle_request(request, query_string, post_body, vsl):
    assert not request[0]
    request = request[1:]

    if not request[0]:
        return index(vsl)
    if request == ['rename_channels']:
        return rename_channels(vsl, post_body)
    if request == ['rename_controls']:
        return rename_controls(vsl, post_body)
    if request == ['channels']:
        return list_channels(vsl)
    if request[0] == "channel":
        return show_channel(request[1:], vsl)
    if request == ['controls']:
        return list_controls(vsl)
    if request[0] == "control":
        return show_control(request[1:], vsl)
    if request == ["update"]:
        process_update(post_body, vsl)
        return ""
    if request == ["sliders"]:
        return "application/json", json_sliders(query_string, vsl)
    raise Exception("Unknown Request Path: '%s'" % request)

class MockVSL():
    def __init__(self):
        self.loaded = False
        self.killed = False
        self.levels = None
        self.control_names = control_decode

        self.channel_names = {}
        self.channels = {}
        self.channel_id_strs = {}
        for i in range(20):
            self.channel_names[i] = "in %s" % i
            self.channels[i] = {}
            self.channel_id_strs[i] = "in%s,0,2" % i

    def send_to_host(self, channel_id, control_id, value):
        self.channels[channel_id][control_id] = value
        update_psuedo_controls(self, channel_id, control_id)

    def update_always(self):
        i = 0

        for i in range(20):
            self.send_to_host(i, 3000, .22)

        self.send_to_host(2, 3000, .1)
        self.send_to_host(2, 3005, .2)
        self.send_to_host(2, 3007, .3)
        self.send_to_host(2, 3009, .4)
        self.send_to_host(2, 1, .5)

        while not self.killed:
            c = float(i % 256)
            q = c/256

            self.levels = (c, c, 256-c, 256-c)
            self.send_to_host(1, 3000, .3*q)
            self.send_to_host(1, 3005, .1*q)
            self.send_to_host(1, 3007, .5*q)
            self.send_to_host(1, 3009, .9*q)
            self.send_to_host(1, 1, 1.0*q)

            time.sleep(.1)
            i += 1

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
        post_body = None
        if environ["REQUEST_METHOD"] == "POST":
            post_body = environ["wsgi.input"].read(int(environ["CONTENT_LENGTH"]))
        try:
            response = handle_request(
                environ["PATH_INFO"].split("/"),
                environ["QUERY_STRING"],
                post_body,
                vsl)
            if type(response) == type(""):
                content_type = 'text/html'
            else:
                content_type, response = response
            headers = [('Content-type', content_type)]
            start_response("200 OK", headers)
            return response
        except Exception:
            tb = traceback.format_exc()
            headers = [('Content-type', 'text/plain')]
            start_response("500 Internal Server Error", headers)
            return tb

    httpd = wsgiref.simple_server.make_server('', 8000, vsl_app)
    print "In your browser load http://localhost:8000"

    try:
        httpd.serve_forever()
    except:
        vsl.killed = True
        raise

if __name__ == "__main__":
    start(sys.argv[1:])

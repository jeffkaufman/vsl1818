# Scratch functions, used in preparing translated_full_sweep.csv and figuring out what
# to_left_right, to_gain_pan, etc should look like.

def to_int(n):
    assert n.startswith("0.") and n.endswith("00")
    return int(n[2:-2])

full_sweep = []
with open("full_sweep__p_g_l_r_uniqd.log") as inf:
    for line in inf:
        line = line.strip()
        count, pan, gain, left, right = line.split()

        pan = to_int(pan)
        gain = to_int(gain)
        #pan = float(pan)
        #gain = float(gain)

        left = int(left)
        right = int(right)

        full_sweep.append((pan, gain, left, right))

        if pan < 50:
            full_sweep.append((100-pan, gain, right, left))

full_sweep.sort()

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

level_to_gain = []
i = 0
with open("level_to_gain.txt") as inf:
    for line in inf:
        level, gain = line.strip().split()
        level, gain = int(level), float(gain)

        assert level == i
        level_to_gain.append(gain)

        i += 1

isos = {}
for pan, gain, left, right in full_sweep:
    #print pan, gain, left, right

    if left not in isos:
        isos[left] = {}
    isos[left][right] = (pan, gain)

pans = {}
for pan, gain, left, right in full_sweep:
    if pan not in pans:
        pans[pan] = {}
    pans[pan][gain] = (left, right)

if False:
    for right, (pan, gain) in isos[200].iteritems():
        print "%s: p=%d, g=%d" % (right, pan, gain)
if False:
    print "left, min_right, max_right"
    for iso in isos:
        min_right = min(isos[iso])
        min_p, min_g = isos[iso][min_right]

        max_right = max(isos[iso])
        max_p, max_g = isos[iso][max_right]

        print "%s, %s (%s, %s), %s (%s, %s)" % (
            iso, min_right, min_p, min_g, max_right, max_p, max_g)

def predict_quantized_level(gain_base, level_base, gain_real):
    level_predicted = predict_level(gain_base, level_base, gain_real)
    for step in [0, 24, 50, 65, 75, 84, 90, 96, 101, 105, 109, 113, 116, 119, 122]:
        if level_predicted < step:
            return step
    return int(level_predicted)

# slope is in level iunits per gain unit
# at gain=50 and above we have one constant slope
#   99 -> 239, 50 -> 149
#   slope = (239 - 149) / (99-50) = 1.84
HIGH_SLOPE=1.84
# at gain below 50 we have another constant slope
#   50 -> 149, 42 -> 116
#   slope = (149 - 116) / (50 - 42) = 4.13
LOW_SLOPE=4.13

def predict_level(gain_base, level_base, gain_real):
    if level_base == 0:
        return 0

    if gain_real >= 50:
        return (gain_real - gain_base) * HIGH_SLOPE + level_base
    else:
        gain_50 = 50
        level_50 = predict_level(gain_base, level_base, gain_50)

        return (gain_real - gain_50) * LOW_SLOPE + level_50

def predict_gain(gain_base, level_base, level_real):
    gain_50 = 50
    level_50 = predict_level(gain_base, level_base, gain_50)

    if level_real >= level_50:
        return (level_real - level_base) / HIGH_SLOPE + gain_base
    else:
        return (level_real - level_50) / LOW_SLOPE + gain_50


def predict_and_eval(gain_base, level_base, gain_real, level_real, error_gain, error_level):
    level_predicted = predict_quantized_level(gain_base, level_base, gain_real)
    gain_predicted = int(predict_gain(gain_base, level_base, level_real))

    gain_error = gain_real - gain_predicted
    gain_error *= gain_error

    level_error = level_real - level_predicted
    level_error *= level_error

    error_level[0] += 1
    error_level[1] += level_error

    error_gain[0] += 1
    error_gain[1] += gain_error

    #print "%s, %s, %s" % (gain_real, level_real, level_predicted)
    print "%s, %s, %s" % (level_real, gain_real, gain_predicted)
    #print "%s l(%s)=%s, l(%s)=%s, l_p(%s)=%s" % (
    #   error_term, gain_base, level_base, gain_real, level_real, gain_real, level_predicted)

if False:
    # what is the relationship between gain and level?
    # predict it all from knowing level(gain=1)
    for pan in pans:
        pan=4

        gains = pans[pan]
        gain_base = 99
        level_base_left, level_base_right = gains[99]


        error_gain = [
            0, # count
            0, # sum squared error
            ]
        error_level = [
            0, # count
            0, # sum squared error
            ]

        for gain_real, (left_real, right_real) in gains.iteritems():
            for level_base, level_real in [
                # (level_base_left, left_real),
                (level_base_right, right_real),
                ]:

                predict_and_eval(gain_base, level_base, gain_real, level_real, error_gain, error_level)

        break



if False:
    for iso in isos:
        with open("iso-%s.csv" % iso, "w") as outf:
            outf.write("right, pan, gain\n")
            for right, (pan, gain) in sorted(isos[iso].iteritems()):
                outf.write("%s, %s, %s\n" % (right, pan, gain))


if False:
    with open("clean_full_sweep.csv", "w") as outf:
        outf.write("pan, gain, left, right\n")
        for pan, gain, left, right in full_sweep:
            outf.write("%s, %s, %s, %s\n" % (pan, gain, left, right))

if False:
    with open("level_to_gain.txt", "w") as outf:
        for i in range(240):
            gain = predict_gain(100, 239, i)/100
            if i == 0:
                gain = 0
            outf.write("%s %.3f\n" % (i, gain))

if False:
    with open("translated_full_sweep.csv", "w") as outf:
        outf.write("pan, gain, left, right\n")
        for pan, gain, left, right in full_sweep:
            outf.write("%s, %s, %s, %s\n" % (
                    pan, gain, level_to_gain[left], level_to_gain[right]))

if False:
    for pan, gain, left, right in translated_full_sweep:

        predicted_gain, predicted_pan = to_gain_pan(left, right)
        predicted_left, predicted_right = to_left_right(gain, pan)

        error = (sqdiff(predicted_pan, pan) +
                 sqdiff(predicted_gain, gain) +
                 sqdiff(predicted_left, left) +
                 sqdiff(predicted_right, right))

        print "%s: p=%.2f->%.2f ; g=%.2f->%.2f ; l=%.2f->%.2f ; r=%.2f->%.2f" % (
            error,
            pan, predicted_pan, gain, predicted_gain,
            left, predicted_left, right, predicted_right)

if True:
    for pan, gain, left, right in translated_full_sweep:
        predicted_gain, predicted_pan = to_gain_pan(left, right)
        predicted_gain_2, predicted_pan_2 = to_gain_pan(right, left)
        predicted_pan_2 = 1-predicted_pan_2

        error = (sqdiff(predicted_gain, predicted_gain_2) +
                 sqdiff(predicted_pan, predicted_pan_2))

        print "%s: p=%.2f->%.2f ; g=%.2f->%.2f" % (
            error, predicted_pan, predicted_pan_2, predicted_gain, predicted_gain_2)

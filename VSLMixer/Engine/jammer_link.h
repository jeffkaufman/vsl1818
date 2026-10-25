// Jammer (~/code/jammer) playing into inputs 1 and 2.
//
// When its audio output is the AudioBox, Jammer opens it on the box's clock
// but writes silence to the jacks, and puts its left and right into this
// ring in shared memory instead.  The engine reads the ring a little behind
// Jammer's writes and uses it in place of inputs 1 and 2, so Jammer gets the
// same EQ, compression and sends as anything plugged in there.  Jammer reads
// the box's real inputs 1 and 2 itself.
//
// The same layout is in jammer's vsllink.h; change both together, and bump
// JL_MAGIC.

#pragma once
#include <stdatomic.h>
#include <stdint.h>

// The sandbox only allows shared memory named under an application group
// (see project.yml), and shm_open names are at most 31 characters.
#define JL_NAME "C58DMTY76R.jefftk.audio/link"
#define JL_MAGIC 0x4a4d4c31u   // "JML1"
#define JL_FRAMES 4096u        // power of two

typedef struct {
    _Atomic uint32_t magic;
    _Atomic uint32_t block;        // frames in Jammer's latest write
    _Atomic uint64_t write_pos;    // frames written, ever
    _Atomic uint64_t heartbeat;    // mach_absolute_time() of the latest write
    float audio[JL_FRAMES][2];
} jammer_link;

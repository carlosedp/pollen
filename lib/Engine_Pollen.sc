// Engine_Pollen: the sound of pollen, a live granular reel.
// Copyright (C) 2026 Voltage Foundry Modular (vfmod.com). GPL-3.0, see LICENSE.
//
//   input (norns in: the ADC, later the radio) -> writer -> the reel (2 mono buffers, a loop)
//   reel -> grains (2x GrainBuf, read back from the write head) -> wet, and back into the writer
//   dry + wet -> out: filter, drive, media, reverb send, static, a limiter -> norns out
//
// The Lua side owns every mapping from macros to parameters (lib/sound.lua); this engine
// only exposes raw parameters. All three synths live in one group, so one command sets a
// parameter on whichever of them has it:
//
//   set(key, value)   writer:  adc, freeze, fb
//                     grains:  density, jitter, size, position (s back from the write head),
//                              pos_spread (0..1 of the reel), pitch, pitch_spread (semitones),
//                              reverse (0..1 chance), spread (stereo), env (0 bell, 1 pluck,
//                              2 block), amp, freeze
//                     out:     mix, level, ftype (0 off, 1 LP, 2 HP, 3 BP), cutoff, res, drive,
//                              media (0 digital, 1 vintage digital, 2 clean tape, 3 dirty tape),
//                              send (reverb), vsize, vfreeze, static
//   reel(seconds)     a new, empty reel of that length (the grains loop over all of it)
//   clear()           silence the reel
//
// Polls: amp_in (the input's level, to tell a dead stream) and head (the write head, in s).
//
// MiVerb (mi-UGens) is the reverb when installed, looked up by name at runtime: a missing
// class must never be written in this file (it would fail SuperCollider for every script).
// Without it, FreeVerb2. The media stage follows Beads' four (after Emilie Gillet's Beads,
// MIT); see doc/DESIGN.md.

Engine_Pollen : CroneEngine {
	var group, bufs, envBufs, headBus, ampBus, dryBus, wetBus, fbBus;
	var writer, grains, outSynth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;
		var verb = \MiVerb.asClass;

		headBus = Bus.control(s, 1);
		ampBus = Bus.control(s, 1);
		dryBus = Bus.audio(s, 2);
		wetBus = Bus.audio(s, 2);
		fbBus = Bus.audio(s, 2);
		bufs = this.newReel(15);
		// grain envelopes: 0 = GrainBuf's own Hann (-1), 1 = a pluck, 2 = a block with soft edges
		envBufs = [
			Buffer.sendCollection(s, Env.perc(0.04, 0.96, 1, -4).discretize(1024)),
			Buffer.sendCollection(s, Env.linen(0.03, 0.94, 0.03, 1, \sin).discretize(1024)),
		];
		this.buildDefs(verb);
		s.sync;

		group = Group.new(context.xg);
		writer = Synth(\pollen_writer, [\inL, context.in_b[0].index, \inR, context.in_b[1].index,
			\bufL, bufs[0], \bufR, bufs[1], \headBus, headBus, \ampBus, ampBus,
			\dryBus, dryBus, \fbBus, fbBus], group);
		grains = Synth.after(writer, \pollen_grains, [\bufL, bufs[0], \bufR, bufs[1], \headBus, headBus,
			\out, wetBus, \fbBus, fbBus, \penv, envBufs[0], \benv, envBufs[1]]);
		outSynth = Synth.after(grains, \pollen_out, [\dryBus, dryBus, \wetBus, wetBus,
			\out, context.out_b.index]);

		this.addCommands;
		this.addPoll(\amp_in, { ampBus.getSynchronous });
		this.addPoll(\head, { headBus.getSynchronous / context.server.sampleRate });
	}

	newReel { |seconds|
		var s = context.server, frames = (seconds.clip(1, 60) * s.sampleRate).asInteger;
		^[Buffer.alloc(s, frames, 1), Buffer.alloc(s, frames, 1)]
	}

	buildDefs { |verb|
		// the writer: a loop the length of the reel. Frozen, the head stops and writes back
		// what is there (no change). The grains come back in through fb, and what's written is
		// soft-clipped (linear below 0.5), so cross-pollination can't pile up past full scale.
		SynthDef(\pollen_writer, { |inL, inR, bufL, bufR, headBus, ampBus, dryBus, fbBus,
			adc = 1, freeze = 0, fb = 0|
			var run = freeze < 0.5;
			var head = Phasor.ar(0, run, 0, BufFrames.kr(bufL));
			var in = [In.ar(inL), In.ar(inR)] * adc.lag(0.1);
			var back = HPF.ar(InFeedback.ar(fbBus, 2), 40) * fb.lag(0.2);
			var old = [BufRd.ar(1, bufL, head, 1, 1), BufRd.ar(1, bufR, head, 1, 1)];
			var w = Select.ar(run, [old, (in + back).softclip]);
			BufWr.ar(w[0], bufL, head);
			BufWr.ar(w[1], bufR, head);
			Out.kr(headBus, A2K.kr(head));
			Out.kr(ampBus, Amplitude.kr(in.sum * 0.5, 0.05, 0.5));
			Out.ar(dryBus, in);
		}).add;

		// the grains: each one starts `position` seconds behind the write head (plus a
		// random part of the reel), with its own pitch, direction and place in the stereo field.
		// A forward grain faster than the head starts far enough back not to overtake it.
		SynthDef(\pollen_grains, { |bufL, bufR, headBus, out, fbBus, penv, benv,
			density = 8, jitter = 0.3, size = 0.15, position = 0.5, pos_spread = 0.05,
			pitch = 0, pitch_spread = 0, reverse = 0, spread = 0.5, env = 0, amp = 0.5, freeze = 0|
			var sr = BufSampleRate.kr(bufL), frames = BufFrames.kr(bufL), len = frames / sr;
			var dur = size.clip(0.005, 4);
			var dens = density.clip(0.1, 200).min(28 / dur); // at most ~28 grains at once (32 voices)
			var trig = CoinGate.ar(1 - jitter, Impulse.ar(dens)) + CoinGate.ar(jitter, Dust.ar(dens));
			var rPos = TRand.ar(0, 1, trig), rPitch = TRand.ar(-1, 1, trig);
			var rDir = TRand.ar(0, 1, trig), rPan = TRand.ar(-1, 1, trig);
			var dir = 1 - (2 * (rDir < reverse));
			var rate = (pitch + (pitch_spread * rPitch)).midiratio * dir;
			var run = freeze < 0.5;
			var minAge = ((rate.max(0) - run).max(0) * dur) + 0.005;
			var age = (position + (pos_spread * len * rPos)).max(minAge);
			var pos = ((In.kr(headBus) - (age * sr)).wrap(0, frames)) / frames;
			var envbuf = Select.kr(env, [-1, penv, benv]);
			var l = GrainBuf.ar(1, trig, dur, bufL, rate, pos, 2, 0, envbuf, 32);
			var r = GrainBuf.ar(1, trig, dur, bufR, rate, pos, 2, 0, envbuf, 32);
			var sig = Balance2.ar(l, r, rPan * spread.lag(0.1)) * amp.lag(0.1);
			Out.ar(out, sig);
			Out.ar(fbBus, sig);
		}).add;

		// the output: the grains through filter, drive and media; the reverb on the grains;
		// the dry input mixed in; and the static between stations on top
		SynthDef(\pollen_out, { |dryBus, wetBus, out, mix = 0.7, level = 1, ftype = 0, cutoff = 2000,
			res = 0.2, drive = 0, media = 0, send = 0.3, vsize = 0.6, vfreeze = 0, static = 0|
			var dry = In.ar(dryBus, 2), wet = In.ar(wetBus, 2);
			var f = cutoff.lag(0.1).clip(20, 20000), rq = (1 - res.clip(0, 0.95)).lag(0.1);
			var g = 1 + (drive.lag(0.1) * 8);
			var wow, rv, st;
			wet = Select.ar(ftype, [wet, RLPF.ar(wet, f, rq), RHPF.ar(wet, f, rq), BPF.ar(wet, f, rq)]);
			wet = (wet * g).tanh / g.tanh;
			// media, after Beads: digital (clean); vintage digital (24 kHz, 12 bits);
			// clean tape (wow, flutter, warmth); dirty tape (more of it, hiss, a rolled-off top).
			// The tapes saturate at unity for quiet signals, so switching media keeps the level
			wow = { |depth| 0.012 + (LFNoise2.kr(0.5) * 0.002 * depth) + (SinOsc.kr(6.3) * 0.0002 * depth) };
			wet = Select.ar(media, [
				wet,
				(Latch.ar(wet, Impulse.ar(24000)) * 2048).round / 2048,
				(DelayC.ar(wet, 0.05, wow.(1)) * 1.4).tanh / 1.4,
				LPF.ar((DelayC.ar(wet, 0.05, wow.(3)) * 2.2).tanh / 2.2, 7000) + (PinkNoise.ar(0.006) ! 2),
			]);
			rv = if (verb.notNil) {
				verb.ar(wet * send.lag(0.1), vsize.lag(0.2), 1, 0.5, 0.05, vfreeze, 0.7)
			} {
				FreeVerb2.ar(wet[0] * send.lag(0.1), wet[1] * send.lag(0.1), 1,
					(vsize + vfreeze).clip(0, 1), 0.5 * (1 - vfreeze))
			};
			// the sky between stations: hiss, crackle, a whistling carrier drifting past
			st = (PinkNoise.ar(0.3) + (Dust.ar(40) * 0.5)
				+ (BPF.ar(WhiteNoise.ar, LFNoise1.kr(0.7).exprange(400, 4000), 0.1) * 2)
				+ (SinOsc.ar(LFNoise1.kr(0.3).exprange(700, 3000)) * 0.04)) * static.lag(0.05);
			// last, a safety limiter: grains summing in phase (heavy cross-pollination) stay under full scale
			Out.ar(out, Limiter.ar(((dry * (1 - mix.lag(0.1))) + (wet * mix.lag(0.1)) + rv + (st ! 2)) * level.lag(0.1), 0.95, 0.01));
		}).add;
	}

	addCommands {
		this.addCommand(\set, "sf", { |msg|
			var key = msg[1].asSymbol, value = msg[2];
			group !? { group.set(key, value) };
		});
		this.addCommand(\reel, "f", { |msg| this.setReel(msg[1]) });
		this.addCommand(\clear, "", { bufs.do(_.zero) });
	}

	// a new reel: allocate, wait for the server, hand it to the writer and the grains, then
	// free the old one
	setReel { |seconds|
		var old = bufs, s = context.server;
		Routine {
			bufs = this.newReel(seconds);
			s.sync;
			writer.set(\bufL, bufs[0], \bufR, bufs[1]);
			grains.set(\bufL, bufs[0], \bufR, bufs[1]);
			s.sync;
			old.do(_.free);
		}.play;
	}

	free {
		group !? { group.free };
		bufs.do(_.free);
		envBufs.do(_.free);
		[headBus, ampBus, dryBus, wetBus, fbBus].do { |b| b !? { b.free } };
	}
}

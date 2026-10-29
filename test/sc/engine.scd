// The engine on a real scsynth (no sound card: jackd's dummy driver), behind test/sc's
// stand-in CroneEngine: a tone into its input, its output recorded and measured, through the
// same checks as test/engine.mjs runs on the browser's engine. Run by test/sc/run.sh.
(
var s = Server.local, fails = List.new;
s.options.sampleRate = 48000;
s.options.numInputBusChannels = 2;
s.options.numOutputBusChannels = 2;
s.options.memSize = 65536;

Routine {
	var ctx, eng, tone, measure, check, cond = Condition.new, sr = 48000;
	s.bootSync(cond);
	ctx = (server: s, xg: Group.new(s), in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
	Engine_Pollen.new(ctx, { |e| eng = e; cond.unhang });
	cond.hang;
	s.sync;
	"engine allocated".postln;

	// a chord of sines into the engine's input, before its group; on (0/1) switches it
	tone = { |on = 1|
		var x = (SinOsc.ar(220) + SinOsc.ar(330)) * 0.2 * on;
		Out.ar(ctx.in_b[0].index, x);
		Out.ar(ctx.in_b[1].index, x);
	}.play(ctx.xg, addAction: \addBefore);

	// record the engine's output for a while, after its group; -> [rms, peak]
	measure = { |seconds|
		var buf = Buffer.alloc(s, (seconds * sr).asInteger, 2), rec, data, sum = 0, peak = 0;
		s.sync;
		rec = { RecordBuf.ar(In.ar(ctx.out_b.index, 2), buf, loop: 0, doneAction: 2); 0 }.play(ctx.xg, addAction: \addAfter);
		(seconds + 0.1).wait;
		buf.loadToFloatArray(action: { |a| data = a });
		while { data.isNil } { 0.05.wait };
		buf.free;
		data.do { |v|
			if (v.isNaN or: { v.abs == inf }) { peak = inf };
			sum = sum + (v * v); peak = max(peak, v.abs);
		};
		[(sum / data.size).sqrt, peak]
	};
	check = { |label, ok, r|
		"% % rms %  peak %".format(if (ok) { "ok  " } { "FAIL" }, label.padRight(44),
			r[0].round(0.0001), r[1].round(0.001)).postln;
		if (ok.not) { fails.add(label) };
	};
	~r = nil;

	eng.cmd(\reel, 8); 0.5.wait;
	~r = measure.(3);
	check.("grains and input, the defaults", (~r[0] > 0.01) and: { ~r[1] < 1 }, ~r);

	eng.cmd(\set, \mix, 1);
	~r = measure.(2);
	check.("grains alone", ~r[0] > 0.01, ~r);

	eng.cmd(\set, \freeze, 1); tone.set(\on, 0);
	~r = measure.(3);
	check.("pressed, input gone: the reel still plays", ~r[0] > 0.01, ~r);
	eng.cmd(\set, \freeze, 0);
	7.wait;
	~r = measure.(2);
	check.("released, input gone: it fades to silence", ~r[0] < 0.002, ~r);
	tone.set(\on, 1); 3.wait;

	[[\media, 1, "vintage digital"], [\media, 2, "clean tape"], [\media, 3, "dirty tape"],
		[\ftype, 1, "low-pass"], [\ftype, 2, "high-pass"], [\ftype, 3, "band-pass"]].do { |c|
		eng.cmd(\set, c[0], c[1]); if (c[0] == \ftype) { eng.cmd(\set, \cutoff, 800) };
		~r = measure.(1.5);
		check.(c[2], (~r[0] > 0.003) and: { ~r[1] < 1 }, ~r);
	};
	eng.cmd(\set, \media, 0); eng.cmd(\set, \ftype, 0);

	eng.cmd(\set, \fb, 0.85); eng.cmd(\set, \density, 40); eng.cmd(\set, \size, 1.5);
	eng.cmd(\set, \pitch, 7); eng.cmd(\set, \pitch_spread, 5);
	~r = measure.(6);
	check.("cross-pollination at its most: the limiter holds", ~r[1] <= 0.97, ~r);
	[[\fb, 0], [\density, 8], [\size, 0.15], [\pitch, 0], [\pitch_spread, 0]].do { |c| eng.cmd(\set, *c) };

	eng.cmd(\set, \reverse, 1);
	~r = measure.(1.5);
	check.("all grains backwards", ~r[0] > 0.005, ~r);
	eng.cmd(\set, \reverse, 0);

	eng.cmd(\set, \mix, 0); tone.set(\on, 0); eng.cmd(\set, \static, 1); 0.3.wait;
	~r = measure.(1.5);
	check.("static alone", (~r[0] > 0.01) and: { ~r[1] < 1 }, ~r);
	eng.cmd(\set, \static, 0);

	eng.cmd(\reel, 30); tone.set(\on, 1); eng.cmd(\set, \mix, 1); 0.5.wait;
	~r = measure.(2);
	check.("a new 30 s reel catches again", ~r[0] > 0.005, ~r);
	eng.cmd(\clear); tone.set(\on, 0); 2.wait; // the reverb's tail dies away
	~r = measure.(1);
	check.("cleared, input gone: silence", ~r[0] < 0.002, ~r);

	[\amp_in, \head].do { |p|
		var v = eng.polls[p].value;
		check.("poll " ++ p ++ " is a number", v.isNumber and: { v.isNaN.not }, [v ? 0, 0]);
	};

	eng.free;
	if (fails.size > 0) { "% failed".format(fails.size).postln; 1.exit } { "all ok".postln; 0.exit };
}.play(AppClock);
)

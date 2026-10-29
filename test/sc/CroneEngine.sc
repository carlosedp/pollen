// A stand-in for norns' CroneEngine, for test/sc/engine.scd: the same construction (alloc in a
// routine, then the done callback), commands and polls kept in tables the test can call.
CroneEngine {
	var <context, <commands, <polls;

	*new { |context, doneCallback| ^super.new.initCrone(context, doneCallback) }

	initCrone { |argContext, doneCallback|
		context = argContext;
		commands = IdentityDictionary.new;
		polls = IdentityDictionary.new;
		Routine {
			this.alloc;
			doneCallback.value(this);
		}.play;
	}

	addCommand { |name, format, func| commands[name.asSymbol] = func }
	addPoll { |name, func| polls[name.asSymbol] = func }

	// as an OSC message from Lua would arrive: [path, args...]
	cmd { |name ...args| commands[name].value([name] ++ args) }
}

package lm;

#if macro
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.Context;
import haxe.macro.Expr.Position;
import lm.Charset;
import lm.LexEngine;
import lm.LexEngine.INVALID;

using haxe.macro.Tools;

typedef Udt = {    // user defined token
	t: Bool,       // terminal or not
	name: String,  // ident
	value: Int,    // must be `enum abstract (Int)`
	cset: Charset, // CSet.single(value)
	pos: Position, // haxe.macro.Position
}

typedef Symbol = { // from switch cases
	t: Bool,
	name: String,  // ident name
	cset: Charset,
	ex: String,    // extract name. CStr(s)| then ex = "s" for terminal   | e = expr then ex = "e" for non-terminal
	pos: Position,
}

typedef SymSwitch = {
	name: String,        // Associated var name
	value: Int,          // Automatic growth
	ct: ComplexType,     // Type of siwtch
	cases: Array<Case>,
	pos: Position,
}

typedef SymbolSet = {
	expr: Expr,
	syms: Array<Symbol>,
}

typedef Lhs = {    // one switch == one Lhs
	name: String,  // associated var name(non-terminals name)
	value: Int,    // automatic increase from "maxValue"
	ct: ComplexType,
	epsilon: Bool, // if have switch "default:" or "case []:"
	cases: Array<SymbolSet>,
	pos: Position,
}

typedef LhsArray = Array<Lhs>;   // all switches.

class LR0Builder {

	var termls: Array<Udt>;      // all Terminal
	var termlsC_All: Charset;    // Terminal Universal Set.
	var udtMap: Map<String,Udt>; // User Defined Terminal + Non-Terminal
	var maxValue: Int;           // if value >= maxValue then it must be a non-terminal
	var lhsA: LhsArray;
	var lhsMap: Map<String,Lhs>;
	var sEof: String;            // by @:rule from Lexer
	var funMap: Map<String, {name: String, ct: ComplexType}>; //  TokenName => FunctionName

	public function new(tk, es) {
		maxValue = 0;
		termls = [];
		termlsC_All = [];
		lhsA = [];
		udtMap = new Map();
		lhsMap = new Map();
		funMap = new Map();
		sEof = es;
		parseToken(tk);
	}

	function parseToken(tk: Type) {
		switch (tk) {
		case TAbstract(_.get() => ab, _):
			for (field in ab.impl.get().statics.get()) {
				for (meta in field.meta.get()) {
					if (meta.name != ":value") continue;
					switch(meta.params[0].expr) {
					case ECast({expr: EConst(CInt(i))}, _):
						var n = Std.parseInt(i);
						if (n < 0 || n > 126) // TODO:
							Context.error("Value should be [0-126]", field.pos);
						if (n > maxValue) maxValue = n;
						firstCharChecking(field.name, UPPER, field.pos);
						var t = {t: true, name: field.name, value: n, cset: CSet.single(n), pos: field.pos};
						termls.push(t);
						udtMap.set(t.name, t);
						if (t.name != this.sEof)
							termlsC_All = CSet.union(termlsC_All, t.cset);
					case _:
					}
				}
			}
		case _:
		}
		if (udtMap.get(this.sEof) == null) throw "Invalid EOF value: " + this.sEof; //
		++ maxValue;
	}

	function getTermlCSet(name: String) {
		if (name == "_") return termlsC_All;
		var t = udtMap.get(name);
		if (t != null) {
			return t.t ? t.cset : null; // Non-Termls if .t == false
		}
		if (name.length >= 2) {         // if name == "Op" then OpPlus, OpMinus, OpXxxx ....
			var cset = [];
			for (t in termls)
				if (StringTools.startsWith(t.name, name))
					cset = CSet.union(cset, t.cset);
			// to prevent abuse
			if (cset.length > 1 || (cset.length > 0 && (cset[0].max > cset[0].min)))
				return cset;
		}
		return null;
	}

	function getNonTermlCSet(name: String) {
		var t = udtMap.get(name);
		return t == null || t.t ? null : t.cset;
	}

	function indexCase(i: Int): SymbolSet {
		var index = 0;
		for (lhs in lhsA) {
			for (li in lhs.cases) {
				if (index == i) return li;
				++ index;
			}
		}
		throw "NotFound";
	}

	function transform(swa: Array<SymSwitch>) {
		for (sw in swa) { // init udtMap first..
			this.udtMap.set(sw.name, {t: false, name: sw.name, value: sw.value, cset: CSet.single(sw.value), pos: sw.pos});
		}
		//inline function typeof(e: Expr) return try{ Context.typeExpr(e); }catch(err:Dynamic){null;}
		inline function setEpsilon(lhs, pos) {
			if (lhs.epsilon) Context.error('Duplicate "default:" or "case _:"', pos);
			lhs.epsilon = true;
		}
		function getCSet(name, pos) {
			var cset = getTermlCSet(name);
			if (cset == null) Context.error("Undefined: " + name, pos);
			return cset;
		}
		for (sw in swa) {
			var lhs: Lhs = { name: sw.name, value: sw.value, ct: sw.ct, cases: [], epsilon: false, pos: sw.pos};
			for (c in sw.cases) {
				if (c.guard != null)
					Context.error("Doesn't support guard", c.guard.pos);
				switch(c.values) {
				case [{expr:EArrayDecl(el), pos: pos}]:
					if (lhs.epsilon)
						Context.error('This case is unused', c.values[0].pos);
					var g: SymbolSet = {expr: c.expr, syms: []};
					for (e in el) {
						switch (e.expr) {
						case EConst(CIdent(i)):
							firstCharChecking(i, UPPER, e.pos);            // e.g: CInt
							g.syms.push( {t: true, name: i,    cset: getCSet(i, e.pos), ex: null, pos: e.pos} );

						// TODO: later.
						//case EParenthesis(macro $i{i}):
						//	firstCharChecking(i, LOWER, e.pos);            // for all termls
						//	g.syms.push( {t: true, name: null, cset: termlsC_All,       ex: i,    pos: e.pos} );

						case ECall(macro $i{i}, [macro $i{v}]):            // e.g: CInt(n)
							firstCharChecking(i, UPPER, e.pos);
							firstCharChecking(v, LOWER, e.pos);
							g.syms.push( {t: true, name: i,    cset: getCSet(i, e.pos), ex: v,    pos: e.pos} );

						case EBinop(OpAssign, macro $i{v}, macro $i{nt}):  // e.g: e = expr
							var udt = udtMap.get(nt);
							if (udt == null || udt.t == true)
								Context.error("Undefined non-terminal: " + nt, e.pos);
							if (el.length == 1 && nt == sw.name)
								Context.error("Infinite recursion", e.pos);
							g.syms.push( {t: false, name: nt, cset: udt.cset , ex: v , pos: e.pos} );

						case _:
							Context.error("Unsupported: " + e.toString(), e.pos);
						}
					}
					if (g.syms.length == 0)
						setEpsilon(lhs, pos);
					lhs.cases.push(g);
				case [{expr:EConst(CIdent("_")), pos: pos}]: // case _: || defualt:
					setEpsilon(lhs, pos);
					lhs.cases.push({expr: c.expr, syms: []});
				case [e]:
					Context.error("Expected [ patterns ]", e.pos);
				case _:
					Context.error("Comma notation is not allowed while matching streams", c.values[0].pos);
				}
			}
			this.lhsA.push(lhs);
		}
		organize();
	}

	function organize() {
		// add to lhsMap.
		for (lhs in lhsA) {
			if (lhsMap.exists(lhs.name))
				Context.error("Duplicate rule field declaration: " + lhs.name, lhs.pos);
			lhsMap.set(lhs.name, lhs);
		}

		// the "entry" must place  "EOF " at the end
		var entry = lhsA[0];
		for (li in entry.cases) {
			var last = li.syms[li.syms.length - 1];
			if (last.name == null || last.name != this.sEof)
				Context.error("for entry you must place *"+ this.sEof +"* at the end", last.pos);
		}

		// duplicate var checking.
		for (lhs in lhsA) {
			for (li in lhs.cases) {
				var row = new Map<String,Bool>();
				for (s in li.syms) {
					if (s.t == false && s.name == entry.name)
						Context.error("the entry non-terminal(\"" + s.name +"\") is not allowed on the right", s.pos);
					if (s.ex == null)
						continue;
					if (row.exists(s.ex))
						Context.error("duplicate var: " + s.ex, s.pos);
					row.set(s.ex, true);
				}
			}
		}
	}

	function checking(lex: LexEngine) {
		var table = lex.table;
		// 1. Is switch case unreachable?
		var exists = new haxe.ds.Vector<Int>(lex.nrules);
		for (i in table.length-lex.perRB...table.length) {
			var c = table.get(i);
			if (c == INVALID) continue;
			exists[c] = 1;
		}
		for (i in 0...lex.nrules)
			if (exists[i] != 1)
				Context.error("Unreachable switch case", indexCase(i).expr.pos);

		// 2. A non-terminator(lhs) must be able to derive at least one terminator directly or indirectly.
		for (index in 0...lex.entrys.length) {
			var base = lex.entrys[index].begin * lex.per;
			var find = false;
			for (i in base ... base + this.maxValue) {
				var c = table.get(i);
				if (c != INVALID) {
					find = true;
					break;
				}
			}
			if (!find) Context.error("There must be at least one terminator.", lhsA[index].pos);
		}
		// 3. more?
	}

	function toPartern(): Array<PatternSet> {
		inline function add(r, cur) return @:privateAccess LexEngine.next(r, Match(cur));
		var ret = [];
		for (lhs in this.lhsA) {
			var a = [];
			for (c in lhs.cases) {
				var p = Empty;
				for (s in c.syms)
					p = add(p, s.cset);
				a.push(p);
			}
			ret.push(a);
		}
		return ret;
	}

	function addition(lex: LexEngine, src: Int, dst: Int, lvalue: Int, lpos) {
		var state = lex.states[src];
		var targets = state.targets;
		var dstStart = dst * lex.per;
		for (c in lex.trans[state.part]) {
			var i = c.min;
			var max = c.max;
			var s = targets[c.ext];
			while ( i <= max ) {
				var follow = lex.table.get(dstStart + i);
				if (i == lvalue) {
					var next = lex.table.get(src * lex.per + lvalue);
					if (follow < lex.segs && next < lex.segs) {
						addition(lex, next, follow, -1, lpos);
					}
				} else {
					if (follow != INVALID)
						Context.error("rewrite conflict", lpos);
					lex.table.set(dstStart + i, s);
				}
				++ i;
			}
		}
	}

	function modify(lex: LexEngine) {
		var b = lex.table;
		var per = lex.per;
		for (seg in 0...lex.segs) {
			var base = seg * per;
			for (l in lhsA) {
				if (b.get(base + l.value) == INVALID)
					continue;
				var entry = lex.entrys[l.value - this.maxValue]; // the entry Associated with lhs
				if (entry.begin == seg) continue; // skip self.
				addition(lex, entry.begin, seg, l.value, l.pos);
				if (l.epsilon) {
					var dst = b.length - 1 - seg;
					if (b.get(dst) != INVALID)
						Context.error("epsilon conflict with " + l.name, l.pos);
					var src = b.length - 1 - entry.begin;
					b.set(dst, b.get(src));
				}
			}
		}
	}

	static public function build() {
		var cls = Context.getLocalClass().get();
		var ct_lr0 = TPath({pack: cls.pack, name: cls.name});
		var tk:Type = null;
		var eof: Expr = null;
		for (it in cls.interfaces) {
			if (it.t.toString() == "lm.LR0") {
				switch(it.params[0]) {
				case TInst(_.get() => lex, _):
					for (it in lex.interfaces) {
						if (it.t.toString() == "lm.Lexer") {
							tk = it.params[0];
							eof = @:privateAccess LexBuilder.getMeta(lex.meta.extract(":rule")).eof;
							if (eof == null || eof.toString() == "null") // "null" is not allowed as an EOF in parser
								Context.error("Invalid EOF value " + eof.toString(), lex.pos);
							break;
						}
					}
				default:
				}
				break;
			}
		}
		if (tk == null || !Context.unify(tk, Context.getType("Int")))
			Context.error("Wrong generic Type for lm.LR0<?>", cls.pos);
		// begin
		var lrb = new LR0Builder(tk, eof.toString());
		var allFields = new haxe.ds.StringMap<Bool>();
		var switches = filter(Context.getBuildFields(), allFields, lrb);
		if (switches.length == 0)
			return null;
		lrb.transform(switches);
		var pats = lrb.toPartern();
		var lex = new LexEngine(pats, lrb.maxValue + lrb.lhsA.length | 15, true);
		// modify lex.table as LR0
		lrb.modify(lex);

	#if lex_lr0table
		var f = sys.io.File.write("lr0-table.txt");
		f.writeString("\nProduction:\n");
		f.writeString(debug.Print.lr0Production(lrb));
		f.writeString(debug.Print.lr0Table(lrb, lex));
		f.writeString("\n\nRAW:\n");
		lex.write(f, true);
		f.close();
	#end

		lrb.checking(lex); // checking.

		var ret = [];
		//generate(ct_lr0, lrb, lex);
		return ret;
	}

	static function generate(ct: ComplexType, lrb: LR0Builder, lex: lm.LexEngine) {
		var force_bytes = !Context.defined("js") || Context.defined("lex_rawtable");
		if (Context.defined("lex_strtable")) force_bytes = false; // force string as table format
		var resname = "_" + StringTools.hex(haxe.crypto.Crc32.make(lex.table)).toLowerCase();
		var raw = macro haxe.Resource.getBytes($v{resname});
		if (force_bytes) {
			Context.addResource(resname, lex.table);
		} else {
			var out = haxe.macro.Compiler.getOutput() + ".lr0-table";
			var dir = haxe.io.Path.directory(out);
			if (!sys.FileSystem.exists(dir))
				sys.FileSystem.createDirectory(dir);
			var f = sys.io.File.write(out);
			lex.write(f);
			f.close();
			raw = macro ($e{haxe.macro.Compiler.includeFile(out, Inline)});
		}
		var getU8 = force_bytes ? macro raw.get(i) : macro StringTools.fastCodeAt(raw, i);
		var useSwitch = false;
		var gotos = useSwitch ? (macro cases(fid, s, i, state)) : (macro cases[fid](s, i, state));
		//var allCases: Array<Expr> = Lambda.flatten( lrb.lhsA.map(l -> l.cases) ).map( s -> s.expr );
		var defs = macro class {
			static var raw = $raw;
			static inline var NRULES  = $v{lex.nrules};
			static inline var NSEGS   = $v{lex.segs};
			static inline var INVALID = $v{INVALID};
			static inline function getU8(i:Int):Int return $getU8;
			static inline function trans(s:Int, c:Int):Int return getU8($v{lex.per} * s + c);
			static inline function exits(s:Int):Int return getU8($v{lex.table.length - 1} - s);
			static inline function rollB(s:Int):Int return getU8(s + $v{lex.posRB()});
			static inline function rollL(s:Int):Int return getU8(s + $v{lex.posRBL()});
			static inline function gotos(fid:Int, s:lm.Stream, i:Int, state:Int) return $gotos;
			var stream: lm.Stream; var stack: Array<Int>;
			public function new(lex: lm.Lexer<Int>) {
				this.stream = new lm.Stream(lex);
				right = 0;
			}
			function entry(state, expect) @:privateAccess {
				var r = stream.right;
				var prev = state;
				while (true) {
					while (true) {
						var t = stream.get(r++);
						state = trans(prev, t.char);
						t.setState(state);
						if (state >= NSEGS)
							break;
						prev = state;
					}
					var dx = 0;
					if (state == INVALID) {
						state = prev;
						dx = 1;
					}
					var q = exits(state);
					if (q < NRULES) {
						r -= dx;
					} else {
						q = rollB(state);
						if (q < NRULES) {
							r = r - dx - rollL(state);
							state = stream.rollback(r);
						} else {
							break; // error.
						}
					}
					stream.limit();
					var reduce: Int = gotos(q, this.stream, r, state);

					// the gotos may change the r and state..

					//if (reduce & 0xFF == expect)
					//	return value;
					// 假如在这里归约, 则需要一个 归约宽度 与 归约值
					// 假如在 gotos 里归约, 则要给每一个函数增加
					// 假设 gotos 只返回 value, 需要获得
					stream.unlimited();
					prev = stream.last().state;
				}
				var last = stream.peek(r - 1);
				throw lm.Utils.error('Unexpected "' + stream.str(last) + '" at ' + last.pos.pmin + "-" + last.pos.pmax);
			}
		}
	}

	static function filter(fields: Array<Field>, allFields, lrb: LR0Builder) {
		var lvalue = lrb.maxValue;
		var ret = [];
		for (f in fields) {
			if (f.access.indexOf(AStatic) > -1) {
				switch (f.kind) {
				case FVar(ct, e) if (e != null):
					switch(e.expr) {
					case ESwitch(macro ($i{"s"}), cl, edef):
						if (cl.length == 0) continue; // TODO: if (cl.length == 0 && edef == null)
						if (edef != null)
							cl.push({values: [macro @:pos(edef.pos) _], expr: edef, guard: null});
						firstCharChecking(f.name, LOWER, f.pos);
						ret.push({name: f.name, value: lvalue++, ct: ct, cases: cl, pos: f.pos});
					case _:
					}
					continue;
				case FFun(fun):
					var ofstr = Lambda.find(f.meta, m->m.name == ":ofStr");
					if (ofstr != null && ofstr.params.length > 0) {
						var p0 = ofstr.params[0];
						switch(p0.expr){
						case EConst(CIdent(s)) | EConst(CString(s)):
							lrb.funMap.set(s, {name: f.name, ct: fun.ret});
						default:
							Context.error("UnSupperted value for @:ofStr: " + p0.toString(), p0.pos);
						}
					}
				default:
				}
			}
			allFields.set(f.name, true);
		}
		return ret;
	}

	static inline var UPPER = true;
	static inline var LOWER = false;
	static function firstCharChecking(s: String, upper: Bool, pos: Position) {
		var c = s.charCodeAt(0);
		if (upper) {
			if ( !(c >= "A".code && c <= "Z".code) )
				Context.error("Should be start with a capital letter: " + s, pos);
		} else {
			if ( !(c >= "a".code && c <= "z".code || c == "_".code) )
				Context.error("Should be start with a lowercase letter: " + s, pos);
		}
	}

}

#else
class LR0Builder{}

@:autoBuild(lm.LR0Builder.build())
#end
@:remove interface LR0<T> {
}
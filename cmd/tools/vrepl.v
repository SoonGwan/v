// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

module main

import os
import term
import readline
import os.cmdline
import v.util

struct Repl {
mut:
	indent         int      // indentation level
	in_func        bool     // are we inside a new custom user function
	line           string   // the current line entered by the user
	//
	imports        []string // all the import statements
	functions      []string // all the user function declarations
	functions_name []string // all the user function names
	lines          []string // all the other lines/statements
	temp_lines     []string // all the temporary expressions/printlns
}

fn (mut r Repl) checks() bool {
	mut in_string := false
	was_indent := r.indent > 0

	for i := 0; i < r.line.len; i++ {
		if r.line[i] == `\'` && (i == 0 || r.line[i - 1] != `\\`) {
			in_string = !in_string
		}
		if r.line[i] == `{` && !in_string {
			r.line = r.line[..i + 1] + '\n' + r.line[i + 1..]
			i++
			r.indent++
		}
		if r.line[i] == `}` && !in_string {
			r.line = r.line[..i] + '\n' + r.line[i..]
			i++
			r.indent--
			if r.indent == 0 {
				r.in_func = false
			}
		}
		if i + 2 < r.line.len && r.indent == 0 && r.line[i + 1] == `f` && r.line[i + 2] == `n` {
			r.in_func = true
		}
	}
	return r.in_func || (was_indent && r.indent <= 0) || r.indent > 0
}

fn (r &Repl) function_call(line string) bool {
	for function in r.functions_name {
		if line.starts_with(function) {
			return true
		}
	}
	return false
}

fn (r &Repl) current_source_code(should_add_temp_lines bool) string {
	mut all_lines := []string{}
	all_lines << r.imports
	all_lines << r.functions
	all_lines << r.lines
	if should_add_temp_lines {
		all_lines << r.temp_lines
	}
	return all_lines.join('\n')
}

fn repl_help() {
	println(util.full_v_version(true))
	println('
  help                   Displays this information.
  list                   Show the program so far.
  reset                  Clears the accumulated program, so you can start a fresh.
  Ctrl-C, Ctrl-D, exit   Exits the REPL.
  clear                  Clears the screen.
')
}

fn run_repl(workdir string, vrepl_prefix string) {
	println(util.full_v_version(true))
	println('Use Ctrl-C or `exit` to exit')

	file := os.join_path(workdir, '.${vrepl_prefix}vrepl.v')
	temp_file := os.join_path(workdir, '.${vrepl_prefix}vrepl_temp.v')
	mut prompt := '>>> '
	defer {
		println('')
		os.rm(file)
		os.rm(temp_file)
		$if windows {
			os.rm(file[..file.len - 2] + '.exe')
			os.rm(temp_file[..temp_file.len - 2] + '.exe')
			$if msvc {
				os.rm(file[..file.len - 2] + '.ilk')
				os.rm(file[..file.len - 2] + '.pdb')
				os.rm(temp_file[..temp_file.len - 2] + '.ilk')
				os.rm(temp_file[..temp_file.len - 2] + '.pdb')
			}
		} $else {
			os.rm(file[..file.len - 2])
			os.rm(temp_file[..temp_file.len - 2])
		}
	}
	mut r := Repl{}
	mut readline := readline.Readline{}
	vexe := os.getenv('VEXE')
	for {
		if r.indent == 0 {
			prompt = '>>> '
		} else {
			prompt = '... '
		}
		oline := readline.read_line(prompt) or {
			break
		}
		line := oline.trim_space()
		if line == '' && oline.ends_with('\n') {
			continue
		}
		if line.len <= -1 || line == '' || line == 'exit' {
			break
		}
		r.line = line
		if r.line == '\n' {
			continue
		}
		if r.line == 'clear' {
			term.erase_display('2')
			continue
		}
		if r.line == 'help' {
			repl_help()
			continue
		}
		if r.line.contains(':=') && r.line.contains('fn(') {
			r.in_func = true
			r.functions_name << r.line.all_before(':= fn(').trim_space()
		}
		if r.line.starts_with('fn') {
			r.in_func = true
			r.functions_name << r.line.all_after('fn').all_before('(').trim_space()
		}
		was_func := r.in_func
		if r.checks() {
			for rline in r.line.split('\n') {
				if r.in_func || was_func {
					r.functions << rline
				} else {
					r.temp_lines << rline
				}
			}
			if r.indent > 0 {
				continue
			}
			r.line = ''
		}
		if r.line == 'debug_repl' {
			eprintln('repl: $r')
			continue
		}
		if r.line == 'reset' {
		    r = Repl{}
			continue
		}
		if r.line == 'list' {
			source_code := r.current_source_code(true)
			println('//////////////////////////////////////////////////////////////////////////////////////')
			println(source_code)
			println('//////////////////////////////////////////////////////////////////////////////////////')
			continue
		}
		// Save the source only if the user is printing something,
		// but don't add this print call to the `lines` array,
		// so that it doesn't get called during the next print.
		if r.line.starts_with('='){
			r.line = 'println(' + r.line[1..] + ')'
		}
		if r.line.starts_with('print') {
			source_code := r.current_source_code(false) + '\n${r.line}\n'
			os.write_file(file, source_code)
			s := os.exec('"$vexe" -repl run "$file"') or {
				rerror(err)
				return
			}
			print_output(s)
		} else {
			mut temp_line := r.line
			mut temp_flag := false
			func_call := r.function_call(r.line)
			filter_line := r.line.replace(r.line.find_between('\'', '\''), '').replace(r.line.find_between('"', '"'), '')
			possible_statement_patterns := [
				'=', '++', '--', '<<',
				'//', '/*',
				'fn ', 'pub ', 'mut ', 'enum ', 'const ', 'struct ', 'interface ', 'import ',
				'#include ', ':=', 'for '
			]
			mut is_statement := false
			for pattern in possible_statement_patterns {
				if filter_line.contains(pattern) {
					is_statement = true
					break
				}
			}
			// NB: starting a line with 2 spaces escapes the println heuristic
			if oline.starts_with('  ') {
				is_statement = true
			}
			if !is_statement && !func_call && r.line != '' {
				temp_line = 'println($r.line)'
				temp_flag = true
			}
			mut temp_source_code := ''
			if temp_line.starts_with('import ') || temp_line.starts_with('#include ') {
				temp_source_code = '${temp_line}\n' + r.current_source_code(false)
			} else {
				for i, l in r.lines {
					if (l.starts_with('for ') || l.starts_with('if ')) && l.contains('println') {
						r.lines.delete(i)
						break
					}
				}

				temp_source_code = r.current_source_code(true) + '\n${temp_line}\n'
			}
			os.write_file(temp_file, temp_source_code)
			s := os.exec('"$vexe" -repl run "$temp_file"') or {
				rerror(err)
				return
			}
			if !func_call && s.exit_code == 0 && !temp_flag {
				for r.temp_lines.len > 0 {
					if !r.temp_lines[0].starts_with('print') {
						r.lines << r.temp_lines[0]
					}
					r.temp_lines.delete(0)
				}
				if r.line.starts_with('import ') || r.line.starts_with('#include ') {
					mut imports := r.imports
					r.imports = [r.line]
					r.imports << imports
				} else {
					r.lines << r.line
				}
			} else {
				for r.temp_lines.len > 0 {
					r.temp_lines.delete(0)
				}
			}
			print_output(s)
		}
	}
}

fn print_output(s os.Result) {
	lines := s.output.split('\n')
	for line in lines {
		if line.contains('.vrepl_temp.v:') {
			// Hide the temporary file name
			sline := line.all_after('.vrepl_temp.v:')
			idx := sline.index(' ') or {
				println(sline)
				return
			}
			println(sline[idx+1..])
		} else if line.contains('.vrepl.v:') {
			// Ensure that .vrepl.v: is at the start, ignore the path
			// This is needed to have stable .repl tests.
			idx := line.index('.vrepl.v:') or { return }
			println(line[idx..])
		} else {
			println(line)
		}
	}
}

fn main() {
	// Support for the parameters replfolder and replprefix is needed
	// so that the repl can be launched in parallel by several different
	// threads by the REPL test runner.
	args := cmdline.options_after(os.args, ['repl'])
	replfolder := os.real_path(cmdline.option(args, '-replfolder', '.'))
	replprefix := cmdline.option(args, '-replprefix', 'noprefix.')
	os.chdir(replfolder)
	if !os.exists(os.getenv('VEXE')) {
		println('Usage:')
		println('  VEXE=vexepath vrepl\n')
		println('  ... where vexepath is the full path to the v executable file')
		return
	}
	run_repl(replfolder, replprefix)
}

fn rerror(s string) {
	println('V repl error: $s')
	os.flush()
}

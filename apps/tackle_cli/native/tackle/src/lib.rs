mod browse;
mod conversation;
mod diff;
mod input;
mod markdown;
mod markdown_table;
mod selection;
mod subagents;
mod surface;
mod tree;
mod widgets;

use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use rustler::{Atom, NifResult};
use std::io::{IsTerminal, Read};
use std::process::{Command, Stdio};

mod atoms {
    rustler::atoms! { ok, invalid_size, label_too_long }
}

// Bound both allocation and output terms, even for direct NIF callers.
const MAX_CELLS: usize = 65_536;
const MAX_LABEL_BYTES: usize = 4_096;

#[rustler::nif(schedule = "DirtyCpu")]
fn badge(label: String, width: u16, height: u16) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS {
        return Err(rustler::Error::Term(Box::new(atoms::invalid_size())));
    }
    if label.len() > MAX_LABEL_BYTES {
        return Err(rustler::Error::Term(Box::new(atoms::label_too_long())));
    }
    if label.chars().any(char::is_control) {
        return Err(rustler::Error::Term(Box::new("control character in label")));
    }
    if width == 0 || height == 0 {
        return Ok((atoms::ok(), vec![]));
    }

    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    widgets::badge::Badge { label: &label }.render(area, &mut buffer);
    let lines = surface::lines(&buffer).map_err(|reason| rustler::Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), lines))
}

/// Rows for one submitted `edit` replacement.
///
/// Returns `{:ok, {added_lines, removed_lines}, rows}`. A row is
/// `{tag, number, spans}` with `tag` in `:del | :ins | :ctx` and
/// `spans` a list of `{text, emphasized}` runs, or `{:elision, count}`
/// for lines left out of the printed window. `similar` does the matching;
/// the card paints it.
#[rustler::nif(schedule = "DirtyCpu")]
fn diff_rows(
    old: String,
    new: String,
    context: usize,
    max_rows: usize,
) -> (Atom, (usize, usize), Vec<diff::DiffRow>) {
    let (counts, rows) = diff::rows(&old, &new, context, max_rows);
    (atoms::ok(), counts, rows)
}

/// Whether the process' stdout is an interactive terminal.
///
/// Guards terminal-only escape sequences (such as OSC window titles) against
/// being written into piped or redirected output.
#[rustler::nif]
fn stdout_is_terminal() -> bool {
    std::io::stdout().is_terminal()
}

/// Runs `argv` on the process' own terminal and returns what it printed.
///
/// Erlang ports start children in a new session, which has no controlling
/// terminal, so a terminal program that opens `/dev/tty` (Emacs, for one)
/// cannot run from a port. A child spawned here stays in the BEAM's session
/// and foreground process group, the way a shell would start it, with the
/// terminal as its standard input and error.
///
/// Its standard output is a pipe, read until the child closes it, because
/// the BEAM ignores `SIGCHLD`: exited children are reaped at once and their
/// exit status cannot be waited for. A caller that needs the status has the
/// child print it. Runs on a dirty I/O scheduler, because the read lasts as
/// long as the program does.
#[rustler::nif(schedule = "DirtyIo")]
fn run_in_terminal(argv: Vec<String>) -> NifResult<(Atom, String)> {
    let (program, args) = argv.split_first().ok_or(rustler::Error::BadArg)?;
    let error = |error: std::io::Error| rustler::Error::Term(Box::new(error.to_string()));

    let (mut reader, writer) = std::io::pipe().map_err(error)?;

    // The command, and the pipe's write end with it, is dropped once the
    // child has started, so the read below ends when the child exits.
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(writer)
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(error)?;

    let mut output = String::new();
    let read = reader.read_to_string(&mut output);

    // Reaps the child where `SIGCHLD` is not ignored; under the BEAM there is
    // nothing left to reap. Never blocks.
    let _ = child.try_wait();

    read.map_err(error)?;
    Ok((atoms::ok(), output))
}

rustler::init!("Elixir.Tackle.CLI.Native");

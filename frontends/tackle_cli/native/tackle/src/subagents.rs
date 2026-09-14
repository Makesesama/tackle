//! NIF boundary for the active-subagent sidebar.
use crate::{
    atoms,
    conversation::{style, WireStyle},
    surface,
    widgets::{
        conversation::sanitize,
        subagents::{SubagentTask, Subagents},
    },
    MAX_CELLS,
};
use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use rustler::{Atom, Error, NifResult};

type WireTask = (String, String, String, String, Option<String>);

#[rustler::nif(schedule = "DirtyCpu")]
fn subagents_render(
    tasks: Vec<WireTask>,
    width: u16,
    height: u16,
    accent: WireStyle,
    muted: WireStyle,
    text: WireStyle,
    selected: Option<usize>,
    spinner_frame: usize,
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS || tasks.len() > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }

    let mut byte_count = 0usize;
    let tasks = tasks
        .into_iter()
        .map(|(profile, model, assignment, work, elapsed)| {
            byte_count = byte_count
                .saturating_add(profile.len())
                .saturating_add(model.len())
                .saturating_add(assignment.len())
                .saturating_add(work.len())
                .saturating_add(elapsed.as_ref().map(String::len).unwrap_or(0));
            SubagentTask {
                profile: sanitize(&profile).replace('\n', " "),
                model: sanitize(&model).replace('\n', " "),
                assignment: sanitize(&assignment).replace('\n', " "),
                work: sanitize(&work).replace('\n', " "),
                elapsed: elapsed.map(|value| sanitize(&value).replace('\n', " ")),
            }
        })
        .collect::<Vec<_>>();
    if byte_count > MAX_CELLS * 16 {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }

    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    Subagents {
        tasks: &tasks,
        accent: style(accent)?,
        muted: style(muted)?,
        text: style(text)?,
        selected,
        spinner_frame,
    }
    .render(area, &mut buffer);
    let rows = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), rows))
}

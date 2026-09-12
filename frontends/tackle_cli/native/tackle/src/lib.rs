mod conversation;
mod input;
mod surface;
mod tree;
mod widgets;

use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use rustler::{Atom, NifResult};

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

rustler::init!("Elixir.Tackle.CLI.Native");

//! Immutable local Browse resources. No provider or session state enters Rust.
use crate::{
    atoms,
    conversation::{style, ConversationResource, WireStyle},
    surface,
    widgets::{
        browse::{body_height, scroll, Browse, PAGES},
        conversation::{Conversation, HistoryCell},
    },
    MAX_CELLS,
};
use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use rustler::{Atom, Error, NifResult, ResourceArc};
use std::sync::Arc;

#[rustler::nif(schedule = "DirtyCpu")]
fn browse_document(
    source: String,
    width: u16,
    base: WireStyle,
) -> NifResult<(ResourceArc<ConversationResource>, usize)> {
    let cell = HistoryCell::plain(&source, width, style(base)?);
    let conversation = Conversation::new(vec![Arc::new(cell)]);
    let height = conversation.height;
    Ok((
        ResourceArc::new(ConversationResource(conversation, width.max(1))),
        height,
    ))
}

#[rustler::nif]
fn browse_scroll(offset: usize, total: usize, height: u16, delta: i64) -> usize {
    scroll(offset, total, body_height(height), delta)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn browse_render(
    resource: ResourceArc<ConversationResource>,
    page: usize,
    width: u16,
    height: u16,
    offset: usize,
    selected: Vec<usize>,
    styles: (WireStyle, WireStyle, WireStyle),
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS || selected.len() > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }
    if page >= PAGES.len() || (width != 0 && height != 0 && width != resource.1) {
        return Err(Error::BadArg);
    }
    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    Browse {
        conversation: &resource.0,
        page,
        offset,
        selected: &selected,
        accent: style(styles.0)?,
        muted: style(styles.1)?,
        selection: style(styles.2)?,
    }
    .render(area, &mut buffer);
    let rows = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), rows))
}

//! NIF boundary for the native conversation-tree viewport.
use crate::{
    atoms,
    conversation::{style, WireStyle},
    surface,
    widgets::{
        conversation::sanitize,
        tree::{Tree, TreeNode},
    },
    MAX_CELLS,
};
use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use rustler::{Atom, Error, NifResult};

type WireNode = (
    String,
    Option<String>,
    usize,
    (bool, bool),
    Vec<bool>,
    bool,
    bool,
);

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_render(
    nodes: Vec<WireNode>,
    selected: usize,
    width: u16,
    height: u16,
    accent: WireStyle,
    muted: WireStyle,
    selection: WireStyle,
    text: WireStyle,
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS || nodes.len() > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }

    let mut byte_count = 0usize;
    let nodes = nodes
        .into_iter()
        .map(
            |(
                text,
                secondary,
                depth,
                (show_connector, is_last),
                ancestor_continues,
                active,
                unsafe_entry,
            )| {
                byte_count = byte_count
                    .saturating_add(text.len())
                    .saturating_add(secondary.as_ref().map(String::len).unwrap_or(0));
                if depth > MAX_CELLS || ancestor_continues.len() != depth {
                    return Err(Error::BadArg);
                }
                Ok(TreeNode {
                    text: sanitize(&text).replace('\n', " "),
                    secondary: secondary.map(|value| sanitize(&value).replace('\n', " ")),
                    depth,
                    show_connector,
                    is_last,
                    ancestor_continues,
                    active,
                    unsafe_entry,
                })
            },
        )
        .collect::<NifResult<Vec<_>>>()?;
    if byte_count > MAX_CELLS * 16 {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }

    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    Tree {
        nodes: &nodes,
        selected,
        scroll_padding: 2,
        accent: style(accent)?,
        muted: style(muted)?,
        selection: style(selection)?,
        text: style(text)?,
    }
    .render(area, &mut buffer);
    let rows = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), rows))
}

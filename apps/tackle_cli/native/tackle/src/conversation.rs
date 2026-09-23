//! Owned immutable resources: old scenes remain valid after a stream refresh.
use crate::{
    atoms, surface,
    widgets::conversation::{sanitize, Conversation, HistoryCell},
    MAX_CELLS,
};
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Widget,
};
use rustler::{Atom, Error, NifResult, NifUntaggedEnum, ResourceArc};
use std::sync::Arc;

pub struct CellResource(Arc<HistoryCell>);
pub struct ConversationResource(pub(crate) Conversation, pub(crate) u16);
#[rustler::resource_impl]
impl rustler::Resource for CellResource {}
#[rustler::resource_impl]
impl rustler::Resource for ConversationResource {}

#[derive(NifUntaggedEnum)]
pub(crate) enum WireColor {
    Index(u8),
    Rgb((u8, u8, u8)),
}
pub(crate) type WireStyle = (Option<WireColor>, Option<WireColor>, Option<WireColor>, u16);
type WireSpan = (String, WireStyle);
type WireLine = (Vec<WireSpan>, WireStyle);

fn color(value: Option<WireColor>) -> Option<Color> {
    value.map(|c| match c {
        WireColor::Index(i) => Color::Indexed(i),
        WireColor::Rgb((r, g, b)) => Color::Rgb(r, g, b),
    })
}
pub(crate) fn style((fg, bg, underline, bits): WireStyle) -> NifResult<Style> {
    let supported = Modifier::BOLD
        | Modifier::DIM
        | Modifier::ITALIC
        | Modifier::UNDERLINED
        | Modifier::REVERSED
        | Modifier::CROSSED_OUT;
    let modifiers = Modifier::from_bits(bits)
        .filter(|m| supported.contains(*m))
        .ok_or(Error::BadArg)?;
    Ok(Style {
        fg: color(fg),
        bg: color(bg),
        underline_color: color(underline),
        add_modifier: modifiers,
        ..Style::default()
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_markdown(
    source: String,
    width: u16,
    base: WireStyle,
) -> NifResult<(ResourceArc<CellResource>, usize)> {
    let cell = HistoryCell::markdown(&source, width, style(base)?);
    let height = cell.height();
    Ok((ResourceArc::new(CellResource(Arc::new(cell))), height))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_message(
    source: String,
    width: u16,
    markdown: bool,
    base: WireStyle,
    marker: WireSpan,
) -> NifResult<(ResourceArc<CellResource>, usize)> {
    let marker = Span::styled(sanitize(&marker.0).replace('\n', " "), style(marker.1)?);
    let cell = HistoryCell::message(&source, width, markdown, style(base)?, marker);
    let height = cell.height();
    Ok((ResourceArc::new(CellResource(Arc::new(cell))), height))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_rows(
    rows: Vec<WireLine>,
    width: u16,
) -> NifResult<(ResourceArc<CellResource>, usize)> {
    let lines = rows
        .into_iter()
        .map(|(spans, base)| {
            let spans = spans
                .into_iter()
                .map(|(text, s)| Ok(Span::styled(sanitize(&text).replace('\n', " "), style(s)?)))
                .collect::<NifResult<Vec<_>>>()?;
            Ok(Line::from(spans).style(style(base)?))
        })
        .collect::<NifResult<Vec<_>>>()?;
    let cell = HistoryCell::rows(lines, width);
    let height = cell.height();
    Ok((ResourceArc::new(CellResource(Arc::new(cell))), height))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_code(
    rows: Vec<WireLine>,
    width: u16,
    base: WireStyle,
    marker: Option<WireSpan>,
) -> NifResult<(ResourceArc<CellResource>, usize)> {
    let lines = rows
        .into_iter()
        .map(|(spans, row_style)| {
            let spans = spans
                .into_iter()
                .map(|(text, s)| Ok(Span::styled(sanitize(&text).replace('\n', ""), style(s)?)))
                .collect::<NifResult<Vec<_>>>()?;
            Ok(Line::from(spans).style(style(row_style)?))
        })
        .collect::<NifResult<Vec<_>>>()?;
    let marker = marker
        .map(|(text, wire)| Ok(Span::styled(sanitize(&text), style(wire)?)))
        .transpose()?;
    let cell = HistoryCell::code(lines, width, style(base)?, marker);
    let height = cell.height();
    Ok((ResourceArc::new(CellResource(Arc::new(cell))), height))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_new(
    cells: Vec<ResourceArc<CellResource>>,
    width: u16,
) -> NifResult<(ResourceArc<ConversationResource>, usize)> {
    if cells.iter().any(|cell| cell.0.width() != width.max(1)) {
        return Err(Error::BadArg);
    }
    let conversation = Conversation::new(cells.iter().map(|cell| cell.0.clone()).collect());
    let height = conversation.height;
    Ok((
        ResourceArc::new(ConversationResource(conversation, width.max(1))),
        height,
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_render(
    resource: ResourceArc<ConversationResource>,
    width: u16,
    height: u16,
    offset: usize,
    selected: Vec<usize>,
    selection: WireStyle,
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }
    if width != 0 && height != 0 && width != resource.1 {
        return Err(Error::BadArg);
    }
    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    resource
        .0
        .widget(offset, &selected, style(selection)?)
        .render(area, &mut buffer);
    let lines = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), lines))
}

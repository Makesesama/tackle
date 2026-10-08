//! Private NIF boundary: Tackle owns these resources, never ExRatatui.
use crate::{
    atoms,
    conversation::WireStyle,
    surface,
    widgets::input::{Input, WireElement},
    MAX_CELLS, MAX_LABEL_BYTES,
};
use ratatui::{buffer::Buffer, layout::Rect};
use rustler::{Atom, Error, NifResult, ResourceArc};
use std::sync::{Mutex, MutexGuard};

pub struct InputResource(Mutex<Input>);

#[rustler::resource_impl]
impl rustler::Resource for InputResource {}

fn lock(resource: &InputResource) -> NifResult<MutexGuard<'_, Input>> {
    resource
        .0
        .lock()
        .map_err(|_| Error::Term(Box::new("input lock poisoned")))
}

#[rustler::nif]
fn input_new() -> ResourceArc<InputResource> {
    ResourceArc::new(InputResource(Mutex::new(Input::default())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_get_value(resource: ResourceArc<InputResource>) -> NifResult<String> {
    Ok(lock(&resource)?.value().to_owned())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_set_value(resource: ResourceArc<InputResource>, value: String) -> NifResult<Atom> {
    lock(&resource)?.set(value);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_insert_str(resource: ResourceArc<InputResource>, value: String) -> NifResult<Atom> {
    lock(&resource)?.insert(&value);
    Ok(atoms::ok())
}

/// Inserts a paste label as one atomic element after `prefix`, both in a single
/// undo step. `id` is the host's identifier for the retained payload; the input
/// stores it and hands it back with the range, and never interprets it.
#[rustler::nif(schedule = "DirtyCpu")]
fn input_insert_element(
    resource: ResourceArc<InputResource>,
    prefix: String,
    label: String,
    id: u64,
) -> NifResult<Atom> {
    if label.is_empty() || label.len() > MAX_LABEL_BYTES || label.contains(char::is_control) {
        return Err(Error::BadArg);
    }
    if prefix.contains(char::is_control) || prefix.len() > MAX_LABEL_BYTES {
        return Err(Error::BadArg);
    }
    lock(&resource)?.insert_element(&prefix, &label, id);
    Ok(atoms::ok())
}

/// The labels in the draft: `{id, byte_start, byte_end}` in draft order.
#[rustler::nif(schedule = "DirtyCpu")]
fn input_elements(resource: ResourceArc<InputResource>) -> NifResult<Vec<WireElement>> {
    Ok(lock(&resource)?.elements())
}

/// Replaces the draft and re-attaches the label spans the host recorded for it.
/// Spans that do not fit are dropped by the widget rather than trusted, and the
/// ones it attached come back so the host can tell the two apart.
#[rustler::nif(schedule = "DirtyCpu")]
fn input_restore(
    resource: ResourceArc<InputResource>,
    text: String,
    spans: Vec<WireElement>,
) -> NifResult<(Atom, Vec<WireElement>)> {
    Ok((atoms::ok(), lock(&resource)?.restore(text, &spans)))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_handle_key(
    resource: ResourceArc<InputResource>,
    code: String,
    modifiers: Vec<String>,
    width: u16,
) -> NifResult<Atom> {
    lock(&resource)?.key(&code, &modifiers, width);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_rows(resource: ResourceArc<InputResource>, width: u16) -> NifResult<usize> {
    Ok(lock(&resource)?.rows(width))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_cursor(resource: ResourceArc<InputResource>) -> NifResult<usize> {
    Ok(lock(&resource)?.cursor())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_replace_range(
    resource: ResourceArc<InputResource>,
    start: usize,
    end: usize,
    text: String,
) -> NifResult<Atom> {
    lock(&resource)?.replace_range(start, end, &text);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn input_render(
    resource: ResourceArc<InputResource>,
    width: u16,
    height: u16,
    placeholder: String,
    focused: bool,
    element_style: WireStyle,
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }
    if placeholder.len() > crate::MAX_LABEL_BYTES || placeholder.contains(char::is_control) {
        return Err(Error::BadArg);
    }
    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    lock(&resource)?.render(
        area,
        &mut buffer,
        &placeholder,
        focused,
        crate::conversation::style(element_style)?,
    );
    let rows = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), rows))
}

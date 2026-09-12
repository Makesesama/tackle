//! Private NIF boundary: Tackle owns these resources, never ExRatatui.
use crate::{atoms, surface, widgets::input::Input, MAX_CELLS};
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
fn input_render(
    resource: ResourceArc<InputResource>,
    width: u16,
    height: u16,
    placeholder: String,
    focused: bool,
) -> NifResult<(Atom, Vec<surface::Line>)> {
    if usize::from(width) * usize::from(height) > MAX_CELLS {
        return Err(Error::Term(Box::new(atoms::invalid_size())));
    }
    if placeholder.len() > crate::MAX_LABEL_BYTES || placeholder.contains(char::is_control) {
        return Err(Error::BadArg);
    }
    let area = Rect::new(0, 0, width, height);
    let mut buffer = Buffer::empty(area);
    lock(&resource)?.render(area, &mut buffer, &placeholder, focused);
    let rows = surface::lines(&buffer).map_err(|reason| Error::Term(Box::new(reason)))?;
    Ok((atoms::ok(), rows))
}

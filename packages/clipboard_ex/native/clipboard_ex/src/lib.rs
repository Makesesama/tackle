//! Native clipboard access for `Clipboard.Native`, backed by `arboard`.
//!
//! A `Handle` wraps one `arboard::Clipboard`. On X11 and Wayland the clipboard
//! contents are served by the process that set them, so the Elixir side keeps a
//! handle alive in a long-lived owner process. Every call may block on the
//! display server, hence the dirty I/O scheduler.

use std::borrow::Cow;
use std::sync::Mutex;

use arboard::{Clipboard, ImageData};
use rustler::{Atom, Binary, Encoder, Env, OwnedBinary, ResourceArc, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        clipboard,
        primary,
        secondary,
        content_not_available,
        clipboard_not_supported,
        clipboard_occupied,
        conversion_failure,
        unknown,
        unsupported_selection,
        invalid_image,
        out_of_memory,
        closed,
    }
}

/// The clipboard, until `close/1` takes it out. Dropping an X11 clipboard that
/// still owns the selection hands it to a clipboard manager and joins its
/// server thread, which can take seconds; `close/1` does that on a dirty
/// scheduler instead of wherever the resource happens to be garbage collected.
pub struct Handle(Mutex<Option<Clipboard>>);

#[rustler::resource_impl]
impl rustler::Resource for Handle {}

/// An error reason: a plain atom, or `{:unknown, description}`.
pub enum Reason {
    Atom(Atom),
    Unknown(String),
}

impl Encoder for Reason {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Reason::Atom(atom) => atom.encode(env),
            Reason::Unknown(description) => (atoms::unknown(), description.as_str()).encode(env),
        }
    }
}

impl From<arboard::Error> for Reason {
    fn from(error: arboard::Error) -> Self {
        match error {
            arboard::Error::ContentNotAvailable => Reason::Atom(atoms::content_not_available()),
            arboard::Error::ClipboardNotSupported => Reason::Atom(atoms::clipboard_not_supported()),
            arboard::Error::ClipboardOccupied => Reason::Atom(atoms::clipboard_occupied()),
            arboard::Error::ConversionFailure => Reason::Atom(atoms::conversion_failure()),
            arboard::Error::Unknown { description } => Reason::Unknown(description),
            // `arboard::Error` is non-exhaustive.
            other => Reason::Unknown(other.to_string()),
        }
    }
}

#[derive(Clone, Copy)]
enum Selection {
    Clipboard,
    Primary,
    Secondary,
}

fn selection(atom: Atom) -> Result<Selection, Reason> {
    if atom == atoms::clipboard() {
        Ok(Selection::Clipboard)
    } else if atom == atoms::primary() {
        Ok(Selection::Primary)
    } else if atom == atoms::secondary() {
        Ok(Selection::Secondary)
    } else {
        Err(Reason::Atom(atoms::unsupported_selection()))
    }
}

/// Linux (X11/Wayland) can address the PRIMARY and SECONDARY selections.
#[cfg(all(
    unix,
    not(any(target_os = "macos", target_os = "android", target_os = "emscripten"))
))]
mod platform {
    use super::{Reason, Selection};
    use arboard::{
        Clear, ClearExtLinux, Clipboard, Get, GetExtLinux, LinuxClipboardKind, Set, SetExtLinux,
    };

    fn kind(selection: Selection) -> LinuxClipboardKind {
        match selection {
            Selection::Clipboard => LinuxClipboardKind::Clipboard,
            Selection::Primary => LinuxClipboardKind::Primary,
            Selection::Secondary => LinuxClipboardKind::Secondary,
        }
    }

    pub fn get(clipboard: &mut Clipboard, selection: Selection) -> Result<Get<'_>, Reason> {
        Ok(clipboard.get().clipboard(kind(selection)))
    }

    pub fn set(clipboard: &mut Clipboard, selection: Selection) -> Result<Set<'_>, Reason> {
        Ok(clipboard.set().clipboard(kind(selection)))
    }

    pub fn clear(clipboard: &mut Clipboard, selection: Selection) -> Result<(), Reason> {
        let clear: Clear<'_> = clipboard.clear_with();
        clear.clipboard(kind(selection)).map_err(Reason::from)
    }
}

/// Other platforms have a single clipboard.
#[cfg(not(all(
    unix,
    not(any(target_os = "macos", target_os = "android", target_os = "emscripten"))
)))]
mod platform {
    use super::{atoms, Reason, Selection};
    use arboard::{Clipboard, Get, Set};

    fn only_clipboard(selection: Selection) -> Result<(), Reason> {
        match selection {
            Selection::Clipboard => Ok(()),
            _ => Err(Reason::Atom(atoms::unsupported_selection())),
        }
    }

    pub fn get(clipboard: &mut Clipboard, selection: Selection) -> Result<Get<'_>, Reason> {
        only_clipboard(selection).map(|()| clipboard.get())
    }

    pub fn set(clipboard: &mut Clipboard, selection: Selection) -> Result<Set<'_>, Reason> {
        only_clipboard(selection).map(|()| clipboard.set())
    }

    pub fn clear(clipboard: &mut Clipboard, selection: Selection) -> Result<(), Reason> {
        only_clipboard(selection)?;
        clipboard.clear().map_err(Reason::from)
    }
}

fn lock(handle: &Handle) -> std::sync::MutexGuard<'_, Option<Clipboard>> {
    // A panic while the lock was held cannot leave `Clipboard` half-updated in a
    // way later calls rely on, so a poisoned lock is still usable.
    handle
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn with_clipboard<T>(
    handle: &Handle,
    f: impl FnOnce(&mut Clipboard) -> Result<T, Reason>,
) -> Result<T, Reason> {
    match lock(handle).as_mut() {
        Some(clipboard) => f(clipboard),
        None => Err(Reason::Atom(atoms::closed())),
    }
}

/// Encodes `:ok` or `{:error, reason}`.
fn unit_reply<'a>(env: Env<'a>, result: Result<(), Reason>) -> Term<'a> {
    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn new() -> Result<ResourceArc<Handle>, Reason> {
    let clipboard = Clipboard::new()?;
    Ok(ResourceArc::new(Handle(Mutex::new(Some(clipboard)))))
}

/// Releases the clipboard. Later calls on the handle return `{:error, :closed}`.
#[rustler::nif(schedule = "DirtyIo")]
fn close(handle: ResourceArc<Handle>) -> Atom {
    let clipboard = lock(&handle).take();
    drop(clipboard);
    atoms::ok()
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_text<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    selection: Atom,
    text: String,
) -> Term<'a> {
    let result = with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::set(clipboard, selection)?
            .text(text)
            .map_err(Reason::from)
    });

    unit_reply(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_html<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    selection: Atom,
    html: String,
    alt_text: Option<String>,
) -> Term<'a> {
    let result = with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::set(clipboard, selection)?
            .html(html, alt_text)
            .map_err(Reason::from)
    });

    unit_reply(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_text(handle: ResourceArc<Handle>, selection: Atom) -> Result<String, Reason> {
    with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::get(clipboard, selection)?
            .text()
            .map_err(Reason::from)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_html(handle: ResourceArc<Handle>, selection: Atom) -> Result<String, Reason> {
    with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::get(clipboard, selection)?
            .html()
            .map_err(Reason::from)
    })
}

/// Sets an RGBA8 image: `bytes` holds `width * height * 4` bytes, row-major.
#[rustler::nif(schedule = "DirtyIo")]
fn set_image<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    selection: Atom,
    width: usize,
    height: usize,
    bytes: Binary<'a>,
) -> Term<'a> {
    let result = with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        let expected = width
            .checked_mul(height)
            .and_then(|pixels| pixels.checked_mul(4));

        if width == 0 || height == 0 || expected != Some(bytes.len()) {
            return Err(Reason::Atom(atoms::invalid_image()));
        }

        let image = ImageData {
            width,
            height,
            bytes: Cow::Borrowed(bytes.as_slice()),
        };

        platform::set(clipboard, selection)?
            .image(image)
            .map_err(Reason::from)
    });

    unit_reply(env, result)
}

/// Returns `{:ok, {width, height, rgba}}` or `{:error, reason}`.
#[rustler::nif(schedule = "DirtyIo")]
fn get_image<'a>(env: Env<'a>, handle: ResourceArc<Handle>, selection: Atom) -> Term<'a> {
    let result = with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::get(clipboard, selection)?
            .image()
            .map_err(Reason::from)
    });

    match result {
        Ok(image) => {
            let Some(mut binary) = OwnedBinary::new(image.bytes.len()) else {
                return (atoms::error(), atoms::out_of_memory()).encode(env);
            };

            binary.as_mut_slice().copy_from_slice(&image.bytes);
            let rgba = binary.release(env);
            (atoms::ok(), (image.width, image.height, rgba)).encode(env)
        }
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn clear<'a>(env: Env<'a>, handle: ResourceArc<Handle>, selection: Atom) -> Term<'a> {
    let result = with_clipboard(&handle, |clipboard| {
        let selection = self::selection(selection)?;
        platform::clear(clipboard, selection)
    });

    unit_reply(env, result)
}

rustler::init!("Elixir.Clipboard.Native");

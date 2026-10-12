//! Terms shared by the NIFs: byte strings, errors, and the shapes returned to
//! `GixEx`.

use rustler::{
    Binary, Decoder, Encoder, Env, NewBinary, NifMap, NifResult, NifStruct, NifTaggedEnum,
    NifUnitEnum, Term,
};

mod atoms {
    rustler::atoms! {
        not_a_repository,
        bare_repository,
        external_worktree,
        unknown_revision,
        no_merge_base,
        reference_not_found,
        not_symbolic,
        git,
    }
}

/// Bytes encoded as an Erlang binary. Paths and file contents are not
/// necessarily UTF-8, so they never go through `String`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Bytes(pub Vec<u8>);

impl Encoder for Bytes {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let mut binary = NewBinary::new(env, self.0.len());
        binary.as_mut_slice().copy_from_slice(&self.0);
        Term::from(binary)
    }
}

// The derived structs decode as well as encode; nothing decodes them in
// practice, but a binary is the only sensible input.
impl<'a> Decoder<'a> for Bytes {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        Ok(Bytes(term.decode::<Binary>()?.as_slice().to_vec()))
    }
}

impl From<&[u8]> for Bytes {
    fn from(bytes: &[u8]) -> Self {
        Bytes(bytes.to_vec())
    }
}

/// Why a call failed. Encoded as the reasons documented on `GixEx`.
#[derive(Debug)]
pub enum Error {
    NotARepository,
    BareRepository,
    ExternalWorktree,
    UnknownRevision(String),
    NoMergeBase,
    ReferenceNotFound(String),
    NotSymbolic(String),
    Git(String),
}

impl Encoder for Error {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Error::NotARepository => atoms::not_a_repository().encode(env),
            Error::BareRepository => atoms::bare_repository().encode(env),
            Error::ExternalWorktree => atoms::external_worktree().encode(env),
            Error::UnknownRevision(rev) => (atoms::unknown_revision(), rev).encode(env),
            Error::NoMergeBase => atoms::no_merge_base().encode(env),
            Error::ReferenceNotFound(name) => (atoms::reference_not_found(), name).encode(env),
            Error::NotSymbolic(name) => (atoms::not_symbolic(), name).encode(env),
            Error::Git(message) => (atoms::git(), message).encode(env),
        }
    }
}

/// Wraps any gix failure that has no reason of its own.
pub fn git(error: impl std::fmt::Display) -> Error {
    Error::Git(error.to_string())
}

/// One side of a diff, as passed by `GixEx.diff/4`.
#[derive(Debug, NifTaggedEnum)]
pub enum Side {
    Rev(String),
    Empty,
    Worktree,
    Index,
}

#[derive(Debug, Clone, Copy, NifUnitEnum)]
pub enum Algorithm {
    Myers,
    Histogram,
}

#[derive(Debug, NifMap)]
pub struct DiffOptions {
    pub context: u32,
    /// Rename similarity in `0.0..=1.0`, or `None` to disable rename tracking.
    pub renames: Option<f32>,
    pub algorithm: Algorithm,
    pub contents: bool,
    pub max_file_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, NifUnitEnum)]
pub enum Status {
    Added,
    Deleted,
    Modified,
    Renamed,
    Copied,
    Unmerged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, NifUnitEnum)]
pub enum LineKind {
    Add,
    Remove,
    Context,
}

#[derive(Debug, NifMap)]
pub struct Line {
    pub kind: LineKind,
    pub old: Option<u32>,
    pub new: Option<u32>,
    pub text: Bytes,
    pub no_newline: bool,
}

#[derive(Debug, NifStruct)]
#[module = "GixEx.Diff.Hunk"]
pub struct Hunk {
    pub header: Bytes,
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    pub section: Bytes,
    pub lines: Vec<Line>,
}

#[derive(Debug, NifStruct)]
#[module = "GixEx.Diff.File"]
pub struct File {
    pub path: Bytes,
    pub old_path: Option<Bytes>,
    pub status: Status,
    pub old_mode: Option<u32>,
    pub new_mode: Option<u32>,
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<Hunk>,
    pub old_content: Option<Bytes>,
    pub new_content: Option<Bytes>,
}

#[derive(Debug, NifStruct)]
#[module = "GixEx.Commit"]
pub struct Commit {
    pub id: String,
    pub subject: Bytes,
    pub body: Bytes,
}

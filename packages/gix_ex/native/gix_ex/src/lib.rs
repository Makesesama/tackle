//! Read-only Git access for `GixEx.Native`, backed by gitoxide (`gix`).
//!
//! Repositories are opened isolated: only the repository's own configuration
//! is read, never the environment, the user's, or the system's. No call runs
//! a program the repository configures (filters, `textconv`, hooks), so
//! reading a hostile repository cannot execute code. Every call reads the
//! disk and may take a while on a large repository, hence the dirty I/O
//! scheduler.

mod hunks;
mod snapshot;
mod terms;

use std::collections::HashSet;

use gix::bstr::{BStr, ByteSlice};
use gix::diff::tree_with_rewrites::Change;
use gix::objs::tree::{EntryKind, EntryMode};
use gix::ObjectId;
use rustler::ResourceArc;

use terms::{git, Bytes, Commit, DiffOptions, Error, File, Side, Status};

/// Git's limit for content inspected when deciding whether a blob is binary.
const BINARY_PROBE_BYTES: usize = 8000;
/// Object cache per call; repeated tree and commit lookups hit it.
const OBJECT_CACHE_BYTES: usize = 16 * 1024 * 1024;
/// Git's `diff.renameLimit` of 1000 caps sources × destinations at 1000²,
/// while gix compares its limit with that product directly.
const RENAME_PAIRS_LIMIT: usize = 1000 * 1000;

/// The `AssertUnwindSafe` is sound because a panic leaves nothing half
/// changed: every call works on its own thread-local handle.
pub struct Repo(std::panic::AssertUnwindSafe<gix::ThreadSafeRepository>);

#[rustler::resource_impl]
impl rustler::Resource for Repo {}

impl Repo {
    fn local(&self) -> gix::Repository {
        let mut repo = self.0.to_thread_local();
        repo.object_cache_size_if_unset(OBJECT_CACHE_BYTES);
        repo
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> Result<(ResourceArc<Repo>, Option<Bytes>, Bytes), Error> {
    use gix::discover::upwards::Error as Discovery;

    let path = std::path::Path::new(&path);
    let options = gix::open::Options::isolated();
    let trust = gix::sec::trust::Mapping {
        full: options.clone(),
        reduced: options.clone(),
    };

    // A repository directory given explicitly, such as a bare repository, is
    // opened as is. Searching upwards only accepts `.git` directories, so a
    // bare repository committed inside a checkout is not picked up from below.
    let repo = if gix::discover::is_git(path).is_ok() {
        gix::ThreadSafeRepository::open_opts(path, options).map_err(git)?
    } else {
        let upwards = || gix::discover::upwards::Options {
            dot_git_only: true,
            ..Default::default()
        };
        if let Err(error) = gix::discover::upwards_opts(path, upwards()) {
            return Err(match error.downcast_any_ref::<Discovery>() {
                Some(
                    Discovery::NoGitRepository { .. }
                    | Discovery::NoGitRepositoryWithinCeiling { .. }
                    | Discovery::NoGitRepositoryWithinFs { .. },
                ) => Error::NotARepository,
                _ => git(error),
            });
        }
        gix::ThreadSafeRepository::discover_opts(path, upwards(), trust).map_err(git)?
    };

    let local = repo.to_thread_local();
    let workdir = match local.workdir() {
        // `core.worktree` can point a repository's working tree anywhere, and
        // a diff of it would read files outside the checkout.
        Some(workdir) if !owns_git_dir(workdir, local.git_dir()) => {
            return Err(Error::ExternalWorktree)
        }
        Some(workdir) => Some(path_bytes(&canonical(workdir))?),
        None => None,
    };
    let git_dir = path_bytes(&canonical(local.git_dir()))?;

    Ok((
        ResourceArc::new(Repo(std::panic::AssertUnwindSafe(repo))),
        workdir,
        git_dir,
    ))
}

/// Whether `workdir/.git` is `git_dir`: the directory itself, or a `gitdir:`
/// file pointing at it, as in linked worktrees and submodules.
fn owns_git_dir(workdir: &std::path::Path, git_dir: &std::path::Path) -> bool {
    use std::io::Read;

    let dot_git = workdir.join(".git");
    let target = match std::fs::metadata(&dot_git) {
        Ok(metadata) if metadata.is_dir() => dot_git,
        Ok(metadata) if metadata.is_file() => {
            let mut content = Vec::new();
            let read = std::fs::File::open(&dot_git)
                .and_then(|file| file.take(4096).read_to_end(&mut content));
            let pointer = read.ok().and_then(|_| {
                content
                    .lines()
                    .next()
                    .and_then(|line| line.strip_prefix(b"gitdir:"))
                    .map(|target| target.trim().to_vec())
            });
            let target = pointer.and_then(|target| {
                gix::path::from_byte_slice(&target)
                    .ok()
                    .map(|path| path.to_owned())
            });
            match target {
                Some(target) => workdir.join(target),
                None => return false,
            }
        }
        _ => return false,
    };

    canonical(&target) == canonical(git_dir)
}

#[rustler::nif(schedule = "DirtyIo")]
fn resolve(repo: ResourceArc<Repo>, rev: String) -> Result<String, Error> {
    Ok(resolve_commit(&repo.local(), &rev)?.to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn merge_base(repo: ResourceArc<Repo>, one: String, two: String) -> Result<String, Error> {
    let repo = repo.local();
    let one = resolve_commit(&repo, &one)?;
    let two = resolve_commit(&repo, &two)?;

    match repo.merge_base(one, two).map_err(git)? {
        Some(base) => Ok(base.to_string()),
        None => Err(Error::NoMergeBase),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn symbolic_ref(repo: ResourceArc<Repo>, name: String) -> Result<(Bytes, Bytes), Error> {
    let repo = repo.local();
    let reference = repo
        .try_find_reference(name.as_str())
        .map_err(git)?
        .ok_or_else(|| Error::ReferenceNotFound(name.clone()))?;

    match reference.target() {
        gix::refs::TargetRef::Symbolic(target) => Ok((
            Bytes::from(target.as_bstr().as_bytes()),
            Bytes::from(target.shorten().as_bytes()),
        )),
        gix::refs::TargetRef::Object(_) => Err(Error::NotSymbolic(name)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn empty_tree(repo: ResourceArc<Repo>) -> String {
    ObjectId::empty_tree(repo.local().object_hash()).to_string()
}

#[rustler::nif(schedule = "DirtyIo")]
fn commits(
    repo: ResourceArc<Repo>,
    base: Option<String>,
    head: String,
    limit: Option<usize>,
) -> Result<Vec<Commit>, Error> {
    use gix::revision::walk::Sorting;
    use gix::traverse::commit::simple::CommitTimeOrder;

    let repo = repo.local();
    let head = resolve_commit(&repo, &head)?;
    let hidden = match base {
        Some(base) => vec![resolve_commit(&repo, &base)?],
        None => Vec::new(),
    };

    let walk = repo
        .rev_walk([head])
        .with_hidden(hidden)
        .sorting(Sorting::ByCommitTime(CommitTimeOrder::NewestFirst))
        .all()
        .map_err(git)?;

    let mut commits = Vec::new();
    for info in walk.take(limit.unwrap_or(usize::MAX)) {
        let info = info.map_err(git)?;
        let commit = repo.find_commit(info.id).map_err(git)?;
        let (subject, body) = split_message(commit.message_raw().map_err(git)?);
        commits.push(Commit {
            id: info.id.to_string(),
            subject: Bytes(subject),
            body: Bytes(body),
        });
    }

    Ok(commits)
}

#[rustler::nif(schedule = "DirtyIo")]
fn diff(
    repo: ResourceArc<Repo>,
    from: Side,
    to: Side,
    options: DiffOptions,
) -> Result<Vec<File>, Error> {
    // Index and working-tree snapshots are written to memory, never to disk.
    let repo = repo.local().with_object_memory();
    let old_tree = tree_of(&repo, &from)?;
    let (new_tree, unmerged, placeholders) = match to {
        Side::Index | Side::Worktree => {
            let source = match to {
                Side::Index => snapshot::Source::Index,
                _ => snapshot::Source::Worktree,
            };
            let snapshot = snapshot::tree(&repo, source, old_tree, options.max_file_bytes)?;
            // The working tree holds conflicted files with their markers;
            // only the index has no version of them.
            let unmerged = match source {
                snapshot::Source::Index => snapshot.unmerged,
                snapshot::Source::Worktree => Vec::new(),
            };
            (snapshot.tree, unmerged, snapshot.placeholders)
        }
        _ => (tree_of(&repo, &to)?, Vec::new(), HashSet::new()),
    };
    let old_tree = repo.find_tree(old_tree).map_err(git)?;
    let new_tree = repo.find_tree(new_tree).map_err(git)?;

    let rewrites = options.renames.map(|percentage| gix::diff::Rewrites {
        copies: None,
        percentage: Some(percentage),
        limit: RENAME_PAIRS_LIMIT,
        track_empty: false,
    });
    let changes = repo
        .diff_tree_to_tree(
            &old_tree,
            &new_tree,
            gix::diff::Options::default().with_rewrites(rewrites),
        )
        .map_err(git)?;

    let mut pairs: Vec<Pair> = changes.into_iter().flat_map(Pair::from_change).collect();
    pairs.extend(unmerged.into_iter().map(|path| Pair {
        status: Status::Unmerged,
        path: path.into(),
        old: None,
        new: None,
    }));
    // Git sorts by path; a type change keeps its deletion before its addition.
    pairs.sort_by(|a, b| a.path.cmp(&b.path));

    let mut attributes = Attributes::new(&repo)?;
    pairs
        .into_iter()
        .map(|pair| file(&repo, pair, &options, &mut attributes, &placeholders))
        .collect()
}

/// How the `diff` attribute treats a path.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Treatment {
    /// Decide by content.
    Auto,
    /// `diff`: always text.
    Text,
    /// `-diff`, `binary`, or a driver with `diff.<driver>.binary`.
    Binary,
}

/// `.gitattributes` as recorded in the index. Reading attributes runs no
/// programs; the working-tree copies are not read, so a hostile working tree
/// cannot block the call with a FIFO in place of a `.gitattributes` file.
struct Attributes<'repo> {
    repo: &'repo gix::Repository,
    stack: gix::AttributeStack<'repo>,
    outcome: gix::attrs::search::Outcome,
}

impl<'repo> Attributes<'repo> {
    fn new(repo: &'repo gix::Repository) -> Result<Self, Error> {
        let index = repo.index_or_empty().map_err(git)?;
        let stack = repo
            .attributes_only(
                &index,
                gix::worktree::stack::state::attributes::Source::IdMapping,
            )
            .map_err(git)?;
        let outcome = stack.selected_attribute_matches(["diff"]);
        Ok(Attributes {
            repo,
            stack,
            outcome,
        })
    }

    fn treatment(&mut self, path: &[u8]) -> Result<Treatment, Error> {
        use gix::attrs::StateRef;

        self.outcome.reset();
        let platform = self.stack.at_entry(path.as_bstr(), None).map_err(git)?;
        platform.matching_attributes(&mut self.outcome);

        let treatment = match self
            .outcome
            .iter_selected()
            .next()
            .map(|m| m.assignment.state)
        {
            Some(StateRef::Set) => Treatment::Text,
            Some(StateRef::Unset) => Treatment::Binary,
            Some(StateRef::Value(driver)) => {
                let key = format!("diff.{}.binary", driver.as_bstr());
                if self.repo.config_snapshot().boolean(key.as_str()) == Some(true) {
                    Treatment::Binary
                } else {
                    Treatment::Auto
                }
            }
            Some(StateRef::Unspecified) | None => Treatment::Auto,
        };
        Ok(treatment)
    }
}

/// One file of the diff: a side that is absent was added or deleted, and an
/// unmerged path has neither.
struct Pair {
    status: Status,
    /// The new path, or the old path of a deleted file.
    path: Vec<u8>,
    old: Option<Entry>,
    new: Option<Entry>,
}

struct Entry {
    path: Vec<u8>,
    mode: EntryMode,
    id: ObjectId,
}

impl Pair {
    fn new(status: Status, old: Option<Entry>, new: Option<Entry>) -> Pair {
        let path = match (&new, &old) {
            (Some(new), _) => new.path.clone(),
            (None, Some(old)) => old.path.clone(),
            (None, None) => Vec::new(),
        };
        Pair {
            status,
            path,
            old,
            new,
        }
    }

    fn from_change(change: Change) -> Vec<Pair> {
        let side = |path: &BStr, mode: EntryMode, id: ObjectId| Entry {
            path: path.to_vec(),
            mode,
            id,
        };

        match change {
            Change::Addition {
                location,
                entry_mode,
                id,
                ..
            } if !entry_mode.is_tree() => vec![Pair::new(
                Status::Added,
                None,
                Some(side(location.as_ref(), entry_mode, id)),
            )],
            Change::Deletion {
                location,
                entry_mode,
                id,
                ..
            } if !entry_mode.is_tree() => vec![Pair::new(
                Status::Deleted,
                Some(side(location.as_ref(), entry_mode, id)),
                None,
            )],
            Change::Modification {
                location,
                previous_entry_mode,
                previous_id,
                entry_mode,
                id,
            } => {
                let old = (!previous_entry_mode.is_tree())
                    .then(|| side(location.as_ref(), previous_entry_mode, previous_id));
                let new = (!entry_mode.is_tree()).then(|| side(location.as_ref(), entry_mode, id));

                match (old, new) {
                    // Like Git, a change between file, symlink, and submodule
                    // is a deletion followed by an addition.
                    (Some(old), Some(new)) if same_type(old.mode, new.mode) => {
                        vec![Pair::new(Status::Modified, Some(old), Some(new))]
                    }
                    (old, new) => {
                        let mut pairs = Vec::new();
                        if let Some(old) = old {
                            pairs.push(Pair::new(Status::Deleted, Some(old), None));
                        }
                        if let Some(new) = new {
                            pairs.push(Pair::new(Status::Added, None, Some(new)));
                        }
                        pairs
                    }
                }
            }
            Change::Rewrite {
                source_location,
                source_entry_mode,
                source_id,
                entry_mode,
                id,
                location,
                copy,
                ..
            } if !entry_mode.is_tree() => vec![Pair::new(
                if copy {
                    Status::Copied
                } else {
                    Status::Renamed
                },
                Some(side(source_location.as_ref(), source_entry_mode, source_id)),
                Some(side(location.as_ref(), entry_mode, id)),
            )],
            _ => Vec::new(),
        }
    }
}

fn same_type(a: EntryMode, b: EntryMode) -> bool {
    fn group(kind: EntryKind) -> u8 {
        match kind {
            EntryKind::Blob | EntryKind::BlobExecutable => 0,
            EntryKind::Link => 1,
            EntryKind::Commit => 2,
            EntryKind::Tree => 3,
        }
    }
    group(a.kind()) == group(b.kind())
}

fn file(
    repo: &gix::Repository,
    pair: Pair,
    options: &DiffOptions,
    attributes: &mut Attributes<'_>,
    placeholders: &HashSet<ObjectId>,
) -> Result<File, Error> {
    let mut treatment = Treatment::Auto;
    for side in [&pair.old, &pair.new].into_iter().flatten() {
        match attributes.treatment(&side.path)? {
            Treatment::Auto => {}
            Treatment::Binary => {
                treatment = Treatment::Binary;
                break;
            }
            Treatment::Text => treatment = Treatment::Text,
        }
    }

    let read =
        |side: Option<&Entry>| content(repo, side, options.max_file_bytes, treatment, placeholders);
    let old = read(pair.old.as_ref())?;
    let new = read(pair.new.as_ref())?;

    let binary = matches!(old, Content::Binary) || matches!(new, Content::Binary);
    let unchanged = match (&pair.old, &pair.new) {
        (Some(old), Some(new)) => old.id == new.id,
        _ => false,
    };

    let (hunks, additions, deletions) = if binary || unchanged {
        (Vec::new(), 0, 0)
    } else {
        let lines = hunks::diff(old.text(), new.text(), options.context, options.algorithm);
        (lines.hunks, lines.additions, lines.deletions)
    };

    // An unmerged path has no sides but is the same path on both.
    let old_path = match (&pair.old, pair.status) {
        (Some(old), _) => Some(Bytes(old.path.clone())),
        (None, Status::Unmerged) => Some(Bytes(pair.path.clone())),
        (None, _) => None,
    };

    Ok(File {
        path: Bytes(pair.path),
        old_path,
        status: pair.status,
        old_mode: pair.old.as_ref().map(|old| u32::from(old.mode.value())),
        new_mode: pair.new.as_ref().map(|new| u32::from(new.mode.value())),
        binary,
        additions,
        deletions,
        hunks,
        old_content: options.contents.then(|| old.into_bytes()).flatten(),
        new_content: options.contents.then(|| new.into_bytes()).flatten(),
    })
}

enum Content {
    Absent,
    Binary,
    Text(Vec<u8>),
}

impl Content {
    fn text(&self) -> &[u8] {
        match self {
            Content::Text(data) => data,
            Content::Absent | Content::Binary => &[],
        }
    }

    fn into_bytes(self) -> Option<Bytes> {
        match self {
            Content::Text(data) => Some(Bytes(data)),
            Content::Absent | Content::Binary => None,
        }
    }
}

fn content(
    repo: &gix::Repository,
    side: Option<&Entry>,
    max_bytes: u64,
    treatment: Treatment,
    placeholders: &HashSet<ObjectId>,
) -> Result<Content, Error> {
    let Some(side) = side else {
        return Ok(Content::Absent);
    };

    // Git shows a submodule as the commit it points at.
    if side.mode.is_commit() {
        return Ok(Content::Text(
            format!("Subproject commit {}\n", side.id).into_bytes(),
        ));
    }

    if treatment == Treatment::Binary || placeholders.contains(&side.id) {
        return Ok(Content::Binary);
    }

    let header = repo.find_header(side.id).map_err(git)?;
    if header.size() > max_bytes {
        return Ok(Content::Binary);
    }

    let data = repo.find_blob(side.id).map_err(git)?.take_data();
    let probe = &data[..data.len().min(BINARY_PROBE_BYTES)];
    if treatment == Treatment::Auto && probe.contains(&0) {
        Ok(Content::Binary)
    } else {
        Ok(Content::Text(data))
    }
}

fn tree_of(repo: &gix::Repository, side: &Side) -> Result<ObjectId, Error> {
    match side {
        Side::Empty => Ok(ObjectId::empty_tree(repo.object_hash())),
        Side::Index | Side::Worktree => Err(git("the old side of a diff must be a tree")),
        Side::Rev(rev) => {
            let unknown = || Error::UnknownRevision(rev.clone());
            let id = repo.rev_parse_single(rev.as_str()).map_err(|_| unknown())?;
            let tree = id
                .object()
                .map_err(|_| unknown())?
                .peel_to_tree()
                .map_err(|_| unknown())?;
            Ok(tree.id)
        }
    }
}

/// Resolves `rev` and peels it to a commit, as `rev^{commit}` does.
fn resolve_commit(repo: &gix::Repository, rev: &str) -> Result<ObjectId, Error> {
    let unknown = || Error::UnknownRevision(rev.to_owned());
    let id = repo.rev_parse_single(rev).map_err(|_| unknown())?;
    let commit = id
        .object()
        .map_err(|_| unknown())?
        .peel_to_commit()
        .map_err(|_| unknown())?;
    Ok(commit.id)
}

/// Splits a commit message as `git log --format=%s%x00%b` does: the subject is
/// the first paragraph with its lines joined by spaces, the body everything
/// after the blank lines that follow it.
fn split_message(message: &BStr) -> (Vec<u8>, Vec<u8>) {
    let mut rest: &[u8] = message.as_bytes();
    rest = skip_blank_lines(rest);

    let mut subject = Vec::new();
    while !rest.is_empty() {
        let (line, after) = match rest.find_byte(b'\n') {
            Some(end) => (&rest[..end], &rest[end + 1..]),
            None => (rest, &[][..]),
        };
        let line = trim_end(line);
        if line.is_empty() {
            break;
        }
        if !subject.is_empty() {
            subject.push(b' ');
        }
        subject.extend_from_slice(line);
        rest = after;
    }

    (subject, skip_blank_lines(rest).to_vec())
}

fn skip_blank_lines(mut text: &[u8]) -> &[u8] {
    loop {
        let (line, after) = match text.find_byte(b'\n') {
            Some(end) => (&text[..end], &text[end + 1..]),
            None => (text, &[][..]),
        };
        if text.is_empty() || !trim_end(line).is_empty() {
            return text;
        }
        text = after;
    }
}

/// Trims trailing whitespace as Git's `isspace` does: ASCII only.
fn trim_end(mut line: &[u8]) -> &[u8] {
    while let Some((last, rest)) = line.split_last() {
        if !hunks::is_c_space(*last) {
            break;
        }
        line = rest;
    }
    line
}

fn canonical(path: &std::path::Path) -> std::path::PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned())
}

fn path_bytes(path: &std::path::Path) -> Result<Bytes, Error> {
    Ok(Bytes(
        gix::path::into_bstr(path).map_err(git)?.into_owned().into(),
    ))
}

rustler::init!("Elixir.GixEx.Native");

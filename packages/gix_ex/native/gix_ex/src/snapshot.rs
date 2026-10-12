//! Trees for the index and the working tree.
//!
//! Neither has a tree object of its own, so one is written to the
//! repository's in-memory object store: the index entries as they are, or
//! with each tracked file replaced by its content on disk. The diff then
//! compares two trees, which gives the index and the working tree the same
//! rename tracking as commits.
//!
//! The working tree may be hostile, so reading it is careful:
//!
//! * Files are read as stored, without clean filters, `textconv`, or
//!   end-of-line conversion. Running filter commands configured by the
//!   repository would let the repository execute programs.
//! * Like Git, a tracked path below a symbolic link is treated as deleted
//!   rather than followed, and index paths with `..`, `.`, or `.git`
//!   components are rejected, so a diff cannot reach outside the working tree.
//! * Only regular files and symbolic links are read; a FIFO or device in
//!   place of a tracked file counts as deleted. Files are opened without
//!   following symbolic links or blocking.
//! * A file larger than the size limit is hashed as a stream but not kept;
//!   if it changed, the tree holds a small binary placeholder in its place.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use gix::bstr::{BStr, BString, ByteSlice};
use gix::index::entry::{stat, Flags, Stat};
use gix::objs::tree::EntryKind;
use gix::ObjectId;

use crate::terms::{git, Error};

/// Which version of each tracked file the tree holds.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Index,
    Worktree,
}

/// A tree written to object memory, and the paths that are unmerged in the
/// index.
pub struct Snapshot {
    pub tree: ObjectId,
    pub unmerged: Vec<BString>,
    /// Ids of the placeholders standing in for changed files over the size
    /// limit, which are always binary.
    pub placeholders: HashSet<ObjectId>,
}

/// Writes the tree of the index or of the working tree to object memory.
/// `repo` must have object memory enabled.
///
/// An unmerged path has no staged version, so for `Source::Index` it keeps
/// its entry from `base` and is reported in `unmerged`, which is how
/// `git diff --cached` shows it. The working tree holds the file with its
/// conflict markers, which is diffed like any other.
pub fn tree(
    repo: &gix::Repository,
    source: Source,
    base: ObjectId,
    max_file_bytes: u64,
) -> Result<Snapshot, Error> {
    let index = repo.index_or_empty().map_err(git)?;
    let workdir = match source {
        Source::Index => None,
        Source::Worktree => Some(repo.workdir().ok_or(Error::BareRepository)?.to_owned()),
    };

    let disk = Disk {
        repo,
        directories: RefCell::new(HashMap::new()),
        placeholders: RefCell::new(HashSet::new()),
        file_mode: config_bool(repo, "core.fileMode", true),
        symlinks: config_bool(repo, "core.symlinks", true),
        stat: stat::Options {
            trust_ctime: config_bool(repo, "core.trustctime", true),
            ..stat::Options::default()
        },
        max_file_bytes,
    };

    let base = repo.find_tree(base).map_err(git)?;
    let mut editor = repo
        .edit_tree(ObjectId::empty_tree(repo.object_hash()))
        .map_err(git)?;
    let mut unmerged: Vec<BString> = Vec::new();

    for entry in index.entries() {
        let Some(mode) = entry.mode.to_tree_entry_mode() else {
            continue;
        };
        let kind = mode.kind();
        // A sparse directory entry is stored as `dir/`.
        let path = match kind {
            EntryKind::Tree => entry.path(&index).trim_end_with(|c| c == '/').as_bstr(),
            _ => entry.path(&index),
        };
        validate(path)?;

        // An unmerged path has up to three entries, one per stage.
        if entry.stage_raw() != 0 {
            if unmerged.last().map(|last| last.as_bstr()) == Some(path) {
                continue;
            }
            unmerged.push(path.to_owned());

            match workdir.as_deref() {
                None => {
                    if let Some(entry) = base
                        .lookup_entry_by_path(gix::path::from_bstr(path).map_err(git)?)
                        .map_err(git)?
                    {
                        editor
                            .upsert(path, entry.mode().kind(), entry.object_id())
                            .map_err(git)?;
                    }
                }
                Some(workdir) => {
                    if let Some((kind, id)) = disk.read(workdir, path, kind, None)? {
                        editor.upsert(path, kind, id).map_err(git)?;
                    }
                }
            }
            continue;
        }

        let Some(workdir) = workdir.as_deref() else {
            // A path only added with `git add -N` has no staged content.
            if !entry.flags.contains(Flags::INTENT_TO_ADD) {
                editor.upsert(path, kind, entry.id).map_err(git)?;
            }
            continue;
        };

        // Sparse directories and submodules have no file of their own; Git
        // takes skip-worktree and assume-unchanged entries from the index.
        let on_disk = matches!(
            kind,
            EntryKind::Blob | EntryKind::BlobExecutable | EntryKind::Link
        ) && !entry
            .flags
            .intersects(Flags::SKIP_WORKTREE | Flags::ASSUME_VALID);

        if !on_disk {
            editor.upsert(path, kind, entry.id).map_err(git)?;
            continue;
        }

        // A file written in the same instant as the index may have changed
        // without its stat data showing it ("racy git"), so it is read.
        let trust_stat = !entry.flags.contains(Flags::INTENT_TO_ADD)
            && !entry.stat.is_racy(index.timestamp(), disk.stat);

        let version = if trust_stat && disk.stat_matches(workdir, path, &entry.stat)? {
            Some((kind, entry.id))
        } else {
            disk.read(workdir, path, kind, Some(entry.id))?
        };

        if let Some((kind, id)) = version {
            editor.upsert(path, kind, id).map_err(git)?;
        }
    }

    let tree = editor.write().map_err(git)?.detach();
    Ok(Snapshot {
        tree,
        unmerged,
        placeholders: disk.placeholders.into_inner(),
    })
}

/// Rejects index paths that would leave the working tree or enter `.git`.
fn validate(path: &BStr) -> Result<(), Error> {
    let invalid = path.split_str("/").any(|component| {
        component.is_empty()
            || component == b"."
            || component == b".."
            || component.eq_ignore_ascii_case(b".git")
    });

    if invalid {
        Err(git(format!("invalid path in the index: {path:?}")))
    } else {
        Ok(())
    }
}

struct Disk<'repo> {
    repo: &'repo gix::Repository,
    /// Whether each directory seen so far is a real directory of the working
    /// tree, rather than a symbolic link or something else.
    directories: RefCell<HashMap<PathBuf, bool>>,
    placeholders: RefCell<HashSet<ObjectId>>,
    file_mode: bool,
    symlinks: bool,
    stat: stat::Options,
    max_file_bytes: u64,
}

impl Disk<'_> {
    fn full_path(&self, workdir: &Path, path: &BStr) -> Result<PathBuf, Error> {
        Ok(workdir.join(gix::path::from_bstr(path).map_err(git)?))
    }

    /// Whether the file still has the stat data recorded in the index, which
    /// is how `git diff` avoids reading unchanged files.
    fn stat_matches(&self, workdir: &Path, path: &BStr, indexed: &Stat) -> Result<bool, Error> {
        let full = self.full_path(workdir, path)?;
        let Some(metadata) = self.metadata(workdir, &full)? else {
            return Ok(false);
        };

        Ok(Stat::from_fs(&metadata).is_ok_and(|current| indexed.matches(&current, self.stat)))
    }

    /// Reads a tracked file into object memory and returns its kind and id,
    /// or `None` when there is no file to read. `indexed` is the id in the
    /// index, which a file over the size limit keeps when it is unchanged.
    fn read(
        &self,
        workdir: &Path,
        path: &BStr,
        indexed_kind: EntryKind,
        indexed: Option<ObjectId>,
    ) -> Result<Option<(EntryKind, ObjectId)>, Error> {
        let full = self.full_path(workdir, path)?;
        let Some(metadata) = self.metadata(workdir, &full)? else {
            return Ok(None);
        };

        if metadata.is_symlink() {
            let target = match std::fs::read_link(&full) {
                Ok(target) => target,
                Err(error) if gone(&error) => return Ok(None),
                Err(error) => return Err(io_error(&full, error)),
            };
            let target = gix::path::into_bstr(target).map_err(git)?.into_owned();
            let id = self.repo.write_blob(&target).map_err(git)?.detach();
            return Ok(Some((EntryKind::Link, id)));
        }

        // Open without following a symbolic link swapped in since the stat,
        // and without blocking on a FIFO; then check what was opened.
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&full)
        {
            Ok(file) => file,
            Err(error) if gone(&error) || error.raw_os_error() == Some(libc::ELOOP) => {
                return Ok(None);
            }
            Err(error) => return Err(io_error(&full, error)),
        };
        let opened = file.metadata().map_err(|error| io_error(&full, error))?;
        if !opened.is_file() {
            return Ok(None);
        }

        let kind = self.file_kind(opened.permissions().mode() & 0o100 != 0, indexed_kind);
        let size = opened.len();

        if size > self.max_file_bytes {
            let id = self.hash_large(file, size, &full)?;
            let id = if Some(id) == indexed {
                id
            } else {
                self.placeholder(id, size)?
            };
            return Ok(Some((kind, id)));
        }

        let mut data = Vec::with_capacity(size as usize);
        file.take(self.max_file_bytes + 1)
            .read_to_end(&mut data)
            .map_err(|error| io_error(&full, error))?;

        // The file grew past the limit while it was read.
        if data.len() as u64 > self.max_file_bytes {
            let id = gix::objs::compute_hash(self.repo.object_hash(), gix::objs::Kind::Blob, &data)
                .map_err(git)?;
            return Ok(Some((kind, self.placeholder(id, data.len() as u64)?)));
        }

        let id = self.repo.write_blob(&data).map_err(git)?.detach();
        Ok(Some((kind, id)))
    }

    fn hash_large(&self, file: std::fs::File, size: u64, full: &Path) -> Result<ObjectId, Error> {
        let mut stream = file.take(size);
        gix::objs::compute_stream_hash(
            self.repo.object_hash(),
            gix::objs::Kind::Blob,
            &mut stream,
            size,
            &mut gix::progress::Discard,
            &AtomicBool::new(false),
        )
        .map_err(|error| git(format!("{}: {error}", full.display())))
    }

    /// A small blob standing in for a changed file over the size limit. Its
    /// NUL byte makes the diff report the file as binary, and the real id in
    /// it keeps different versions apart.
    fn placeholder(&self, id: ObjectId, size: u64) -> Result<ObjectId, Error> {
        let content = format!("\0gix_ex: file over the size limit, {size} bytes, blob {id}\n");
        let placeholder = self
            .repo
            .write_blob(content.as_bytes())
            .map_err(git)?
            .detach();
        self.placeholders.borrow_mut().insert(placeholder);
        Ok(placeholder)
    }

    fn file_kind(&self, executable: bool, indexed: EntryKind) -> EntryKind {
        if !self.symlinks && indexed == EntryKind::Link {
            // Without symlink support the link is checked out as a plain file
            // holding its target.
            EntryKind::Link
        } else if !self.file_mode {
            match indexed {
                EntryKind::BlobExecutable => EntryKind::BlobExecutable,
                _ => EntryKind::Blob,
            }
        } else if executable {
            EntryKind::BlobExecutable
        } else {
            EntryKind::Blob
        }
    }

    /// Metadata of a tracked path, or `None` when there is no file: missing,
    /// replaced by a directory, or below a symbolic link.
    fn metadata(
        &self,
        workdir: &Path,
        full: &Path,
    ) -> Result<Option<gix::index::fs::Metadata>, Error> {
        match full.parent() {
            Some(parent) if !self.real_directory(workdir, parent)? => Ok(None),
            _ => match gix::index::fs::Metadata::from_path_no_follow(full) {
                Ok(metadata) if metadata.is_dir() => Ok(None),
                Ok(metadata) => Ok(Some(metadata)),
                Err(error) if gone(&error) => Ok(None),
                Err(error) => Err(io_error(full, error)),
            },
        }
    }

    fn real_directory(&self, workdir: &Path, directory: &Path) -> Result<bool, Error> {
        if directory == workdir {
            return Ok(true);
        }
        if let Some(known) = self.directories.borrow().get(directory) {
            return Ok(*known);
        }

        let real = match directory.parent() {
            Some(parent) if directory.starts_with(workdir) => {
                self.real_directory(workdir, parent)?
                    && match std::fs::symlink_metadata(directory) {
                        Ok(metadata) => metadata.is_dir(),
                        Err(error) if gone(&error) => false,
                        Err(error) => return Err(io_error(directory, error)),
                    }
            }
            _ => false,
        };

        self.directories
            .borrow_mut()
            .insert(directory.to_owned(), real);
        Ok(real)
    }
}

fn gone(error: &std::io::Error) -> bool {
    // A path below a file that replaced its directory fails with ENOTDIR.
    matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory)
}

fn io_error(path: &Path, error: std::io::Error) -> Error {
    git(format!("{}: {error}", path.display()))
}

fn config_bool(repo: &gix::Repository, key: &str, default: bool) -> bool {
    repo.config_snapshot().boolean(key).unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::validate;
    use gix::bstr::ByteSlice;

    #[test]
    fn rejects_paths_that_leave_the_working_tree() {
        for path in [
            "../etc/passwd",
            "a/../../b",
            "./a",
            "a//b",
            ".git/config",
            "a/.GIT/x",
            "",
        ] {
            assert!(validate(path.as_bytes().as_bstr()).is_err(), "{path:?}");
        }
        for path in ["a", "a/b.txt", ".gitignore", "a/.github/x", "..a", "a.."] {
            assert!(validate(path.as_bytes().as_bstr()).is_ok(), "{path:?}");
        }
    }
}

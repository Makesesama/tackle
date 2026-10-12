use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

// A musl cdylib cannot use crt-static. Once it is disabled, rustc requests
// libgcc_s for panic unwinding, but Burrito's runtime does not ship that
// shared library. Shadow the lookup with the toolchain's static unwinder.
fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    if !target.contains("musl") {
        return;
    }

    let compiler = cc::Build::new().get_compiler();
    let archive = query_archive(compiler.path(), "libgcc_eh.a");

    let Some(archive) = archive else {
        println!(
            "cargo:warning=libgcc_eh.a was not found; the musl NIF may depend on libgcc_s.so.1"
        );
        return;
    };

    let shim_dir = PathBuf::from(env::var("OUT_DIR").unwrap()).join("gcc_s_shim");
    fs::create_dir_all(&shim_dir).expect("failed to create the libgcc_s shim directory");
    fs::copy(archive, shim_dir.join("libgcc_s.a")).expect("failed to copy libgcc_eh.a");
    println!("cargo:rustc-link-search=native={}", shim_dir.display());

    if let Some(archive) = query_archive(compiler.path(), "libgcc.a") {
        fs::copy(archive, shim_dir.join("libgcc.a")).expect("failed to copy libgcc.a");
    }

    println!("cargo:rustc-link-arg=-lgcc");
}

fn query_archive(compiler: &std::path::Path, name: &str) -> Option<PathBuf> {
    let output = Command::new(compiler)
        .arg(format!("-print-file-name={name}"))
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    (path.is_absolute() && path.exists()).then_some(path)
}
